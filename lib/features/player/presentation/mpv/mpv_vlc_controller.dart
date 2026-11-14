/// An mpv-backed [VlcPlayerController], so the stock player chrome
/// ([VlcPlayerControls]) and the stock options panel ([PlayerPanel]) run on
/// the mpv engine (media_kit) instead of libVLC.
///
/// The stock UI is written against [VlcPlayerController] — an abstract class
/// whose only constructor is a factory plus a library-private `._()`, so it
/// cannot be subclassed from app code. This class `implements` it instead,
/// backed by a media_kit [Player]: it publishes a [VlcPlayerValue] built
/// from mpv's state, and translates the stock UI's calls (play / pause /
/// seek / track picks) into mpv calls. It owns no playback itself.
///
/// What maps cleanly:
///   * transport — play, pause, stop, seek, speed, volume, fit;
///   * tracks — embedded audio/subtitle tracks from mpv, plus the plugin's
///     external subtitle files (ids 1000+, see [_externalIdBase]);
///   * subtitle look — stored and reported (the screen draws it through
///     media_kit's [SubtitleViewConfiguration]);
///   * position/duration/buffered/video size — published from mpv's state.
///
/// What mpv cannot do, and is honestly absent rather than faked:
///   * picture-in-picture — `startPictureInPicture` returns false (no
///     iOS PiP window from an mpv texture). Android PiP does not go
///     through here at all: the screen enters it through the platform
///     service and passes `onEnterPip`, so the PiP button renders on
///     Android; the only job here is publishing `videoSize` for the
///     window's aspect ratio;
///   * audio/subtitle delay — media_kit 1.2.6 exposes no delay API, so
///     [setAudioDelay] / [setSubtitleDelay] are no-ops (the panel's stepper
///     shows 0 and does nothing);
///   * playlists, snapshots, media stats — not used by the player screen;
///     they throw [UnimplementedError].
library;

import 'dart:async';
import 'dart:ui' show Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../domain/track_language.dart';

/// External (plugin) subtitle files live at ids from here up, so they can
/// never collide with an embedded track's index.
const int _externalIdBase = 1000;

/// Keeps the first item of each key, dropping later duplicates.
///
/// The subtitle track list's dedup rule: mpv reports the same subtitle
/// content once per HLS rendition/variant, so one language can appear half
/// a dozen times with the same title + language ("English - [auto]" six
/// times over), and a source can ship the same side-car file twice. The
/// viewer cannot tell the copies apart — the row shows only title +
/// language — so only the first is kept. Pure, so the rule is testable
/// without a player.
List<T> deduplicateByKey<T, K>(List<T> items, K Function(T) key) {
  final seen = <K>{};
  final out = <T>[];
  for (final item in items) {
    if (seen.add(key(item))) out.add(item);
  }
  return out;
}

/// How near a seek's target the reported position must land for the pending
/// seek to count as arrived.
const Duration _kSeekLandedWithin = Duration(seconds: 3);

/// A [VlcPlaybackClock] that reads the last position the adapter published.
/// The stock chrome never reads it (only the VLC screen's own subtitle
/// timing does), so this is a thin, honest implementation: the position is
/// the engine's last word, and [timeUntil] counts forward at the current
/// speed while playing.
class _MpvPlaybackClock extends ChangeNotifier implements VlcPlaybackClock {
  Duration _position = Duration.zero;
  double _speed = 1.0;
  bool _playing = false;

  void update(Duration position, double speed, bool playing) {
    _position = position;
    _speed = speed;
    _playing = playing;
  }

  @override
  Duration get position => _position;

  @override
  Duration? timeUntil(Duration target) {
    if (!_playing || _speed <= 0) return null;
    final remaining = target - _position;
    if (remaining <= Duration.zero) return Duration.zero;
    return Duration(
      milliseconds: (remaining.inMilliseconds / _speed).round(),
    );
  }
}

/// The mpv engine, speaking the stock UI's language.
class MpvVlcController implements VlcPlayerController {
  MpvVlcController({
    required Player player,
    required List<SubtitleFile> Function() externalSubtitles,
    required String Function() mediaTitle,
  }) : _player = player,
       _externalSubtitles = externalSubtitles,
       _mediaTitle = mediaTitle;

  final Player _player;
  final List<SubtitleFile> Function() _externalSubtitles;
  final String Function() _mediaTitle;

  /// The published value, and the notifier that carries listeners for it.
  /// [VlcPlayerValue] has no `==`, so every publish notifies — the stock
  /// chrome throttles its own rebuilds.
  VlcPlayerValue _value = const VlcPlayerValue();
  final ValueNotifier<VlcPlayerValue> _notifier =
      ValueNotifier<VlcPlayerValue>(const VlcPlayerValue());

  /// Whether a seek is on its way, and where it is going.
  final ValueNotifier<Duration?> _pendingSeekTarget =
      ValueNotifier<Duration?>(null);

  /// Whether the PiP window is up. Always false on mpv.
  final ValueNotifier<bool> _pictureInPicture = ValueNotifier<bool>(false);

  final _MpvPlaybackClock _clock = _MpvPlaybackClock();

  /// Counts seeks and pauses/stops, as the stock controller does: a host
  /// watching for a stop nobody asked for compares these against a
  /// remembered value.
  int _seekRequests = 0;
  int _pauseRequests = 0;

  /// The last subtitle look the screen asked for, kept so a re-read sees it.
  VlcSubtitleLook? _subtitleLook;

  /// The measured length cap, if the screen set one.
  Duration? _durationCap;

  /// The fit the screen last asked for. The screen reads it back to draw
  /// the video; mpv itself is always told through the video widget.
  VlcVideoFit _fit = VlcVideoFit.contain;

  /// The track lists' revision, bumped whenever mpv reports new tracks or
  /// the subtitle look changes, so the panel re-reads its lists.
  int _trackRevision = 0;

  /// The aid mpv itself reports as playing, read back from the engine (see
  /// [refreshRealAudioAid]). media_kit never reads the track-list
  /// `selected` flag, so when mpv auto-selects, `state.track.audio` stays
  /// `auto` and [_activeAudioId] can only guess — and the guess is wrong
  /// while the HLS list is still settling, because mpv locks its pick
  /// early (Tamil) and the settled list resolves to another track (Hindi).
  /// Null while no read-back has landed (or it answered 'auto'/'no').
  int? _realAudioAid;

  /// The last error string, published as the value's error.
  String? _errorDescription;

  bool _disposed = false;

  // -- publishing -----------------------------------------------------------

  /// Rebuilds the published value from mpv's current state. The screen
  /// calls this on every mpv state change (playing, position, duration,
  /// buffer, buffering, completed, tracks, error).
  void publish() {
    if (_disposed) return;
    final state = _player.state;
    final position = state.position;
    final duration = _durationCap != null && state.duration > _durationCap!
        ? _durationCap!
        : state.duration;

    // A pending seek counts as landed once the engine is at (or just past)
    // its target; a seek the engine ignored stays pending until a new one
    // replaces it, exactly as the stock controller holds it.
    final pending = _pendingSeekTarget.value;
    if (pending != null) {
      final landed =
          (position - pending).abs() <= _kSeekLandedWithin ||
          position > pending;
      if (landed) _pendingSeekTarget.value = null;
    }

    final isLive = duration <= Duration.zero && state.playing;
    final videoParams = state.videoParams;
    final videoSize =
        videoParams.w != null && videoParams.h != null
            ? Size(
                videoParams.w!.toDouble(),
                videoParams.h!.toDouble(),
              )
            : null;

    final VlcPlaybackState playbackState;
    if (_errorDescription != null && !state.playing) {
      playbackState = VlcPlaybackState.error;
    } else if (state.completed) {
      playbackState = VlcPlaybackState.ended;
    } else if (state.buffering && state.playing) {
      playbackState = VlcPlaybackState.buffering;
    } else if (state.playing) {
      playbackState = VlcPlaybackState.playing;
    } else if (position > Duration.zero || duration > Duration.zero) {
      playbackState = VlcPlaybackState.paused;
    } else {
      playbackState = VlcPlaybackState.idle;
    }

    _clock.update(position, state.rate, state.playing);

    _value = VlcPlayerValue(
      state: playbackState,
      position: position,
      duration: duration,
      volume: state.volume.round().clamp(0, 100),
      playbackSpeed: state.rate,
      audioDelay: Duration.zero,
      subtitleDelay: Duration.zero,
      activeAudioTrackId: _activeAudioId(),
      activeSubtitleTrackId: _activeSubtitleId(),
      trackRevision: _trackRevision,
      isReady: duration > Duration.zero,
      isSeekable: duration > Duration.zero && !isLive,
      isLive: isLive,
      isStalled: state.buffering && state.playing,
      videoSize: videoSize,
      bufferingProgress: duration > Duration.zero
          ? (state.buffer.inMilliseconds / duration.inMilliseconds)
                .clamp(0.0, 1.0)
          : null,
      error: _errorDescription == null
          ? null
          : VlcPlayerError(
              code: VlcPlayerErrorCode.playbackError,
              message: _errorDescription,
            ),
      errorDescription: _errorDescription,
    );
    _notifier.value = _value;
  }

  /// Notes that the track lists changed (mpv reported new tracks, or the
  /// screen opened a new source). Bumps the revision and republishes, so
  /// the panel re-reads its lists. The aid read-back is re-validated too:
  /// an aid belongs to the media it was read from, so a stale one from the
  /// previous source must not outlive the new list.
  void noteTracksChanged() {
    _trackRevision++;
    _realAudioAid = null;
    publish();
    unawaited(refreshRealAudioAid());
  }

  /// Reads mpv's `aid` property — the track actually playing — back from
  /// the engine, so the drawer lights the track mpv is on, not the guess
  /// [_activeAudioId] makes while the state is `auto`.
  ///
  /// Best-effort: a non-numeric answer ('auto'/'no') or any error clears
  /// the read-back and the guess stands. Called from [noteTracksChanged],
  /// so it lands as soon as the tracks exist and re-lands as the HLS list
  /// settles; the drawer repaints when it does (see the [publish]).
  Future<void> refreshRealAudioAid() async {
    try {
      final platform = _player.platform;
      if (platform is! NativePlayer) return;
      final aid = int.tryParse(await platform.getProperty('aid'));
      if (_disposed) return;
      if (aid != _realAudioAid) {
        _realAudioAid = aid;
        publish();
      }
    } catch (_) {
      // Best-effort: the guess in [_activeAudioId] stands.
      if (!_disposed && _realAudioAid != null) {
        _realAudioAid = null;
        publish();
      }
    }
  }

  /// Notes a playback error, published as the value's error until the next
  /// successful open clears it.
  void noteError(String? message) {
    _errorDescription = message;
    publish();
  }

  /// Clears a previously noted error (a new source opened).
  void clearError() {
    if (_errorDescription == null) return;
    _errorDescription = null;
    publish();
  }

  // -- track id mapping -----------------------------------------------------

  /// The engine's real tracks: media_kit's lists lead with the `auto` and
  /// `no` sentinels, which are not tracks a viewer can pick — shown, they
  /// read as the generic "Audio 1" / "Subtitle 2" rows, and the screen's
  /// auto-select set `embedded.first` (the `auto` sentinel) instead of the
  /// first real track, leaving the state on 'auto' while mpv played its
  /// pick — so the drawer read "Off" under a rendering subtitle.
  List<AudioTrack> get _audioTracks => _player.state.tracks.audio
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList(growable: false);
  /// The embedded subtitle tracks, deduplicated by title + language: mpv
  /// reports the same content once per HLS rendition/variant, so without
  /// this the drawer lists "English - [auto]" six times over. Keeping the
  /// first occurrence, so the row the viewer sees is the track the id
  /// selects. This is the list every id maps against — get, set and active
  /// all read it — so a shown id always selects the track it names, and
  /// tapping a row can never spawn more duplicates: the rendered list is
  /// rebuilt from this deduped source, so no matter how many renditions
  /// mpv discovers on a tap, the drawer still shows one row per track.
  List<SubtitleTrack> get _embeddedSubtitles => deduplicateByKey(
    _player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList(growable: false),
    (t) => (t.title, t.language),
  );

  /// The side-car / downloaded subtitle files, deduplicated by URL: a source
  /// can ship the same file twice, and the drawer would list it twice. The
  /// same list every id maps against, as with [_embeddedSubtitles].
  List<SubtitleFile> get _externalSubtitlesDeduped =>
      deduplicateByKey(_externalSubtitles(), (f) => f.url);

  /// A track's id as the drawer (and the screen's remembered pick) knows
  /// it: mpv's real track id — the `aid` / `sid` — not the track's
  /// position in the list. media_kit reports the mpv id as a string
  /// (`'1'`, `'2'`, …); the list position is NOT that id, and the list
  /// is re-ordered while an HLS master settles (renditions appear as the
  /// demuxer discovers them), so a position stored at drawer-open time
  /// pointed at a different track by tap time — Hindi shown selected
  /// while Tamil played, and the first tap landing on the wrong track.
  /// The fallback (list position) only covers a track whose id mpv did
  /// not number, which a real track never is.
  int _trackId(String mpvId, int fallback) =>
      int.tryParse(mpvId) ?? fallback;

  int? _activeAudioId() {
    final current = _player.state.track.audio;
    if (current.id == 'no') return null;
    if (current.id == 'auto') {
      // mpv's own word first: the aid read back from the engine (see
      // [refreshRealAudioAid]). The guess below is only for the window
      // before that read-back lands.
      final real = _realAudioAid;
      if (real != null) return real;
      // mpv auto-selected: it plays the default-flagged audio track,
      // else the first one — the same rule mpv itself uses with no
      // language preference set. The engine never reports which one it
      // picked (media_kit does not read the track-list `selected` flag),
      // so resolve it here, or nothing would read as selected while the
      // video is playing. The id returned is the track's real mpv aid,
      // so the drawer row it lights is the track mpv is playing.
      if (_audioTracks.isEmpty) return null;
      final def = _audioTracks.indexWhere((t) => t.isDefault == true);
      final track = _audioTracks[def >= 0 ? def : 0];
      return _trackId(track.id, def >= 0 ? def : 0);
    }
    // mpv's own word for the track playing: its aid, read back from the
    // engine — never the position in a list that may since have moved.
    return int.tryParse(current.id);
  }

  /// The audio track mpv would pick on its own, from the LIVE track list:
  /// the default-flagged track, else the first — the real mpv aid, or null
  /// when there are no audio tracks yet.
  ///
  /// The screen's auto-select uses this on AUTO (no preferred language, no
  /// last pick) instead of the published [value.activeAudioTrackId], which
  /// is stale when the tracks listener runs: the listener fires before the
  /// adapter publishes, and on a direct file there is only one tracks event,
  /// so a stale read that returns early is never retried — Tamil played
  /// while the drawer showed Hindi (+4, AUTO only).
  int? get liveDefaultAudioTrackId {
    if (_audioTracks.isEmpty) return null;
    final def = _audioTracks.indexWhere((t) => t.isDefault == true);
    final track = _audioTracks[def >= 0 ? def : 0];
    return _trackId(track.id, def >= 0 ? def : 0);
  }

  int? _activeSubtitleId() {
    final current = _player.state.track.subtitle;
    if (current.id == 'no') return null;
    if (current.id == 'auto') {
      // mpv auto-selected: it plays the default-flagged subtitle track,
      // else the first one — the same rule mpv itself uses. The engine
      // never reports which one it picked, so resolve it here, or the
      // drawer would read "Off" while a subtitle renders. The id
      // returned is the track's real mpv sid.
      final embedded = _embeddedSubtitles;
      if (embedded.isEmpty) return null;
      final def = embedded.indexWhere((t) => t.isDefault == true);
      final track = embedded[def >= 0 ? def : 0];
      return _trackId(track.id, def >= 0 ? def : 0);
    }
    // An external file the screen added: mpv reports it under its title.
    final external = _externalSubtitlesDeduped;
    final externalIndex = external.indexWhere(
      (f) => f.label == current.title,
    );
    if (externalIndex >= 0) return _externalIdBase + externalIndex;
    // mpv's own word for the track playing: its sid, read back from the
    // engine — never the position in a list that may since have moved.
    return int.tryParse(current.id);
  }

  /// The language name for a track's language code or label, or null when
  /// it names none known here. Mirrors the panel's own `_languageName`
  /// (player_panel_labels.dart): a code maps to its English name, a name
  /// passes through, `und` (unknown) is nothing.
  String? _languageName(String? language) {
    final value = language?.trim();
    if (value == null || value.isEmpty || value.toLowerCase() == 'und') {
      return null;
    }
    final mapped = languageNameForCode(value);
    if (mapped != null) return mapped;
    if (value.length > 3) return value;
    return value.toUpperCase();
  }

  /// The language a track's title itself carries, e.g. `[Hindi]` in
  /// `Track 1 - [Hindi]` — the fallback when media_kit reports no
  /// language for the track. `languageCodeOf` reads a bracketed name out
  /// of a label.
  String? _languageFromTitle(String title) {
    final code = languageCodeOf(title);
    if (code == null) return null;
    return languageNameForCode(code);
  }

  /// Whether the title already carries its language (in brackets, or as a
  /// word), so the display name does not read it twice.
  bool _titleHasLanguage(String title, String language) {
    final lowered = title.toLowerCase();
    final lang = language.toLowerCase();
    return lowered.contains('[$lang]') || lowered.contains(lang);
  }

  /// The audio/subtitle row's display name: the track's title with its
  /// language in brackets, as the original shows — `MoviesDrives.bid -
  /// [English]`. libVLC folds the language into the track name itself;
  /// mpv (media_kit) reports the title and the language separately, and
  /// the panel's `trackLabel` returns a non-empty title as-is, so the
  /// language was lost and every row read the same bare title. The
  /// language is appended here, where the adapter owns the mapping.
  String _trackDisplayName({
    required String? title,
    required String? language,
    required String fallback,
  }) {
    final name = (title ?? '').trim();
    final lang = _languageName(language) ?? _languageFromTitle(name);
    if (name.isNotEmpty) {
      if (lang != null && !_titleHasLanguage(name, lang)) {
        return '$name - [$lang]';
      }
      return name;
    }
    if (lang != null) return lang;
    return fallback;
  }

  /// The channel count for an audio track: the demux channel count, else
  /// the output channel count, else the channel layout string (`5.1` → 6)
  /// — so the panel's detail line can read `5.1` as the original does.
  int? _audioChannelCount(AudioTrack track) {
    final count = track.channelscount ?? track.audiochannels;
    if (count != null && count > 0) return count;
    final layout = track.channels?.trim().toLowerCase();
    if (layout == null || layout.isEmpty) return null;
    return switch (layout) {
      'mono' || '1.0' => 1,
      'stereo' || '2.0' => 2,
      '2.1' => 3,
      '3.0' => 3,
      '4.0' => 4,
      '5.0' => 5,
      '5.1' => 6,
      '6.1' => 7,
      '7.1' => 8,
      _ => null,
    };
  }

  // -- ValueNotifier (the stock UI listens to this) -------------------------

  @override
  VlcPlayerValue get value => _notifier.value;

  @override
  set value(VlcPlayerValue newValue) {
    _value = newValue;
    _notifier.value = newValue;
  }

  @override
  void addListener(VoidCallback listener) => _notifier.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _notifier.removeListener(listener);

  @override
  void notifyListeners() => _notifier.notifyListeners();

  @override
  bool get hasListeners => _notifier.hasListeners;

  @override
  void dispose() {
    _disposed = true;
    _notifier.dispose();
    _pendingSeekTarget.dispose();
    _pictureInPicture.dispose();
    _clock.dispose();
  }

  // -- identity -------------------------------------------------------------

  @override
  bool get autoPlay => false;

  @override
  List<String> get options => const <String>[];

  @override
  Duration? get eventThrottleInterval => null;

  @override
  Duration get stallIndicatorDelay => const Duration(milliseconds: 1000);

  @override
  VlcBackgroundPolicy get backgroundPolicy => VlcBackgroundPolicy.pause;

  @override
  bool get isAttached => true;

  @override
  List<VlcMediaSource> get playlist => const <VlcMediaSource>[];

  @override
  int? get playlistIndex => null;

  @override
  VlcPlaylistLoopMode get playlistLoopMode => VlcPlaylistLoopMode.none;

  @override
  VlcMediaSource? get currentMediaSource => null;

  @override
  bool get hasNext => false;

  @override
  bool get hasPrevious => false;

  @override
  int get seekRequests => _seekRequests;

  @override
  int get pauseRequests => _pauseRequests;

  @override
  VlcPlaybackClock get playbackClock => _clock;

  @override
  ValueListenable<Duration?> get pendingSeekTarget => _pendingSeekTarget;

  @override
  ValueListenable<bool> get isPictureInPicture => _pictureInPicture;

  @override
  String? get lastPipError => null;

  @override
  bool? get lastPipPossible => null;

  // -- transport ------------------------------------------------------------

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    _pauseRequests++;
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    _pauseRequests++;
    await _player.stop();
  }

  @override
  Future<void> seekTo(Duration position) async {
    _seekRequests++;
    final target = position < Duration.zero ? Duration.zero : position;
    _pendingSeekTarget.value = target;
    await _player.seek(target);
  }

  @override
  Future<void> seekToWindowFraction(double fraction) async {
    // Live windows are not modelled on mpv: the screen never offers a live
    // seek, and a stray one does nothing rather than throwing.
  }

  @override
  Future<void> setVolume(int volume) async {
    await _player.setVolume(volume.clamp(0, 200).toDouble());
    publish();
  }

  @override
  Future<void> setPlaybackSpeed(double speed) async {
    await _player.setRate(speed);
    publish();
  }

  @override
  Future<void> setFit(VlcVideoFit fit) async {
    _fit = fit;
    publish();
  }

  /// The fit the screen last asked for, so it can draw the video to match.
  VlcVideoFit get fit => _fit;

  @override
  Future<void> setAudioDelay(Duration delay) async {
    // media_kit 1.2.6 exposes no audio-delay API. A no-op, honestly: the
    // value stays zero, so the panel's stepper shows 0 and does nothing.
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    // media_kit 1.2.6 exposes no subtitle-delay API. See [setAudioDelay].
  }

  @override
  Future<bool> setSubtitleLook(VlcSubtitleLook look) async {
    // The look stays with the controller, as on libVLC; the screen draws
    // it through media_kit's SubtitleViewConfiguration. Bumping the
    // revision tells the panel the style moved.
    _subtitleLook = look;
    _trackRevision++;
    publish();
    return true;
  }

  /// The last subtitle look asked for, if any.
  VlcSubtitleLook? get subtitleLook => _subtitleLook;

  @override
  void setDurationCap(Duration? cap) {
    _durationCap = cap;
    publish();
  }

  // -- picture-in-picture (not available on mpv) ----------------------------

  @override
  Future<bool> startPictureInPicture({Rect? sourceRect}) async => false;

  @override
  void notePictureInPictureImminent() {}

  @override
  Future<void> stopPictureInPicture() async {}

  // -- media (the screen drives mpv directly; these are not used) ----------

  @override
  Future<void> setMedia(
    VlcMediaSource source, {
    bool autoPlay = false,
    bool keepPicture = false,
  }) async {
    throw UnimplementedError('The mpv screen opens media on the Player.');
  }

  @override
  Future<void> setPlaylist(
    List<VlcMediaSource> sources, {
    int initialIndex = 0,
    bool autoPlay = false,
    bool autoAdvance = true,
    VlcPlaylistLoopMode loopMode = VlcPlaylistLoopMode.none,
  }) async {
    throw UnimplementedError('No playlist on the mpv player.');
  }

  @override
  Future<bool> next({bool autoPlay = true}) async => false;

  @override
  Future<bool> previous({bool autoPlay = true}) async => false;

  @override
  Future<void> jumpTo(int index, {bool autoPlay = true}) async {
    throw StateError('No playlist on the mpv player.');
  }

  @override
  Future<void> addToPlaylist(VlcMediaSource source) async {
    throw StateError('No playlist on the mpv player.');
  }

  @override
  Future<void> insertIntoPlaylist(int index, VlcMediaSource source) async {
    throw StateError('No playlist on the mpv player.');
  }

  @override
  Future<void> removeFromPlaylistAt(int index, {bool autoPlay = true}) async {
    throw StateError('No playlist on the mpv player.');
  }

  @override
  Future<void> clearPlaylist() async {}

  @override
  Future<void> shufflePlaylist({int? seed}) async {
    throw StateError('No playlist on the mpv player.');
  }

  @override
  Future<Uint8List> takeSnapshot({int? width, int? height}) async {
    throw UnimplementedError('No snapshot on the mpv player.');
  }

  @override
  Future<VlcMediaStats> getMediaStats() async {
    throw UnimplementedError('No media stats on the mpv player.');
  }

  // -- tracks ---------------------------------------------------------------

  @override
  Future<List<VlcTrackDescription>> getAudioTracks() async {
    return <VlcTrackDescription>[
      for (var i = 0; i < _audioTracks.length; i++)
        VlcTrackDescription(
          // The track's real mpv aid — never the list position (see
          // [_trackId]): the drawer shows this id, and the tap sets it.
          id: _trackId(_audioTracks[i].id, i),
          name: _trackDisplayName(
            title: _audioTracks[i].title,
            language: _audioTracks[i].language,
            // A track with no title and no language reads as plain
            // "Audio" — never "Audio 1" / "Audio 2".
            fallback: 'Audio',
          ),
          language: _audioTracks[i].language,
          channels: _audioTracks[i].channelscount,
        ),
    ];
  }

  @override
  Future<void> setAudioTrack(int id) async {
    // By mpv aid, not by list position: the position of a track in the
    // list moves while an HLS master settles, the aid does not. The id
    // compared here is the same one [getAudioTracks] publishes for the
    // track (see [_trackId]).
    AudioTrack? track;
    for (var i = 0; i < _audioTracks.length; i++) {
      if (_trackId(_audioTracks[i].id, i) == id) {
        track = _audioTracks[i];
        break;
      }
    }
    if (track == null) return;
    await _player.setAudioTrack(track);
    publish();
  }

  @override
  Future<List<VlcTrackDescription>> getSubtitleTracks() async {
    final embedded = _embeddedSubtitles;
    final external = _externalSubtitlesDeduped;
    return <VlcTrackDescription>[
      for (var i = 0; i < embedded.length; i++)
        VlcTrackDescription(
          // The track's real mpv sid — never the list position (see
          // [_trackId]): the drawer shows this id, and the tap sets it.
          id: _trackId(embedded[i].id, i),
          name: _trackDisplayName(
            title: embedded[i].title,
            language: embedded[i].language,
            // A track with no title and no language reads as plain
            // "Subtitle" — never "Subtitle 1" / "Subtitle 2".
            fallback: 'Subtitle',
          ),
          language: embedded[i].language,
        ),
      for (var i = 0; i < external.length; i++)
        VlcTrackDescription(
          id: _externalIdBase + i,
          name: '${external[i].label} (source)',
          language: external[i].lang,
        ),
    ];
  }

  @override
  Future<void> setSubtitleTrack(int id) async {
    if (id >= _externalIdBase) {
      final external = _externalSubtitlesDeduped;
      final index = id - _externalIdBase;
      if (index < 0 || index >= external.length) return;
      final file = external[index];
      await _player.setSubtitleTrack(
        SubtitleTrack.uri(file.url, title: file.label),
      );
      publish();
      return;
    }
    // By mpv sid, not by list position (see [setAudioTrack]).
    final embedded = _embeddedSubtitles;
    SubtitleTrack? track;
    for (var i = 0; i < embedded.length; i++) {
      if (_trackId(embedded[i].id, i) == id) {
        track = embedded[i];
        break;
      }
    }
    if (track == null) return;
    await _player.setSubtitleTrack(track);
    publish();
  }

  @override
  Future<void> disableSubtitle() async {
    await _player.setSubtitleTrack(SubtitleTrack.no());
    publish();
  }

  @override
  Future<void> addSubtitle(Uri uri) async {
    await _player.setSubtitleTrack(SubtitleTrack.uri(uri.toString()));
    _trackRevision++;
    publish();
  }

  @override
  Future<VlcMediaInfo> getMediaInfo() async {
    // The panel's detail line (codec · channels · bitrate, e.g. `5.1`)
    // comes from these lists, correlated by position with the track
    // descriptions. mpv used to return only title + duration, so the
    // detail line was always empty; the codec, language and channel count
    // are all on media_kit's tracks, so they are reported here.
    return VlcMediaInfo(
      title: _mediaTitle(),
      duration: _value.duration,
      audioTracks: <VlcMediaTrackInfo>[
        for (final track in _audioTracks)
          VlcMediaTrackInfo(
            type: 'audio',
            codec: track.codec,
            language: track.language,
            bitrate: track.bitrate,
            channels: _audioChannelCount(track),
            sampleRate: track.samplerate,
          ),
      ],
      subtitleTracks: <VlcMediaTrackInfo>[
        for (final track in _embeddedSubtitles)
          VlcMediaTrackInfo(
            type: 'subtitle',
            language: track.language,
          ),
      ],
    );
  }
}
