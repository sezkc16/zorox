/// The PREMIUM GOLDEN player UI, on the mpv engine (via media_kit).
///
/// The stock chrome ([VlcPlayerControls] + [PlayerPanel]) replaced by the
/// golden design the user asked for (ChatGPT spec + mockup): black #080808
/// with champagne gold #D4AF37, dark top/bottom gradients, a thin golden
/// seekbar, rounded floating buttons, 200–300 ms fades. The engine is the
/// v18-mpv one: 512 MiB forward + backward demuxer cache, VideoToolbox
/// hardware decode, ±10 s seek, pause keeps the position.
///
/// What this build carries over the stock player:
///   * the golden overlay ([GoldenPlayerControls]): top bar (Back, title,
///     season/episode, subtitle style, Episodes, More), centre transport
///     (−10 s, gold play/pause, +10 s), bottom golden seekbar + times and
///     the utility row (prev/next, CC, volume, speed, lock, aspect,
///     rotate), single-tap show/hide with a 3 s auto-hide, double-tap
///     ±10 s, right-side long-press 2x (gold "▶▶ 2x" pill, exact speed
///     restored on release), pinch zoom, skip-intro/outro chip;
///   * the golden right-side drawers: Episodes (season selector, real
///     episode data, gold highlight on the playing row, resume bar),
///     Subtitle Style (size, colour, font, bold, background, outline,
///     position + nudge, opacity, encoding, reset — all live on mpv),
///     Audio & Sources (track and source lists);
///   * skip-intro/outro chips, the up-next countdown, and the ended card;
///   * subtitles that sit low and at full size: media_kit's SubtitleView
///     caches its padding at creation and scales text down on phones, so
///     the screen pushes the padding through VideoState.setSubtitleViewPadding
///     and the configuration uses a 1.0 text scaler — the Position slider
///     and +5/−5 nudge move the caption live.
///   * Continue Watching resume (a [PlaybackProgressRecorder] fed from the
///     same samples as the tracker), the source list in portrait before
///     play, Back stopping the audio and returning to portrait, no centre
///     "+10s"/"−10s" pop-up, and the pre-play source list with auto-play
///     of the first working source.
///
/// What it deliberately does NOT carry (mpv limits, reported honestly):
///   * PiP — no PiP button; mpv renders through a Metal texture, not an
///     AVPlayerLayer (see the v18 header). Audio keeps playing in the
///     background (the app declares the `audio` background mode).
///   * Cast — no cast button; media_kit has no cast in this app.
///   * Subtitle/audio delay — media_kit 1.2.6 exposes no delay API, so
///     there is no delay control (the stock panel's steppers were no-ops
///     showing 0).
///   * HLS quality picker — mpv's ABR picks the rendition; no Quality tab.
///   * Side-car subtitle download, ClearKey DRM, torrent files.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/skip_segments.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/subtitle_search_target.dart';
import '../player_platform_service.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/ended_card.dart';
import '../vlc/next_episode_countdown.dart';
import '../vlc/panel/player_panel_data.dart';
import '../vlc/panel/player_panel_labels.dart';
import '../vlc/player_startup_view.dart';
import 'golden_player_controls.dart';
import 'mpv_subtitle_style.dart';
import 'mpv_vlc_controller.dart';

/// mpv demuxer cache, forward AND backward, in bytes.
///
/// media_kit maps `PlayerConfiguration.bufferSize` to mpv's
/// `demuxer-max-bytes` and `demuxer-max-back-bytes`, so this one value is
/// both how far ahead the engine pre-buffers and how much already-played
/// data it keeps for a backward seek. 512 MiB matches v17's libVLC prefetch
/// ring, so the engine comparison is on the same window.
const int kMpvBufferSize = 512 * 1024 * 1024;

/// How long an opened stream gets to show playback before it counts as dead
/// and the failover moves to the next candidate.
const Duration _kStartupWatchdog = Duration(seconds: 12);

/// How long the pre-play source list stays up with its rows painted before
/// the first source auto-plays. The streams are preloaded, so resolution is
/// fast and the list would otherwise flash past unseen — the viewer must see
/// the list (and get a chance to tap a row) before the video starts. This is
/// a floor on visibility, not a forced wait: a tap still opens at once.
const Duration _kMinListVisible = Duration(milliseconds: 3000);

/// Pinch-zoom range, same as the VLC screen.
const double _kMinZoom = 0.5;
const double _kMaxZoom = 3.0;

enum _Stage { resolving, playing, failed }

/// The stock player screen, on the mpv engine. Same constructor as
/// VlcPlayerScreen so the route can point at either.
class MpvPlayerScreen extends ConsumerStatefulWidget {
  const MpvPlayerScreen({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
    super.key,
  });

  final MultimediaItem item;

  /// The plugin's resolution token, not a URL. See [resolvePlayback].
  final String videoUrl;

  final Episode? episode;

  /// Sources already aggregated by a source sheet. When present, no plugin
  /// call is made.
  final List<StreamResult>? preloadedStreams;

  @override
  ConsumerState<MpvPlayerScreen> createState() => _MpvPlayerScreenState();
}

class _MpvPlayerScreenState extends ConsumerState<MpvPlayerScreen>
    with WidgetsBindingObserver {
  /// The engine. Created once per screen; disposed with it.
  late final Player _player;
  late final VideoController _videoController;

  /// The stock UI's view of the engine. Created with the player; fed from
  /// every mpv state change via [_publishAdapter].
  late final MpvVlcController _adapter;

  _Stage _stage = _Stage.resolving;
  String? _error;

  /// Candidates in failover order, and which one is open.
  List<StreamResult> _streams = const [];
  int _streamIndex = 0;
  final Set<int> _failedStreams = <int>{};

  /// What the reachability check found per source, while resolving: the
  /// original SkyStream's rows read "Checking…" (spinner) while a source is
  /// probed, then a green check when it answers — the viewer watches the
  /// sources resolve and picks one before anything plays. mpv used to mark
  /// every row `notChecked` (blank), so the list said nothing and flashed
  /// past. Fed by `resolvePlayback`'s `onProbe`, cleared per resolve.
  final Map<int, ProbeOutcome> _probes = <int, ProbeOutcome>{};

  /// The row the viewer picked during the probe race, if any. A pick during
  /// the race must not be overruled when the resolve returns: the resolver's
  /// index is only the auto-pick, and the viewer's pick is already opening.
  int? _pickedIndex;

  /// True once this resolve has returned its streams and index. Before that
  /// (the probe race) no row is "being opened", so no row reads "Opening…" —
  /// the original leaves every playState blank until the first open starts.
  bool _resolveDone = false;
  StreamResult? get _selected =>
      _streams.isEmpty ? null : _streams[_streamIndex];

  /// Where to resume, resolved once before the first open.
  Duration _resumePosition = Duration.zero;

  /// Progress tracking (history, scrobbling, watched) — the same tracker the
  /// VLC screen uses, fed from mpv's state stream.
  PlaybackTracker? _tracker;
  int _sessionToken = 0;

  /// Continue Watching: the recorder is fed the same samples as the tracker
  /// and flushed (past its rate limit) on pause, on teardown, and when the
  /// app goes away — so Back from a point resumes from that point.
  PlaybackProgressRecorder? _recorder;
  ProgressSample? _sample;
  bool _recordedLivestream = false;

  /// Last good state, for the UI and the tracker. Buffering and completion
  /// are read off the engine by the adapter (which publishes them as the
  /// stock value), so they are not kept here.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _isLive = false;

  /// Which source the subtitle auto-select has already run for.
  int _subtitleAppliedFor = -1;

  /// The audio/subtitle picks the viewer made in the panel, re-applied when
  /// a failover opens a new source (mpv resets tracks to auto on open).
  int? _rememberedAudioId;
  int? _rememberedSubtitleId;

  /// True once playback has actually started for the open source (used by the
  /// startup watchdog).
  bool _startedPlaying = false;
  Timer? _watchdogTimer;

  /// The chrome's auto-hide clock, owned here and lent to the controls.
  late final ChromeVisibilityController _chrome;

  /// The video view's key, so the screen can push the subtitle padding
  /// into it — media_kit's SubtitleView caches its padding at creation
  /// and never re-reads the configuration (see _syncSubtitlePadding).
  final GlobalKey<VideoState> _videoKey = GlobalKey<VideoState>();

  /// The subtitle padding last pushed into the video view, so the sync
  /// only calls the view when the padding actually moved.
  EdgeInsets? _lastSubtitlePadding;

  /// The screen height last seen in build. The padding sync runs from a
  /// post-frame callback and from the chrome listener — outside build —
  /// so it reads the height from here instead of calling MediaQuery
  /// (an inherited-widget read) off the build path.
  double _lastScreenHeight = 0;

  /// The pinch zoom's value, owned here and written by the controls'
  /// gesture layer; the Transform over the video reads it.
  final ValueNotifier<double> _videoScale = ValueNotifier<double>(1.0);

  /// The video fit, owned here; the controls report changes through
  /// onFitChanged and the video widget reads it.
  VlcVideoFit _fit = VlcVideoFit.contain;

  /// Fraction of the media fetched ahead of the playhead, for the seek
  /// bar's buffered band.
  final ValueNotifier<double> _bufferedFraction =
      ValueNotifier<double>(0.0);

  /// Whether this media has a subtitle to pick — an embedded track the
  /// engine has published, or a file the source shipped. The subtitles
  /// button is only there when there is one.
  final ValueNotifier<bool> _hasSubtitles = ValueNotifier<bool>(false);

  /// Whether the screen is locked against accidental touches.
  final ValueNotifier<bool> _locked = ValueNotifier<bool>(false);

  /// What the side panel shows, published from every place it changes.
  final ValueNotifier<PanelData> _panelData =
      ValueNotifier<PanelData>(PanelData.empty);

  /// Intro/outro bands, usually empty — both sources are opt-in.
  List<SkipSegment> _skipSegments = const <SkipSegment>[];

  /// The episode being played, and the route token for it. Both move on an
  /// advance; the panel and the next/previous arrows read them.
  Episode? _currentEpisode;
  late String _currentVideoUrl;

  /// An episode advance in flight.
  bool _advancing = false;

  /// The up-next card's episode, or null when no card is up.
  Episode? _nextEpisodeOffer;

  /// The viewer pressed Cancel on the up-next card.
  bool _nextEpisodeDeclined = false;

  /// The ended card's kind, or null when no card is up.
  EndedKind? _ended;

  /// The settings, live, for the panel's Subtitle style page. Updated from
  /// the provider (see [_init]); the panel reads this, not the provider.
  late final ValueNotifier<PlayerSettings> _playerSettings;

  /// Last position-update setState, so mpv's frequent ticks do not rebuild
  /// the whole screen at full rate.
  DateTime _lastPositionUi = DateTime.fromMicrosecondsSinceEpoch(0);

  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool get _isSeries =>
      widget.item.contentType == MultimediaContentType.series ||
      widget.item.contentType == MultimediaContentType.anime;

  bool get _isEpisodic => _isSeries && _currentEpisode != null;

  bool get _canSeek => _duration > Duration.zero && !_isLive;

  /// Whether an episode follows this one. Recomputed rather than cached so
  /// it cannot go stale after an advance.
  bool get _hasNextEpisode =>
      nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _currentVideoUrl,
      ).next !=
      null;

  Episode? get _previousEpisode => previousEpisodeFor(
    item: widget.item,
    current: _currentEpisode,
    videoUrl: _currentVideoUrl,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentEpisode = widget.episode;
    _currentVideoUrl = widget.videoUrl;
    // No landscape here: the source list shown before play stays portrait,
    // and landscape is forced only when the video itself first starts
    // playing (see the playing listener).
    _chrome = ChromeVisibilityController(
      isPlaying: () => _adapter.value.isPlaying,
    );
    // The chrome showing/hiding moves the caption's bottom padding, so
    // the padding is pushed into the video view on every change.
    _chrome.addListener(_onChromeVisibilityChanged);
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    // Order matters: write first, tear down second. A stop after the write
    // halts the audio now — the async dispose alone left it running after
    // the screen was gone.
    _flushProgress();
    try {
      _tracker?.finish();
    } catch (_) {
      // Tracking must never block leaving the player.
    }
    _chrome.removeListener(_onChromeVisibilityChanged);
    _chrome.dispose();
    _videoScale.dispose();
    _bufferedFraction.dispose();
    _hasSubtitles.dispose();
    _locked.dispose();
    _panelData.dispose();
    _playerSettings.dispose();
    unawaited(_player.stop());
    unawaited(_player.dispose());
    _adapter.dispose();
    _restoreOrientation();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !mounted) return;
    // A backstop behind the pause flush: the position at the moment the
    // app goes away is the one Continue Watching must have.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _flushProgress();
    }
  }

  void _forceLandscapeIfPortrait() {
    final size = MediaQuery.sizeOf(context);
    if (size.width < size.height) {
      unawaited(
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]),
      );
    }
  }

  void _restoreOrientation() {
    // Force portrait on the way out: the player is the only landscape
    // screen, and DeviceOrientation.values (all) does NOT rotate the
    // device — it just lifts the pin, so the app stays sideways in
    // landscape after Back. portraitUp rotates it back upright.
    unawaited(
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]),
    );
  }

  /// Leaves the player: stop the audio first, then portrait (so the rotation
  /// starts with the exit transition), then the pop. dispose() repeats the
  /// stop and the portrait as a safety net for a route that went any other
  /// way.
  void _goBack() {
    _flushProgress();
    unawaited(_player.stop());
    _restoreOrientation();
    if (mounted) Navigator.of(context).pop();
  }

  /// Writes the last known-good sample, bypassing the rate limit.
  void _flushProgress() {
    final sample = _sample;
    final recorder = _recorder;
    if (sample == null || recorder == null) return;
    recorder.record(sample, lastStreamUrl: _selected?.url, force: true);
  }

  Future<void> _init() async {
    // media_kit must be initialized before the first Player; main() already
    // does this, but the screen is usable on its own too.
    try {
      MediaKit.ensureInitialized();
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'mpv could not start: $e';
        });
      }
      return;
    }

    _player = Player(
      configuration: const PlayerConfiguration(
        // Forward AND backward demuxer cache (see kMpvBufferSize).
        bufferSize: kMpvBufferSize,
      ),
    );
    try {
      _videoController = VideoController(
        _player,
        configuration: const VideoControllerConfiguration(
          // VideoToolbox hardware decode (4K HEVC/HDR) + Metal rendering.
          hwdec: 'videotoolbox',
          enableHardwareAcceleration: true,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = 'mpv video output could not start: $e';
        });
      }
      return;
    }

    _adapter = MpvVlcController(
      player: _player,
      externalSubtitles: () => _selected?.subtitles ?? const [],
      mediaTitle: () => widget.item.title,
    );

    // The panel's copy of the settings, kept live from the provider.
    final settings =
        ref.read(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    _playerSettings = ValueNotifier<PlayerSettings>(settings);
    ref.listenManual<AsyncValue<PlayerSettings>>(
      playerSettingsProvider,
      (_, next) {
        final value = next.asData?.value;
        if (value != null && !_disposed) _playerSettings.value = value;
      },
    );

    _listen();
    await _resolveAndOpen();
  }

  void _listen() {
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        _playing = playing;
        if (playing) {
          final firstPlay = !_startedPlaying;
          _startedPlaying = true;
          _watchdogTimer?.cancel();
          if (firstPlay) {
            // First frame of playback: the video itself has started, so
            // now — and only now — rotate to landscape on a portrait
            // handset. The source list shown before this stays portrait.
            _forceLandscapeIfPortrait();
            // And the source list's job is done: the video is up.
            if (_stage == _Stage.resolving) {
              _stage = _Stage.playing;
            }
          }
        } else {
          _tracker?.onPaused();
          // Pausing is the viewer's own save point, so flush past the
          // rate limit. A stall that auto-pauses the engine flushes the
          // same way — the position is real either way.
          _flushProgress();
        }
        _publishAdapter();
        _chrome.poke();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.position.listen((position) {
        if (_disposed) return;
        _position = position;
        // Feed the tracker and the Continue Watching recorder from the
        // same sample: only samples taken while playing count toward
        // history / watched, and the token ties them to this session.
        if (_playing && _duration > Duration.zero) {
          final sample = ProgressSample(
            position: position,
            duration: _duration,
            token: _sessionToken,
          );
          _tracker?.onPlaying(sample);
          if (sample.isWritable) {
            _sample = sample;
            _recorder?.record(sample, lastStreamUrl: _selected?.url);
          }
        }
        // A livestream has no position to store, but Continue Watching
        // still needs the row.
        if (!_recordedLivestream &&
            widget.item.contentType == MultimediaContentType.livestream) {
          _recordedLivestream = true;
          _recorder?.recordLivestream();
        }
        _publishAdapter();
        // Throttle UI rebuilds: the bar only needs ~5 updates a second.
        final now = DateTime.now();
        if (now.difference(_lastPositionUi) >=
            const Duration(milliseconds: 200)) {
          _lastPositionUi = now;
          setState(() {});
        }
      }),
    );
    _subs.add(
      _player.stream.duration.listen((duration) {
        if (_disposed) return;
        _duration = duration;
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffer.listen((buffered) {
        if (_disposed) return;
        _buffered = buffered;
        _bufferedFraction.value = _canSeek
            ? (_buffered.inMilliseconds / _duration.inMilliseconds).clamp(
                0.0,
                1.0,
              )
            : 0.0;
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffering.listen((_) {
        if (_disposed) return;
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.completed.listen((completed) {
        if (_disposed) return;
        if (completed) {
          _flushProgress();
          try {
            _tracker?.finish();
          } catch (_) {}
          _chrome.poke();
          _onEnded();
        }
        _publishAdapter();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((_) {
        if (_disposed) return;
        _applyRememberedTracks();
        _applySubtitleAutoSelect();
        _updateHasSubtitles();
        _adapter.noteTracksChanged();
        _publishPanelData();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.error.listen((message) {
        if (_disposed) return;
        if (kDebugMode) debugPrint('mpv error: $message');
        _adapter.noteError(message);
        // A dead source fails over; an error mid-play just shows in the log
        // — the watchdog owns startup, and a mid-play error is usually a
        // transient network hiccup mpv recovers from on its own.
        if (!_startedPlaying) _tryNextStream();
      }),
    );
  }

  /// Rebuilds the adapter's published value from the engine's state, so
  /// the stock chrome and panel always read mpv's truth.
  void _publishAdapter() {
    if (_disposed) return;
    _adapter.publish();
  }

  Future<void> _resolveAndOpen() async {
    if (_disposed) return;
    // A fresh resolve: no probes yet, no pick, no row "being opened".
    _probes.clear();
    _pickedIndex = null;
    _resolveDone = false;
    try {
      final resolved = await resolvePlayback(
        read: ref.read,
        item: widget.item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: widget.preloadedStreams,
        // The original's list appears as soon as the candidates arrive and
        // its rows update live as each source is probed — the viewer watches
        // the sources resolve and picks one before anything plays. mpv used
        // to pass neither callback, so the list only appeared AFTER the
        // whole resolve (probe race included) had returned, and every row
        // read blank. Now the candidates land early and each probe answer
        // rebuilds the list, exactly as the stock screen narrates them.
        onCandidates: (streams) {
          if (_disposed) return;
          _streams = streams;
          _publishPanelData();
          if (mounted) setState(() {});
        },
        onProbe: (index, outcome) {
          if (_disposed) return;
          _probes[index] = outcome;
          if (mounted) setState(() {});
        },
      );
      final resume = await resolveResumePoint(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
      );
      if (_disposed) return;
      _streams = resolved.streams;
      _resolveDone = true;
      // The viewer picked a row during the probe race: it is already
      // opening (see _pickFromStartup), so do not overrule it with the
      // resolver's auto-pick and do not open a second source. Without
      // this the assignment below would overwrite the pick.
      if (_pickedIndex != null) return;
      _streamIndex = resolved.index;
      _resumePosition = resume?.position ?? Duration.zero;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      _publishPanelData();
      // The list must be SEEN, not flashed: the streams are preloaded, so
      // resolution is fast, and until now nothing rebuilt the screen with
      // the rows — the first rebuild came from _openStream's trailing
      // setState, by which time the first frame was imminent and the list
      // was skipped entirely. Rebuild now, wait for the populated list to
      // paint, then hold it for a beat before the first source auto-plays.
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (_disposed) return;
      final listPaintedAt = DateTime.now();
      unawaited(_loadSkipSegments(_currentEpisode));
      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: ++_sessionToken,
      );
      _recorder = PlaybackProgressRecorder(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
        token: _sessionToken,
      );
      final listVisibleFor = DateTime.now().difference(listPaintedAt);
      if (listVisibleFor < _kMinListVisible) {
        await Future<void>.delayed(_kMinListVisible - listVisibleFor);
      }
      if (_disposed) return;
      // A row tapped during the hold already opened its source; do not
      // overrule the viewer's pick with the auto-pick.
      if (_streamIndex != resolved.index) return;
      await _openStream(_streamIndex, start: _resumePosition);
    } on StreamResolutionException catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = describeStreamFailure(AppLocalizations.of(context)!, e);
      });
      _publishPanelData();
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'Could not load sources: $e';
      });
      _publishPanelData();
    }
  }

  Future<void> _openStream(int index, {Duration? start}) async {
    if (_disposed || _streams.isEmpty) return;
    _streamIndex = index;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _adapter.clearError();
    final stream = _streams[index];
    _sessionToken++;
    _tracker = PlaybackTracker(
      read: ref.read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
      token: _sessionToken,
    );
    _recorder = PlaybackProgressRecorder(
      read: ref.read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
      token: _sessionToken,
    );
    _sample = null;
    _publishPanelData();
    try {
      await _player.open(
        Media(
          stream.url,
          httpHeaders: stream.headers,
          start: start != null && start > Duration.zero ? start : null,
        ),
        play: true,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('mpv open failed: $e');
      _failedStreams.add(index);
      _publishPanelData();
      _tryNextStream();
      return;
    }
    _armWatchdog();
    if (mounted) setState(() {});
  }

  void _armWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(_kStartupWatchdog, () {
      if (_disposed || _startedPlaying) return;
      // Nothing is playing after the budget: this source is dead.
      if (kDebugMode) {
        debugPrint('mpv watchdog: no playback in $_kStartupWatchdog');
      }
      _failedStreams.add(_streamIndex);
      _publishPanelData();
      _tryNextStream();
    });
  }

  void _tryNextStream() {
    if (_disposed) return;
    final next = _streamIndex + 1;
    if (next >= _streams.length) {
      setState(() {
        _stage = _Stage.failed;
        _error = 'No working source found.';
      });
      _publishPanelData();
      return;
    }
    // Fail over near where the viewer was, rather than from the top.
    final resumeAt = _position > const Duration(seconds: 5)
        ? _position
        : Duration.zero;
    unawaited(_openStream(next, start: resumeAt));
  }

  /// A row picked on the startup list, before anything is playing: open
  /// that source instead of the one the auto-open chose. The list stays up
  /// until the picked source plays, so a pick that fails falls over to the
  /// next one the same way. The pick is remembered so a resolve still
  /// running cannot overrule it when it returns (see _resolveAndOpen).
  void _pickFromStartup(int index) {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex && !_startedPlaying) return;
    _pickedIndex = index;
    unawaited(_openStream(index, start: _position));
  }

  /// A source picked in the panel's Sources tab: open it from where the
  /// viewer was, as the stock screen does.
  Future<void> _pickSource(int index) async {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex) return;
    await _openStream(index, start: _position);
  }

  /// Re-applies the audio/subtitle picks the viewer made in the panel, when
  /// a new source reports its tracks (mpv resets tracks to auto on open).
  void _applyRememberedTracks() {
    final audioId = _rememberedAudioId;
    if (audioId != null) {
      unawaited(_adapter.setAudioTrack(audioId));
    }
    final subtitleId = _rememberedSubtitleId;
    if (subtitleId != null) {
      unawaited(_adapter.setSubtitleTrack(subtitleId));
    }
  }

  /// Picks a subtitle without being asked: the plugin's own subtitle file
  /// first (usually the right language), else the first embedded track.
  /// Runs once per source, when mpv reports its tracks — and never over a
  /// pick the viewer already made.
  void _applySubtitleAutoSelect() {
    if (_disposed || _subtitleAppliedFor == _streamIndex) return;
    if (_rememberedSubtitleId != null) {
      _subtitleAppliedFor = _streamIndex;
      return;
    }
    final stream = _selected;
    if (stream == null) return;
    final embedded = _player.state.tracks.subtitle;
    final external = stream.subtitles ?? const [];
    if (external.isNotEmpty) {
      final first = external.first;
      unawaited(
        _player.setSubtitleTrack(
          SubtitleTrack.uri(first.url, title: first.label),
        ),
      );
      _subtitleAppliedFor = _streamIndex;
      return;
    }
    if (embedded.isNotEmpty) {
      unawaited(_player.setSubtitleTrack(embedded.first));
      _subtitleAppliedFor = _streamIndex;
    }
  }

  /// Whether the subtitles button shows at all: only when this media has a
  /// subtitle to pick — an embedded track, or a file the source shipped.
  void _updateHasSubtitles() {
    final embedded = _player.state.tracks.subtitle;
    final external = _selected?.subtitles ?? const [];
    _hasSubtitles.value = embedded.isNotEmpty || external.isNotEmpty;
  }

  /// Looks up intro/outro segments in the background.
  ///
  /// Never awaited by the open path: both sources are network lookups
  /// against crowdsourced databases, and playback must not wait on a
  /// convenience.
  Future<void> _loadSkipSegments(Episode? episode) async {
    if (episode == null) return;
    final segments = await fetchSkipSegments(
      read: ref.read,
      item: widget.item,
      episode: episode,
    );
    if (_disposed || segments.isEmpty) return;
    setState(() => _skipSegments = segments);
  }

  // -- panel ---------------------------------------------------------------

  /// What the side panel shows, published from every place it changes.
  void _publishPanelData() {
    if (_disposed) return;
    _panelData.value = PanelData(
      sources: _streams,
      currentSourceIndex: _stage == _Stage.failed ? -1 : _streamIndex,
      failedSources: Set<int>.unmodifiable(_failedStreams),
      playedSources: _startedPlaying
          ? <int>{_streamIndex}
          : const <int>{},
      // mpv's ABR picks the rendition: no quality ladder, so no Quality tab.
      qualityLadder: const <int>[],
      episodes: effectiveEpisodes(widget.item, _currentEpisode),
      currentEpisode: _currentEpisode,
      subtitleTarget: SubtitleSearchTarget.of(widget.item, _currentEpisode),
    );
  }

  /// How much of [episode] the viewer has already seen, for the Episodes
  /// Episodes tab. Asked per row as the list builds it, never precomputed.
  EpisodeProgress _episodeProgressFor(Episode episode) {
    final mainUrl = widget.item.url;
    if (ref.read(episodeWatchRepositoryProvider).isWatched(mainUrl, episode)) {
      return const EpisodeProgress(watched: true);
    }
    final history = ref.read(historyRepositoryProvider);
    final duration = history.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    if (duration <= 0) return EpisodeProgress.none;
    final position = history.getEpisodePosition(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    return EpisodeProgress(fraction: (position / duration).clamp(0.0, 1.0));
  }

  /// How long [episode] is, for the Episodes drawer: the history's exact
  /// seconds first, else the plugin's runtime in minutes.
  Duration? _episodeDurationFor(Episode episode) {
    final mainUrl = widget.item.url;
    final history = ref.read(historyRepositoryProvider);
    final seconds = history.getEpisodeDuration(
      episode.url,
      mainUrl: mainUrl,
      season: episode.season,
      episode: episode.episode,
    );
    if (seconds > 0) return Duration(seconds: seconds);
    final runtime = episode.runtime;
    if (runtime != null && runtime > 0) return Duration(minutes: runtime);
    return null;
  }

  // -- episodes -------------------------------------------------------------

  /// Switches to another episode in place: the current episode's progress
  /// is flushed, the engine is stopped, and the new episode resolves and
  /// opens through the same startup list. A saved position on the new
  /// episode resumes from there.
  Future<void> _pickEpisode(Episode next) async {
    if (_disposed || _advancing || next == _currentEpisode) return;
    _advancing = true;
    try {
      _flushProgress();
      try {
        _tracker?.finish();
      } catch (_) {}
      rollForwardHistory(read: ref.read, item: widget.item, next: next);
      await _startEpisode(next);
    } finally {
      _advancing = false;
    }
  }

  /// The next episode, or the previous one, from the chrome's arrows.
  Future<void> _advance() async {
    if (_disposed || _advancing) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    await _pickEpisode(next);
  }

  Future<void> _goToPreviousEpisode() async {
    if (_disposed || _advancing) return;
    final previous = _previousEpisode;
    if (previous == null) return;
    await _pickEpisode(previous);
  }

  Future<void> _startEpisode(Episode next) async {
    _sample = null;
    _streams = const [];
    _streamIndex = 0;
    _failedStreams.clear();
    _probes.clear();
    _pickedIndex = null;
    _resolveDone = false;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _rememberedAudioId = null;
    _rememberedSubtitleId = null;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _resumePosition = Duration.zero;
    _recorder = null;
    _skipSegments = const <SkipSegment>[];
    _nextEpisodeOffer = null;
    _nextEpisodeDeclined = false;
    _ended = null;
    _currentEpisode = next;
    _currentVideoUrl = next.url;
    await _player.stop();
    if (_disposed) return;
    setState(() => _stage = _Stage.resolving);
    _publishPanelData();
    await _resolveAndOpen();
  }

  // -- ended / up-next ------------------------------------------------------

  /// The engine reached the end of the media. Everything that is a failure
  /// wearing an ending's clothes is caught before this (the watchdog, the
  /// failover); here the film or episode really finished.
  void _onEnded() {
    if (_disposed || !mounted) return;
    // A next episode, not yet declined: offer it (the countdown card).
    // Otherwise the ended card, finished or declined-next.
    if (_hasNextEpisode && !_nextEpisodeDeclined) {
      _offerNextEpisodeNow();
      return;
    }
    _showEnded(
      _nextEpisodeDeclined ? EndedKind.declinedNext : EndedKind.finished,
    );
  }

  /// Raises the up-next countdown card for the following episode.
  void _offerNextEpisodeNow() {
    if (_disposed || !mounted) return;
    if (_advancing || _isLive) return;
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    setState(() {
      _nextEpisodeDeclined = false;
      _nextEpisodeOffer = next;
    });
  }

  void _showEnded(EndedKind kind) {
    if (_disposed || !mounted || _ended == kind) return;
    // The card unmounts the whole controls subtree, and the unlock chip
    // goes with it, so a lock left standing here would have nothing on
    // screen to undo it.
    _locked.value = false;
    setState(() => _ended = kind);
  }

  /// Plays the finished media again, from the top.
  void _startOver() {
    if (_disposed) return;
    _sample = null;
    _nextEpisodeDeclined = false;
    _nextEpisodeOffer = null;
    setState(() => _ended = null);
    unawaited(_player.seek(Duration.zero));
    unawaited(_player.play());
  }

  // -- chrome text ----------------------------------------------------------

  /// What the top bar's subtitle says: the source the picture is coming
  /// from. Null where nothing is playing yet, and the bar then renders no
  /// second line at all rather than an empty one.
  String? _chromeSubtitle() {
    final data = _panelData.value;
    final index = data.currentSourceIndex;
    if (index < 0 || index >= data.sources.length) return null;
    final stream = data.sources[index];
    return sourceProvider(stream) ?? sourceFactsOf(stream).title;
  }

  /// "S1 E3 · Episode name", for the startup list.
  String? get _episodeLine {
    final episode = _currentEpisode;
    if (!_isSeries || episode == null) return null;
    return 'S${episode.season} E${episode.episode} · ${episode.name}';
  }

  /// The startup list's current row: the one being opened, or null while
  /// the probe race is still running (the original shows no row as current
  /// until the first open starts, unless the viewer picked one).
  int? get _startupCurrentIndex {
    if (_streams.isEmpty) return null;
    if (!_resolveDone && _pickedIndex == null) return null;
    return _streamIndex;
  }

  /// The startup list's rows, in the original's own terms: a source's
  /// reachability is what the probe race found for it — Checking… (spinner)
  /// while it is probed, a green check when it answers, Failed when it
  /// does not — and its playState is whether it is the one being opened or
  /// is already playing. The original's rows read this way because the
  /// stock screen feeds `resolvePlayback`'s `onProbe` into these same
  /// helpers; mpv now does too. Before the resolve returns (the probe
  /// race) no row is "being opened", so every playState is blank — the
  /// original leaves them blank until the first open starts.
  List<StartupRow> get _startupRows {
    return <StartupRow>[
      for (var i = 0; i < _streams.length; i++)
        StartupRow(
          label: _startupRowLabel(_streams[i]),
          reachability: sourceReachabilityOf(
            _streams[i],
            _probes[i],
            hasPlayed: _startedPlaying && i == _streamIndex,
          ),
          playState: sourcePlayStateOf(
            isCurrent:
                i == _streamIndex && (_resolveDone || _pickedIndex == i),
            hasPicture: _startedPlaying,
            failed: _failedStreams.contains(i),
          ),
        ),
    ];
  }

  /// The plugin's own label for the source, led by its provider, with the
  /// quality after it — "HubCloud · 1080p".
  String _startupRowLabel(StreamResult stream) {
    final base = sourceRowLabel(stream);
    final quality = stream.quality;
    return quality != null && quality > 0 ? '$base · ${quality}p' : base;
  }

  // -- build ----------------------------------------------------------------

  /// Flips the handset the other way for the rest of this video (rotate
  /// button). Only where the player turns the device at all.
  void _flipOrientation() {
    final orientation = MediaQuery.orientationOf(context);
    unawaited(
      SystemChrome.setPreferredOrientations([
        orientation == Orientation.landscape
            ? DeviceOrientation.landscapeRight
            : DeviceOrientation.landscapeLeft,
      ]),
    );
  }

  BoxFit _boxFitFor(VlcVideoFit fit) {
    return switch (fit) {
      VlcVideoFit.cover => BoxFit.cover,
      VlcVideoFit.fill => BoxFit.fill,
      _ => BoxFit.contain,
    };
  }

  /// The chrome showed or hid, so the caption's bottom padding moved
  /// (40px hidden, 116px up) — push it into the video view.
  void _onChromeVisibilityChanged() => _syncSubtitlePadding();

  /// Pushes the current subtitle padding into the video view.
  ///
  /// media_kit's [SubtitleView] caches its padding in a `late` field at
  /// creation and has no `didUpdateWidget`, so a rebuilt
  /// [SubtitleViewConfiguration] never reaches it — the caption stays
  /// wherever it was created (high) and the Position slider / +5/−5 nudge
  /// does nothing. The only update path is
  /// [VideoState.setSubtitleViewPadding]. This runs after every build
  /// (post-frame, so a settings change moves the caption) and whenever the
  /// chrome shows or hides. Guarded on the last pushed padding so it is a
  /// no-op when nothing moved.
  ///
  /// It never runs while the source list is up ([_Stage.resolving]): no
  /// caption is visible before the first frame, and the sync — a
  /// MediaQuery read plus a setState into the video view from outside the
  /// build — must not run during the resolving window, or the list never
  /// becomes visible (2.9.17+5 regression). Once the video is playing the
  /// post-frame callback in build and the chrome listener push it as
  /// before, so the caption sits low at full size and Position moves it
  /// live.
  void _syncSubtitlePadding() {
    if (_disposed || !mounted) return;
    if (_stage == _Stage.resolving) return;
    if (_lastScreenHeight <= 0) return;
    try {
      final settings =
          ref.read(playerSettingsProvider).asData?.value ??
          const PlayerSettings();
      final padding = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: _lastScreenHeight,
        controlsVisible: _chrome.value,
      ).padding;
      if (padding == _lastSubtitlePadding) return;
      _lastSubtitlePadding = padding;
      _videoKey.currentState?.setSubtitleViewPadding(padding);
    } catch (_) {
      // A subtitle-sync failure must never break the player.
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The saved subtitle style, watched so a Style-tab change restyles the
    // caption live. An unloaded provider reads as a fresh install.
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    // The subtitle configuration for the video view. The view caches its
    // padding at creation (see _syncSubtitlePadding), so a changed
    // configuration alone does not move the caption — push the new padding
    // after the frame, only if it moved. The height is cached for the sync
    // (it runs off the build path), and the callback is only armed once the
    // video is playing: while the source list is up no caption is visible,
    // and the sync must not run during the resolving window.
    final screenHeight = MediaQuery.sizeOf(context).height;
    _lastScreenHeight = screenHeight;
    final subtitleConfig = mpvSubtitleViewConfiguration(
      settings,
      screenHeight: screenHeight,
      controlsVisible: _chrome.value,
    );
    if (_stage != _Stage.resolving &&
        subtitleConfig.padding != _lastSubtitlePadding) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _syncSubtitlePadding(),
      );
    }
    final profile = ref.watch(deviceProfileProvider).asData?.value;
    final form = playerFormFactorOf(profile);
    final canRotate = playerCanRotate(profile);
    final isTv = form == PlayerFormFactor.tv;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video. The pinch zoom is a Transform over the picture, driven by
          // the controls' gesture layer through [_videoScale].
          ValueListenableBuilder<double>(
            valueListenable: _videoScale,
            builder: (context, scale, child) => Transform.scale(
              scale: scale.clamp(_kMinZoom, _kMaxZoom),
              alignment: Alignment.center,
              child: child,
            ),
            child: Center(
              child: Video(
                key: _videoKey,
                controller: _videoController,
                fit: _boxFitFor(_fit),
                fill: Colors.black,
                // The stock controls below; media_kit's own are hidden.
                controls: (_) => const SizedBox.shrink(),
                wakelock: true,
                pauseUponEnteringBackgroundMode: true,
                subtitleViewConfiguration: subtitleConfig,
              ),
            ),
          ),

          // Resolving: the source list. It stays up until the first source
          // actually plays — the list is the control, and the first open is
          // automatic. Portrait, until the video itself starts playing.
          if (_stage == _Stage.resolving)
            PlayerStartupView(
              title: widget.item.title,
              episodeLine: _episodeLine,
              logoUrl: widget.item.logoUrl,
              backdropUrl: widget.item.backdropImageUrl,
              sourceName: _selected?.displaySource,
              status: _streams.isEmpty ? 'Getting links…' : null,
              attempt: _streams.isEmpty
                  ? null
                  : (index: _streamIndex + 1, total: _streams.length),
              rows: _startupRows,
              currentIndex: _startupCurrentIndex,
              onPick: _pickFromStartup,
              onBack: _goBack,
              isTv: isTv,
            ),

          // Failed: every link tried, or the resolve itself failed.
          if (_stage == _Stage.failed)
            Container(
              color: Colors.black,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.white54,
                        size: 48,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _error ?? l10n.playerNothingToPlay,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FilledButton(
                            onPressed: () {
                              setState(() {
                                _stage = _Stage.resolving;
                                _error = null;
                                _failedStreams.clear();
                              });
                              unawaited(_resolveAndOpen());
                            },
                            child: Text(l10n.retry),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            onPressed: _goBack,
                            child: Text(l10n.cancel),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // The golden chrome. Unmounted while the ended card or the up-next
          // card is up, so their autofocus and Back handling own the route.
          if (_stage == _Stage.playing &&
              _ended == null &&
              _nextEpisodeOffer == null)
            RepaintBoundary(
              child: GoldenPlayerControls(
                controller: _adapter,
                bufferedFraction: _bufferedFraction,
                chrome: _chrome,
                fit: _fit,
                videoScale: _videoScale,
                onFitChanged: (fit) {
                  if (!mounted) return;
                  setState(() => _fit = fit);
                },
                onRotate: canRotate ? _flipOrientation : null,
                title: widget.item.title,
                episodeLine: _episodeLine,
                subtitle: _chromeSubtitle(),
                onBack: _goBack,
                onNextEpisode: _hasNextEpisode ? _advance : null,
                onPreviousEpisode: _previousEpisode == null
                    ? null
                    : _goToPreviousEpisode,
                panelData: _panelData,
                settings: _playerSettings,
                settingsNotifier:
                    ref.read(playerSettingsProvider.notifier),
                onPickEpisode: (episode) =>
                    unawaited(_pickEpisode(episode)),
                onPickSource: (index) => unawaited(_pickSource(index)),
                onAudioPicked: (track) {
                  // Remembered across failover: the next source re-applies
                  // it.
                  _rememberedAudioId = track.id;
                },
                onSubtitlePicked: (id) {
                  _rememberedSubtitleId = id;
                },
                episodeProgress: _episodeProgressFor,
                episodeDuration: _episodeDurationFor,
                hasSubtitles: _hasSubtitles,
                isLive: _isLive,
                skipSegments: _skipSegments,
                onSkipOutro: _hasNextEpisode ? _offerNextEpisodeNow : null,
                // Phone and tablet only: with nothing here the controls
                // have no padlock.
                locked: form.isTouch ? _locked : null,
                lockAvailable: form.isTouch,
              ),
            ),

          // Up-next countdown card.
          if (_nextEpisodeOffer != null)
            NextEpisodeCountdown(
              title: _nextEpisodeOffer!.name,
              posterUrl: _nextEpisodeOffer!.posterUrl ?? widget.item.posterUrl,
              season: _nextEpisodeOffer!.season,
              episode: _nextEpisodeOffer!.episode,
              onPlayNext: () {
                final next = _nextEpisodeOffer;
                if (next == null) return;
                setState(() => _nextEpisodeOffer = null);
                unawaited(_pickEpisode(next));
              },
              onCancel: () {
                setState(() {
                  _nextEpisodeDeclined = true;
                  _nextEpisodeOffer = null;
                });
                _showEnded(EndedKind.declinedNext);
              },
              paused: !_playing,
              isTv: isTv,
            ),

          // Ended card.
          if (_ended != null)
            EndedCard(
              title: _isEpisodic
                  ? (_currentEpisode?.name ?? widget.item.title)
                  : widget.item.title,
              kind: _ended!,
              onStartOver: _startOver,
              onClose: _goBack,
              onNextEpisode: _ended == EndedKind.declinedNext
                  ? () {
                      setState(() => _ended = null);
                      unawaited(_advance());
                    }
                  : null,
              isTv: isTv,
            ),
        ],
      ),
    );
  }
}
