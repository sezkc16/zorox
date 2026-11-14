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
///     Audio (track list) and Sources (source list, as separate
///     drawers);
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
///   * PiP on iOS — mpv renders through a Metal texture, not an
///     AVPlayerLayer (see the v18 header), so there is no iOS PiP window.
///     Android PiP exists: the activity enters it through
///     [PlayerPlatformService] — a button in the top bar, plus auto-enter
///     when the viewer leaves the app mid-play — and the chrome unmounts
///     while the window is open. Audio keeps playing in the background
///     (the app declares the `audio` background mode).
///   * Cast — no cast button; media_kit has no cast in this app.
///   * Subtitle/audio delay — media_kit 1.2.6 exposes no delay API, so
///     there is no delay control (the stock panel's steppers were no-ops
///     showing 0).
///   * HLS quality picker — mpv's ABR picks the rendition; no Quality tab.
///   * Side-car subtitle download, ClearKey DRM, torrent files.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/providers/device_info_provider.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/storage/episode_watch_repository.dart';
import '../../../../core/storage/history_repository.dart';
import '../../../../core/storage/settings_repository.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/episode_duration.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_recovery.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/skip_segments.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/subtitle_search_target.dart';
import '../../domain/track_memory.dart';
import '../player_platform_service.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/ended_card.dart';
import '../vlc/next_episode_countdown.dart';
import '../vlc/panel/player_panel_data.dart';
import '../vlc/panel/player_panel_labels.dart';
import '../vlc/player_startup_view.dart';
import 'golden_player_controls.dart';
import 'mpv_android_options.dart';
import 'mpv_subtitle_style.dart';
import 'mpv_vlc_controller.dart';

/// mpv demuxer cache, forward AND backward, in bytes.
///
/// media_kit maps `PlayerConfiguration.bufferSize` to mpv's
/// `demuxer-max-bytes` and `demuxer-max-back-bytes`, so this one value is
/// both how far ahead the engine pre-buffers and how much already-played
/// data it keeps for a backward seek. It is the ONLY cache knob media_kit
/// exposes — there is no public API for `cache-secs`,
/// `demuxer-readahead-secs` or `cache-pause-*`, so a bigger cushion has to
/// come through this size.
///
/// 768 MiB (up from 512 MiB in v18-mpv): at a 4K bitrate of ~25 Mbit/s the
/// old cap held ~2.5 minutes of video; the new one holds ~4 minutes, which
/// is the difference between riding out a 60–90 s dip on a slow mobile line
/// and stalling on it. It is only a cap — mpv allocates what arrives, so a
/// slow connection never pays for the headroom — and it is still small
/// against an 8 GB phone. v17's libVLC prefetch ring was 512 MiB; mpv now
/// holds more because its stall has no other recovery below.
const int kMpvBufferSize = 768 * 1024 * 1024;

/// How long an opened stream gets to show playback before it counts as dead
/// and the failover moves to the next candidate.
const Duration _kStartupWatchdog = Duration(seconds: 12);

/// How long the pre-play source list stays up with its rows painted before
/// the first source auto-plays. The streams are preloaded, so resolution is
/// fast and the list would otherwise flash past unseen — the viewer must see
/// the list (and get a chance to tap a row) before the video starts. This is
/// a floor on visibility, not a forced wait: a tap still opens at once.
const Duration _kMinListVisible = Duration(milliseconds: 3000);

/// Pre-buffer before the first play: how much must be buffered ahead of
/// the playhead before the video starts, and the longest the start may be
/// held for it.
///
/// mpv starts on the first frame with only ~1s of readahead by default
/// (media_kit exposes no `demuxer-readahead-secs` / `cache-pause-initial`
/// knob — `PlayerConfiguration` only carries the cache SIZE), so the
/// playhead catches the buffered edge 2–3s in and stalls, then stalls
/// again when the next segment is slow. Holding the start until 5s are
/// buffered gives it a cushion. The hold is capped at 4s so a slow source
/// still starts instead of hanging on a paused first frame — and a fast
/// source plays at once, since the buffer is usually there already.
///
/// A high-bitrate (4K) stream gets a bigger cushion: at ~25 Mbit/s the
/// same 5s is only ~15 MB and the playhead eats it in seconds on a line
/// that cannot keep up, so 4K opens wait for 10s (capped at 6s). The
/// values are per-open — see [_prebufferTarget]/[_prebufferMaxWait],
/// set in [_openStream] from [isHighBitrateStream].
const Duration _kPrebufferTarget = Duration(seconds: 5);
const Duration _kPrebufferMaxWait = Duration(seconds: 4);

/// The pre-buffer target and hold cap for a high-bitrate (4K) open.
/// See [_kPrebufferTarget].
const Duration _kPrebufferTargetHighBitrate = Duration(seconds: 10);
const Duration _kPrebufferMaxWaitHighBitrate = Duration(seconds: 6);

/// How many times a stalled source may be reopened at the same position
/// before the watchdog gives up on it and fails over to the next
/// candidate (see [_onStallTick]). Two reopens are room for a demuxer
/// that dropped its request twice; a third would just stall again on
/// the same line, and the failover ladder has others to try.
const int _kStallMaxReopens = 2;

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

  /// The audio language the viewer asked for in Settings, as a canonical
  /// code ('hin', 'tam', …) — or null when the setting is empty. Captured
  /// per open in [_openStream]: a change in Settings reaches the next
  /// media, not the one on screen — the same rule the VLC screen uses.
  /// The mpv screen never read this setting at all, so mpv played its own
  /// auto pick (Tamil) while the drawer showed the resolved default
  /// (Hindi); the VLC screen applies it on open.
  String? _preferredAudioToPick;

  /// The adapter id the audio auto-select last set, and the source it was
  /// set for — so a tracks event that only re-lists the same tracks does
  /// not set the same track again, while a list that settles differently
  /// (Hindi arriving after Tamil) still corrects the pick. Reset on every
  /// open in [_openStream]: an open resets mpv's tracks to auto, so the
  /// pick has to be made again.
  int _audioAutoSelectSetId = -1;
  int _audioAutoSelectSetFor = -1;

  /// The audio pick the viewer last made in the Audio drawer, persisted
  /// across opens (Hive key [_kLastAudioPickKey]) so AUTO still plays it:
  /// the viewer taps Hindi every time, so on AUTO the next open applies
  /// Hindi instead of leaving mpv's early pick (Tamil) in place. Loaded
  /// per open in [_openStream]; written on every drawer tap. The Settings
  /// language, when set, still wins over it (see [_applyAudioAutoSelect]).
  /// Cleared by nothing: a pick is only replaced by a newer pick, never
  /// by an open — a failover that re-opens the same film must not forget
  /// what the viewer was hearing.
  RememberedTrack? _lastAudioPick;

  /// Hive key for [_lastAudioPick].
  static const String _kLastAudioPickKey = 'player_last_audio_track';

  /// True once playback has actually started for the open source (used by the
  /// startup watchdog).
  bool _startedPlaying = false;
  Timer? _watchdogTimer;

  /// Pre-buffer state (see _kPrebufferTarget): while true, an opened stream
  /// is held paused until enough is buffered ahead of the playhead. The
  /// token invalidates a wait from an earlier source, so a stale timer can
  /// never play a source the viewer has already left.
  bool _awaitingPrebuffer = false;
  Timer? _prebufferTimer;
  int _prebufferToken = 0;

  /// The pre-buffer target and hold cap for the open source, set in
  /// [_openStream]: the ordinary [_kPrebufferTarget]/[_kPrebufferMaxWait],
  /// or the high-bitrate pair for a 4K open (see
  /// [isHighBitrateStream]).
  Duration _prebufferTarget = _kPrebufferTarget;
  Duration _prebufferMaxWait = _kPrebufferMaxWait;

  /// Mid-playback stall recovery (see [_onStallTick]): the clock that
  /// measures how long the playhead has stood still, the highest rung of
  /// the [stallActionFor] ladder already fired for this stall window, and
  /// how many times the current source has been reopened for a stall.
  /// A source that plays again earns a fresh budget (see the tick); a
  /// source reopened twice without playing is abandoned for the next
  /// candidate instead of being reopened forever.
  final StallClock _stallClock = StallClock();
  StallAction _stallLastAction = StallAction.none;
  int _stallRecoveries = 0;
  int _stallStreamIndex = -1;

  /// The buffered position the last stall tick saw: if it grew since then,
  /// bytes are still arriving and the cache is refilling rather than dead
  /// (see [stallActionFor]'s `arriving`).
  Duration _stallBufferedAt = Duration.zero;

  /// The stall watchdog's tick, every 2s while the screen lives.
  Timer? _stallTimer;

  /// Where the open source started (its resume point, else zero): the
  /// pre-buffer cushion is measured from here, not from the stream start.
  Duration _openStart = Duration.zero;

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

  /// The platform bridge for Android picture-in-picture: the activity
  /// enters PiP through it, and the PiP window's transport buttons and
  /// mode changes come back through it (see [_attachPip]).
  final PlayerPlatformService _platform = PlayerPlatformService();

  /// True while the PiP window is open (or an enter request is out): the
  /// golden chrome is unmounted, so the video is bare under the window.
  bool _inPip = false;

  /// The PiP watchdog: if the window never opens after a successful
  /// request, the chrome comes back after 5 s instead of staying hidden
  /// forever (mirrors the VLC screen).
  Timer? _pipWatchdog;
  int _pipAttempt = 0;
  bool _pipWindowOpened = false;
  bool _pipAttemptFromButton = false;

  bool get _isSeries =>
      widget.item.contentType == MultimediaContentType.series ||
      widget.item.contentType == MultimediaContentType.anime;

  bool get _isEpisodic => _isSeries && _currentEpisode != null;

  bool get _canSeek => _duration > Duration.zero && !_isLive;

  /// Picture-in-picture is an Android activity mode; mpv on iOS renders
  /// through a Metal texture with no AVPlayerLayer, so there is no PiP
  /// there. Meaningless on a television either way.
  ///
  /// The gate reads [defaultTargetPlatform] rather than `Platform.isAndroid`
  /// because only the former can be overridden by a test (see
  /// [PlayerPlatformService.enterPip]); in production the two agree.
  bool get _pipAvailable {
    if (defaultTargetPlatform != TargetPlatform.android) return false;
    final profile = ref.read(deviceProfileProvider).asData?.value;
    return playerFormFactorOf(profile) != PlayerFormFactor.tv;
  }

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
    // Fullscreen playback hides the Android status + navigation bars, so
    // the video fills the whole screen with nothing on top of it. The VLC
    // screen does the same in its own initState; the mpv screen never did,
    // which is why the status bar (time, signal, battery) showed over the
    // video on Android. iOS already hides its status bar here, so this is
    // Android-only. Restored in dispose.
    if (defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    // No landscape here: the source list shown before play stays portrait,
    // and landscape is forced only when the video itself first starts
    // playing (see the playing listener).
    _chrome = ChromeVisibilityController(
      isPlaying: () => _adapter.value.isPlaying,
    );
    // The chrome showing/hiding moves the caption's bottom padding, so
    // the padding is pushed into the video view on every change.
    _chrome.addListener(_onChromeVisibilityChanged);
    // PiP transport buttons + mode changes ride back through the platform
    // channel; attach early so a window opened before the first play is
    // still routed.
    _attachPip();
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    _prebufferTimer?.cancel();
    _stallTimer?.cancel();
    _pipWatchdog?.cancel();
    // The channel handler closes over this screen; without the detach it
    // would keep routing PiP buttons into a disposed player.
    _platform.detachPipListener();
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
    // Hands the status + navigation bars back: without this the app stays
    // in immersive mode after the player closes, and Home has no status
    // bar. Mirrors the hide in initState (Android only).
    if (defaultTargetPlatform == TargetPlatform.android) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !mounted) return;
    if (state == AppLifecycleState.inactive) {
      // Home swipe / app switcher on Android: the moment to enter PiP.
      // `inactive` is the activity pausing while still visible, so the
      // enter call is still valid here — and the window opening keeps
      // the app from ever reaching `paused`, so media_kit's
      // pauseUponEnteringBackgroundMode never fires and the film keeps
      // playing under the window. Only while actually playing, and only
      // where PiP exists; a paused film stays paused.
      if (!_inPip && _pipAvailable && _playing) {
        unawaited(_enterPip());
      }
    }
    if (state == AppLifecycleState.resumed) {
      // Backstop behind `pipModeChanged`: returning to the foreground is
      // what ending PiP looks like, and the chrome must come back with it
      // whether or not the activity got round to telling us. The window
      // is already gone by the time the app is foregrounded, so there is
      // no native stop to send — just take the chrome back.
      if (_inPip) {
        _pipWatchdog?.cancel();
        _pipWatchdog = null;
        setState(() => _inPip = false);
      }
    }
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

  /// Routes the PiP window's transport buttons and mode changes back to
  /// the screen (Android only; the channel is inert elsewhere).
  ///
  /// The handler is keyed by channel name, so it is process-wide — a
  /// second call replaces the first. Detached in [dispose].
  void _attachPip() {
    _platform.attachPipListener(
      onAction: (action) => switch (action) {
        PipAction.play => unawaited(_player.play()),
        PipAction.pause => unawaited(_player.pause()),
        PipAction.seekForward => _seekRelative(
          PlayerPlatformService.pipSeekStep,
        ),
        PipAction.seekBackward => _seekRelative(
          -PlayerPlatformService.pipSeekStep,
        ),
      },
      onModeChanged: (inPip) {
        if (!mounted || _disposed || inPip == _inPip) return;
        // The attempt's answer, whatever it is: the watchdog stands down.
        _pipWatchdog?.cancel();
        _pipWatchdog = null;
        // The other way into PiP: the viewer swiped home and the
        // auto-enter below never ran, or the system's own PiP control
        // opened it. A locked PiP window has no chip in it, so the lock
        // clears on the way in.
        if (inPip) {
          _pipWindowOpened = true;
          _pipAttemptFromButton = false;
          _locked.value = false;
        }
        setState(() => _inPip = inPip);
      },
    );
  }

  /// Seeks by [delta] from wherever playback is, for the PiP buttons.
  ///
  /// Clamped at both ends: a negative target is refused outright by mpv,
  /// and overshooting the duration would trip the end-of-media handler.
  /// Counted from the last known position. No chain can straddle this:
  /// [GoldenPlayerControls] is built only while `!_inPip`, so it is
  /// unmounted before a PiP window exists to press these buttons in.
  void _seekRelative(Duration delta) {
    if (!_canSeek) return;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (_duration > Duration.zero && target > _duration) {
      target = _duration;
    }
    unawaited(_player.seek(target));
  }

  /// Enters the Android PiP window.
  ///
  /// Mirrors the VLC screen: the chrome comes off optimistically in the
  /// same frame the request is made, and the lock clears on the way in
  /// (a locked PiP window has no chip in it). Android answers false —
  /// not an error — when the user has PiP disabled for the app, and then
  /// never sends `pipModeChanged`; without the reset below the optimism
  /// is permanent and the chrome never comes back.
  Future<void> _enterPip({bool fromButton = false}) async {
    _pipAttemptFromButton = fromButton;
    _pipWindowOpened = false;
    setState(() => _inPip = true);
    _locked.value = false;
    final entered = await _platform.enterPip(
      _playing,
      // Shapes the window to the film. Read at the moment of the request
      // rather than remembered, because a failover or a next-episode start
      // can have changed it since the last size event.
      videoSize: _adapter.value.videoSize,
    );
    if (_disposed || !mounted || !_inPip) return;
    if (!entered) {
      if (fromButton) {
        // The native side refused outright (no PiP support, no picture):
        // say so, instead of the button silently doing nothing.
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture isn\'t available for this video right now.',
              title: 'Picture-in-picture',
            );
      }
      setState(() => _inPip = false);
      return;
    }
    // The request went out; the window opening, or failing to, is
    // reported through `pipModeChanged`. If neither arrives, the watchdog
    // takes the chrome back (see [_armPipWatchdog]).
    _armPipWatchdog();
  }

  /// Arms the PiP watchdog for the attempt that just went out.
  ///
  /// The native start only says the request went out; the window opening,
  /// or failing to, is reported through `pipModeChanged`. If neither
  /// arrives, the player is left with its controls unmounted and no touch
  /// handling at all — the screen looks frozen until the app is
  /// backgrounded and foregrounded again. Five seconds is the backstop
  /// behind the native side's own three: the native gate gives up at
  /// three seconds and reports the failure itself, so this only fires
  /// when no event arrived at all.
  void _armPipWatchdog() {
    _pipWatchdog?.cancel();
    final attempt = ++_pipAttempt;
    _pipWatchdog = Timer(const Duration(seconds: 5), () {
      if (_disposed || !mounted || attempt != _pipAttempt) return;
      // The window opened after all, or the event is already on its way.
      if (_pipWindowOpened || !_inPip) return;
      if (kDebugMode) {
        debugPrint(
          'MpvPlayerScreen: PiP watchdog fired — the window never opened',
        );
      }
      final fromButton = _pipAttemptFromButton;
      _pipAttemptFromButton = false;
      if (fromButton) {
        ref
            .read(notificationServiceProvider)
            .showInfo(
              'Picture-in-picture didn\'t open for this video.',
              title: 'Picture-in-picture',
            );
      }
      if (mounted && !_disposed) setState(() => _inPip = false);
    });
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
        configuration: VideoControllerConfiguration(
          // VideoToolbox is Apple-only: on Android the old hardcoded
          // 'videotoolbox' made mpv fall back to software decoding, and
          // 4K HEVC in software is the stutter the viewer reported on
          // Android (iOS is smooth because VideoToolbox engages there).
          // Android uses media_kit's default 'auto-safe' (mediacodec).
          hwdec: mpvHwdecForPlatform(defaultTargetPlatform),
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
    // Android-only mpv options (see mpv_android_options.dart): applied
    // after the VideoController (which owns `hwdec`) exists and before
    // the first open, so they govern every file this player loads.
    // Best-effort: a failure leaves media_kit's defaults in place and
    // the open still goes ahead. iOS is untouched — its path is smooth
    // as it is.
    if (defaultTargetPlatform == TargetPlatform.android) {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await applyMpvAndroidOptions(platform);
      }
    }
    // The mid-playback stall watchdog: a tick every 2s that asks whether
    // the playhead has moved, and recovers the source when it has not
    // (see _onStallTick). It stands down while the screen is gone.
    _stallTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _onStallTick(),
    );
    await _resolveAndOpen();
  }

  void _listen() {
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        _playing = playing;
        // Keeps the PiP window's play/pause button in sync while the
        // window is open. Not worth the platform call while it is not.
        if (_inPip) {
          _platform.syncPipState(
            playing,
            videoSize: _adapter.value.videoSize,
          );
        }
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
            // mpv has settled its pick by now, so re-read the aid the
            // drawer shows — the tracks-event read can land while mpv is
            // still on 'auto' — and give the audio auto-select a second
            // chance in case the first tracks event arrived before the
            // list was populated. Both are guarded (the read-back is
            // best-effort, the auto-select is deduped per open), and
            // neither touches a pick the viewer made.
            unawaited(_adapter.refreshRealAudioAid());
            unawaited(_applyAudioAutoSelect());
            // One-time decode diagnostic: what decoder is actually
            // engaged (see mpv_android_options.dart). Android should
            // print mediacodec; empty/no means software decode.
            unawaited(logMpvDecodeInfo(_player));
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
        // The pre-buffer target is met: start the held stream.
        if (_awaitingPrebuffer && _prebufferReady) {
          _startAfterPrebuffer();
        }
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
        unawaited(_applyAudioAutoSelect());
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
    // The audio-language setting is captured per open (a change in
    // Settings reaches the next media, not the one on screen), and the
    // auto-select record resets with it: an open resets mpv's tracks to
    // auto, so the pick has to be made again.
    final preferred = _playerSettings.value.preferredAudioLanguage;
    _preferredAudioToPick = preferred.isNotEmpty ? preferred : null;
    // And the last pick the viewer made, so AUTO applies it on this open
    // (see [_lastAudioPick]).
    _lastAudioPick = _readLastAudioPick();
    _audioAutoSelectSetId = -1;
    _audioAutoSelectSetFor = -1;
    _adapter.clearError();
    final stream = _streams[index];
    // A high-bitrate (4K) open waits for a bigger cushion (see the
    // pre-buffer consts); an ordinary open keeps the 5s target.
    final highBitrate = isHighBitrateStream(stream);
    _prebufferTarget = highBitrate
        ? _kPrebufferTargetHighBitrate
        : _kPrebufferTarget;
    _prebufferMaxWait = highBitrate
        ? _kPrebufferMaxWaitHighBitrate
        : _kPrebufferMaxWait;
    // A new source earns a fresh stall budget; a reopen of the same one
    // (stall recovery) keeps its count, so a source that cannot play is
    // abandoned for the next candidate instead of reopened forever.
    if (index != _stallStreamIndex) {
      _stallStreamIndex = index;
      _stallRecoveries = 0;
      _stallLastAction = StallAction.none;
      _stallClock.reset();
    }
    _stallBufferedAt = Duration.zero;
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
      // Opened PAUSED: the first frame shows as soon as it is decoded, but
      // the playhead does not move until _waitForPrebuffer has a cushion
      // buffered ahead of it (see _kPrebufferTarget). Opening with
      // play: true started on the first frame with ~1s buffered, so it
      // stalled 2–3s in, then again — the spinner the viewer reported.
      _openStart = start != null && start > Duration.zero
          ? start
          : Duration.zero;
      await _player.open(
        Media(
          stream.url,
          httpHeaders: stream.headers,
          start: start != null && start > Duration.zero ? start : null,
        ),
        play: false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('mpv open failed: $e');
      _failedStreams.add(index);
      _publishPanelData();
      _tryNextStream();
      return;
    }
    _armWatchdog();
    _waitForPrebuffer();
    if (mounted) setState(() {});
  }

  /// Holds an opened stream paused until the pre-buffer target is met, then
  /// plays. A fast source is usually buffered already, so it plays at once;
  /// a slow one waits at most _kPrebufferMaxWait and then plays anyway (the
  /// cache-pause will stall it if the server cannot keep up — same as
  /// before, but now from a cushion rather than from the first frame).
  void _waitForPrebuffer() {
    final token = ++_prebufferToken;
    _awaitingPrebuffer = true;
    if (_prebufferReady) {
      _startAfterPrebuffer(token);
      return;
    }
    _prebufferTimer?.cancel();
    _prebufferTimer = Timer(_prebufferMaxWait, () {
      if (_disposed || token != _prebufferToken) return;
      _startAfterPrebuffer(token);
    });
  }

  /// Whether the buffered cushion ahead of the playhead meets the target.
  bool get _prebufferReady =>
      _buffered - _openStart >= _prebufferTarget;

  void _startAfterPrebuffer([int? token]) {
    if (!_awaitingPrebuffer) return;
    if (token != null && token != _prebufferToken) return;
    _awaitingPrebuffer = false;
    _prebufferTimer?.cancel();
    _prebufferTimer = null;
    if (_disposed) return;
    unawaited(_player.play());
  }

  /// One tick of the mid-playback stall watchdog (every 2s).
  ///
  /// The start-only pre-buffer (see [_waitForPrebuffer]) does nothing once
  /// playback has begun: on a line slower than a 4K stream's bitrate the
  /// forward cache drains mid-film, mpv's spinner comes up, and the
  /// playhead sits still — in the video the user sent, forever, with
  /// Control Center reading "Not Playing". The engine's `buffering` flag
  /// alone cannot be the trigger (it is true through healthy playback
  /// while the cache refills), so the trigger is the ground truth from
  /// [stallActionFor]: a playhead that has not moved.
  ///
  /// The ladder is the shared one, so a stall is ridden out before
  /// anything is done about it: a seek back to the frozen position at
  /// 10s (a fresh request for a demuxer that dropped its own — on a
  /// stalled HLS stream the forward cache is empty, so the seek throws
  /// nothing away), then a reopen of the same source at the same
  /// position at 25s, then the next candidate after two failed reopens.
  /// The nudge is kept for HLS on purpose: the ladder's `adaptive`
  /// exemption is written for libVLC, whose adaptive module restarts
  /// every stream at the playhead's segment and drops a rendition on a
  /// seek. mpv's HLS demuxer only re-fetches the segment at the seek
  /// point, and a stalled one has nothing buffered to lose — so the
  /// nudge is the move that restarts a demuxer whose segment retries
  /// are spent, not a cost.
  /// A source that is still delivering bytes (the buffered position
  /// growing) is refilling, not dead: no nudge, and recovery waits out
  /// the longest refill. Playback that is not expected — the viewer's
  /// own pause, the pre-buffer wait, or nothing started yet — restarts
  /// the clock instead of counting against the source, so ten minutes
  /// paused is never ten minutes stalled the moment play resumes.
  void _onStallTick() {
    if (_disposed || !_startedPlaying || _awaitingPrebuffer) return;
    final state = _player.state;
    if (!state.playing && !state.buffering) {
      _stallClock.restart();
      _stallLastAction = StallAction.none;
      return;
    }
    final moved = _stallClock.tick(_position);
    if (moved) {
      // The picture is moving again: the stall is over and the source
      // has earned a fresh recovery budget.
      _stallLastAction = StallAction.none;
      _stallRecoveries = 0;
      _stallBufferedAt = _buffered;
      return;
    }
    final arriving = _buffered > _stallBufferedAt;
    _stallBufferedAt = _buffered;
    final action = stallActionFor(
      stalledFor: _stallClock.stalledFor,
      hadFrames: _startedPlaying,
      lastAction: _stallLastAction,
      arriving: arriving,
    );
    switch (action) {
      case StallAction.none:
        break;
      case StallAction.nudge:
        _stallLastAction = StallAction.nudge;
        unawaited(_player.seek(_position));
      case StallAction.recover:
        _stallLastAction = StallAction.recover;
        _stallClock.reset();
        if (_stallRecoveries < _kStallMaxReopens) {
          _stallRecoveries++;
          unawaited(_openStream(_streamIndex, start: _position));
        } else {
          _tryNextStream();
        }
    }
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

  /// The persisted last audio pick, or null when there is none — or it is
  /// unreadable. A corrupted box reads as no pick, and mpv's own default
  /// stands, which is where the viewer would have been anyway.
  RememberedTrack? _readLastAudioPick() {
    try {
      final stored = ref
          .read(settingsRepositoryProvider)
          .getPlayerSetting<String>(_kLastAudioPickKey);
      if (stored == null || stored.isEmpty) return null;
      return RememberedTrack.fromJson(jsonDecode(stored));
    } catch (_) {
      return null;
    }
  }

  /// Puts the audio the viewer wants on, once the tracks are known.
  ///
  /// mpv picks its audio at loadfile from the tracks it has seen so far —
  /// for HLS that list is still settling, so it can lock onto a track
  /// (Tamil) that is not the one the settled list resolves to (Hindi),
  /// and it never re-selects. Nothing on this screen corrected that: the
  /// viewer's pick is only re-applied when one was made in this session
  /// ([_applyRememberedTracks]), and the audio-language setting was never
  /// read here at all.
  ///
  /// Runs on every tracks event until the pick is set for this open, and
  /// once more on first play (the list may have settled by then): the
  /// setting's language first ([findPreferredAudioTrack] — a Hindi DD 5.1
  /// already playing is not moved to a Hindi 2.0 for being listed first),
  /// else the last pick the viewer made ([_lastAudioPick] — the viewer
  /// taps Hindi every time, so AUTO plays Hindi even with no language set
  /// in Settings), else mpv's own default from the LIVE list. Setting the
  /// track mpv already plays is a no-op, so re-running while the list
  /// settles only corrects the pick; a pick the viewer made wins and is
  /// never touched. A language not in the list yet returns early and
  /// retries on the next tracks event — never a delayed guess, the list
  /// itself is the clock.
  ///
  /// +5: the +4 version read the AUTO default from the published adapter
  /// snapshot (`_adapter.value.activeAudioTrackId`), which is STALE when
  /// the tracks listener runs — the listener fires before the adapter
  /// publishes, so on the first tracks event it read null and returned
  /// early, and on a direct file there is no second tracks event to retry
  /// on. That is why +4 fixed the setting (its branch reads the live
  /// list) but not AUTO (Tamil played while the drawer showed Hindi). The
  /// AUTO branch now reads the live list too, and applies the last pick
  /// before falling back to the live default.
  Future<void> _applyAudioAutoSelect() async {
    if (_disposed || _rememberedAudioId != null) return;
    // The LIVE track list, not the published snapshot: the tracks
    // listener runs before the adapter publishes (see above).
    final tracks = await _adapter.getAudioTracks();
    if (_disposed || _rememberedAudioId != null) return;
    if (tracks.isEmpty) return; // Not ready yet: retry on the next tracks event.
    final preferred = _preferredAudioToPick;
    int? targetId;
    if (preferred != null && preferred.isNotEmpty) {
      final match = findPreferredAudioTrack(
        tracks,
        preferred,
        activeId: _adapter.value.activeAudioTrackId,
      );
      if (match == null) return; // Not in the list yet: retry on the next tracks event.
      targetId = match.id;
    } else {
      // AUTO: the last pick the viewer made first — matched by language
      // and name, never by list position, so a settled list that moved
      // still finds it — else mpv's own default from the live list, set
      // explicitly so the engine plays what the drawer shows.
      final lastPick = _lastAudioPick;
      final remembered =
          lastPick != null ? matchRememberedTrack(tracks, lastPick) : null;
      targetId = remembered?.id ?? _adapter.liveDefaultAudioTrackId;
      if (targetId == null) return; // No tracks yet.
    }
    if (targetId == _audioAutoSelectSetId &&
        _audioAutoSelectSetFor == _streamIndex) {
      return; // Already set for this open.
    }
    await _adapter.setAudioTrack(targetId);
    if (_disposed || _rememberedAudioId != null) return;
    _audioAutoSelectSetId = targetId;
    _audioAutoSelectSetFor = _streamIndex;
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
      // The engine's list leads with the `auto` and `no` sentinels,
      // which are not tracks: setting the first of them left the state
      // on 'auto' while mpv played its pick, so the drawer read "Off"
      // under a rendering subtitle. The default-flagged track is mpv's
      // own pick with no language preference set; else the first real
      // track — and the state is concrete from here on, so the drawer
      // shows the track that is actually playing.
      final real = embedded
          .where((t) => t.id != 'auto' && t.id != 'no')
          .toList(growable: false);
      if (real.isNotEmpty) {
        final def = real.indexWhere((t) => t.isDefault == true);
        unawaited(_player.setSubtitleTrack(real[def >= 0 ? def : 0]));
        _subtitleAppliedFor = _streamIndex;
      }
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
  /// duration first, else the plugin's runtime in minutes.
  Duration? _episodeDurationFor(Episode episode) {
    final mainUrl = widget.item.url;
    final history = ref.read(historyRepositoryProvider);
    return episodeDurationFromHistoryMs(
      history.getEpisodeDuration(
        episode.url,
        mainUrl: mainUrl,
        season: episode.season,
        episode: episode.episode,
      ),
      runtimeMinutes: episode.runtime,
    );
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
          server: sourceServer(_streams[i]),
          quality: sourceQualityLabel(_streams[i]),
          size: sourceSizeLabel(_streams[i]),
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
          // the controls' gesture layer through [_videoScale]. The picture
          // is its own repaint boundary: the chrome above it rebuilds on
          // every position tick, and without the boundary each of those
          // rebuilds re-rasterizes the 4K texture layer with it.
          ValueListenableBuilder<double>(
            valueListenable: _videoScale,
            builder: (context, scale, child) => Transform.scale(
              scale: scale.clamp(_kMinZoom, _kMaxZoom),
              alignment: Alignment.center,
              child: child,
            ),
            child: RepaintBoundary(
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
              _nextEpisodeOffer == null &&
              // The window is the chrome in PiP: the golden controls
              // unmount while it is open (mirrors the VLC screen).
              !_inPip)
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
                  // it — and persisted across opens, so AUTO plays it next
                  // time too (see [_lastAudioPick]).
                  _rememberedAudioId = track.id;
                  final pick = RememberedTrack.of(track);
                  _lastAudioPick = pick;
                  if (pick != null) {
                    unawaited(
                      ref
                          .read(settingsRepositoryProvider)
                          .setPlayerSetting(
                            _kLastAudioPickKey,
                            jsonEncode(pick.toJson()),
                          ),
                    );
                  }
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
                // PiP is Android-only; on iOS and TV this stays null and
                // the button never renders.
                onEnterPip: _pipAvailable
                    ? () => unawaited(_enterPip(fromButton: true))
                    : null,
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
