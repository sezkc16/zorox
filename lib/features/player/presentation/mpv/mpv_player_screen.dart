/// Playback on the mpv engine (via media_kit) — v19 build.
///
/// A focused, parallel player screen that plays the same resolved streams as
/// the VLC screen (VlcPlayerScreen) on the mpv engine, so the two engines
/// can be compared on the same phone for the same films:
///
///   * double-tap ±10 s seek (forward AND back) — mpv pre-buffers ahead AND
///     keeps a backward cache, so a ±10 s seek should land in already-buffered
///     data instead of re-fetching / reconnecting;
///   * pause/resume — a plain mpv pause keeps the stream and the exact
///     position, with no "Reconnecting..." and no 0:00 reset;
///   * subtitles, volume/brightness gestures, speed, source switching.
///
/// mpv cache (the point of this build), set in one place:
///   * `PlayerConfiguration(bufferSize: 512 MiB)` — media_kit maps this to
///     mpv's `demuxer-max-bytes` AND `demuxer-max-back-bytes`, so the demuxer
///     keeps 512 MiB ahead of playback AND 512 MiB behind it. The window is
///     deliberately the same 512 MiB as v17's libVLC prefetch ring, so the
///     comparison is fair. At 1080p (~8 Mbit/s) that is ~8 min ahead and ~8 min
///     behind; at 4K (~20 Mbit/s) ~3.5 min each way. A ±10 s seek is far inside
///     both windows, so it should be instant.
///   * `VideoControllerConfiguration(hwdec: 'videotoolbox')` — hardware
///     decoding on iOS (VideoToolbox) so 4K HEVC/HDR plays smoothly instead
///     of on the CPU. `enableHardwareAcceleration: true` (the default) renders
///     through Metal.
///
/// v19 adds, on the mpv line (approved design, Gold & Black, compact bottom
/// icon toolbar — settings / subtitles / audio / speed / lock / PiP /
/// rotate / fullscreen):
///   * a pre-play source list: before the video opens, the resolved sources
///     show with a "Source X of N" pill and their probe status, and tapping
///     a row plays that row (the same pick/abandon race the VLC screen runs);
///   * an episode picker (series) + previous/next episode buttons, switching
///     episodes by re-resolving for the new episode;
///   * audio + subtitle pickers surfaced through the bottom icon toolbar
///     (they already existed behind the top-bar icons; the sheets now
///     re-check the tracks as they arrive);
///   * a settings sheet (sources + quality + episodes);
///   * PiP, attempted on mpv for the first time: the forked media_kit_video
///     (see packages/media_kit_video_fork) swaps the GL render context for
///     a software one on PiP start and feeds the frames to an
///     AVSampleBufferDisplayLayer. See [MpvPip] in the fork and the notes in
///     the v19 build report. If the native PiP cannot show real video, the
///     button is left out rather than shipping a black PiP.
///
/// What this build deliberately does NOT carry over (secondary — reported
/// honestly, not silently broken):
///   * Side-car subtitle download (OpenSubtitles etc.) — only the subtitles
///     the plugin already listed on the stream, plus embedded tracks.
///   * ClearKey DRM (drmKid/drmKey) — media_kit exposes no ClearKey path; a
///     DRM stream will fail to play and the failover moves to the next source.
///   * Skip Intro/Outro, auto-advance to the next episode (manual episode
///     switching only). Ended shows Replay + Close.
///   * Volume is the engine's gain (`setVolume`), not the system volume the
///     VLC screen drives; brightness reuses the same platform channel as the
///     VLC screen ([PlatformPlayerBrightness]).
///   * There is no stall watchdog / auto-reconnect here on purpose: the v17
///     pause bug was exactly a watchdog reading a pause as a stall. A pause
///     is a pause; a genuinely dead source is handled by the startup failover
///     only.
///
/// The VLC screen stays in the repo untouched; the route points here for this
/// test build, and flipping it back is a one-line change in `app_router.dart`.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/services/download_service.dart';
import '../../../../core/storage/storage_service.dart';
import '../../../../core/utils/app_utils.dart';
import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../settings/presentation/widgets/subtitle_appearance_settings.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/skip_segments.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../../domain/track_language.dart';
import '../player_brightness.dart';
import '../vlc/panel/player_panel_labels.dart';

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

/// A double-tap seek step.
const Duration _kSeekStep = Duration(seconds: 10);

/// Pinch-zoom range, same as the VLC screen.
const double _kMinZoom = 0.5;
const double _kMaxZoom = 3.0;

const Duration _kControlsAutoHide = Duration(seconds: 3);

/// Subtitle size for the mpv overlay (media_kit's default is 32, which is
/// sized for a desktop window).
const double _kSubtitleFontSize = 22;

/// Storage keys for the mpv subtitle position + style (Hive settings box,
/// via StorageService.setPlayerSetting). mpv-only; the VLC screen keeps its
/// own PlayerSettings fields.
const String _kSubPosXKey = 'mpv_sub_pos_x';
const String _kSubPosYKey = 'mpv_sub_pos_y';
const String _kSubSizeKey = 'mpv_sub_size';
const String _kSubColorKey = 'mpv_sub_color';
const String _kSubBgKey = 'mpv_sub_bg';
const String _kSubOutlineKey = 'mpv_sub_outline';

/// The subtitle's default spot: bottom-centre, just above the controls
/// bar. Stored as a fraction of the video area (0..1), the text's centre.
const Offset _kDefaultSubtitlePos = Offset(0.5, 0.92);

/// The top preset: same x, near the top edge.
const Offset _kTopSubtitlePos = Offset(0.5, 0.08);

enum _Stage { resolving, playing, failed }

/// Which swipe the HUD is reporting: brightness (left half) or volume
/// (right half).
enum _HudKind { brightness, volume }

/// The tabbed panel's tabs (like the VLC player's panel): Sources,
/// Audio, Subtitles, Episodes. The toolbar opens it on the tab its icon
/// stands for.
enum _PanelTab { sources, audio, subtitles, episodes }

/// The mpv test player. Same constructor as VlcPlayerScreen so the route
/// can point at either.
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

  _Stage _stage = _Stage.resolving;
  String? _error;

  /// Candidates in failover order, and which one is open.
  List<StreamResult> _streams = const [];
  int _streamIndex = 0;
  StreamResult? get _selected =>
      _streams.isEmpty ? null : _streams[_streamIndex];

  /// The episode being played, and the route token for it. Mutable: an
  /// episode switch re-resolves for the new episode (see [_startEpisode]).
  late Episode? _episode;
  late String _videoUrl;

  /// Intro/outro segments for the current episode (IntroDB + AnimeSkip,
  /// the same crowdsourced source the libVLC player uses). Empty is
  /// normal — most episodes have none, and then no chip shows. Works
  /// for any series with timestamps: anime, drama, Netflix shows.
  List<SkipSegment> _skipSegments = const <SkipSegment>[];

  /// The segment Auto Skip just jumped over, so the position ticks that
  /// land while the seek is still in flight do not fire it a second time.
  /// Cleared the moment the position is outside every segment again, and
  /// when a new episode's segments arrive.
  SkipSegment? _autoSkippedSegment;

  /// Sources already aggregated by a source sheet. Route sources belong to
  /// the first episode only; an episode switch clears them (as the VLC
  /// screen does).
  List<StreamResult>? _preloaded;

  /// Pre-play source list, from the resolve race: the ordered candidates, the
  /// probe outcome per index, and the pick/abandon completers. See
  /// [_resolveAndOpen].
  List<StreamResult> _candidates = const [];
  final Map<int, ProbeOutcome> _probes = {};
  Completer<int>? _pick;
  Completer<void>? _abandonResolve;
  int? _pickedBeforeOpen;
  int _resolveGeneration = 0;

  /// Screen lock: when locked the controls hide and only an unlock button
  /// shows; the video keeps playing.
  bool _locked = false;

  /// mpv PiP (forked media_kit_video): whether the native side can start it,
  /// and whether it is active.
  bool _pipAvailable = false;
  bool _pipActive = false;

  /// Where to resume, resolved once before the first open.
  Duration _resumePosition = Duration.zero;

  /// Progress tracking (history, scrobbling, watched) — the same tracker the
  /// VLC screen uses, fed from mpv's state stream.
  PlaybackTracker? _tracker;
  int _sessionToken = 0;

  /// Last good state, for the UI and the tracker.
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  bool _isLive = false;

  /// Which source the subtitle auto-select has already run for.
  int _subtitleAppliedFor = -1;

  /// Whether the in-flight resolve was abandoned by the viewer's Back (not
  /// by a retry or dispose). resolvePlayback answers an abandon with the
  /// default source, so this flag — not the abandon completer alone — is
  /// what stops the late open after the user has left.
  bool _resolveAbandoned = false;

  /// Subtitle position + style (the long-press drag and the style panel).
  /// The position is a fraction of the video area (0..1), the text's
  /// centre; it is persisted, so a dragged subtitle stays where the viewer
  /// put it — for this session and the next ones.
  Offset _subtitlePos = _kDefaultSubtitlePos;

  /// True while the viewer is holding the subtitle and dragging it.
  bool _subtitleDragging = false;

  /// The video area's key, so the drag can turn the pointer's screen
  /// position into a spot on the picture (see [_buildDraggableSubtitle]).
  final GlobalKey _videoAreaKey = GlobalKey();

  /// Where the pointer grabbed the subtitle, as a video-area offset from
  /// the text's centre (so the text does not jump when the drag starts).
  Offset _dragGrab = Offset.zero;

  /// The style panel's values (persisted alongside the position).
  double _subSize = _kSubtitleFontSize;
  int _subColor = 0xFFFFFFFF;

  /// The box behind the text: 0 = Off (no box); otherwise the box's ARGB.
  int _subBg = 0;
  SubtitleOutline _subOutline = SubtitleOutline.thin;

  /// True once playback has actually started for the open source (used by the
  /// startup watchdog).
  bool _startedPlaying = false;
  Timer? _watchdogTimer;

  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// Pinch zoom factor, applied with a Transform around the Video widget.
  double _zoom = 1.0;
  double _zoomBase = 1.0;

  /// Engine gain (0..100) and screen brightness (0..1) for the vertical
  /// swipe gestures. Volume here is the engine's, not the system volume.
  double _volume = 100;
  double _brightness = 1.0;

  /// Speed (1.0 = normal).
  double _speed = 1.0;

  /// Which swipe HUD is showing (brightness on the left half, volume on
  /// the right), its level (0..1), and whether it is visible. The HUD
  /// fades in on a swipe, follows the level live, and fades out ~1.5 s
  /// after the swipe ends (see [_hudTimer]).
  _HudKind? _hudKind;
  double _hudValue = 0;
  bool _hudVisible = false;
  Timer? _hudTimer;

  /// The double-tap seek flash: which side it is on (-1 = left/back,
  /// 1 = right/forward) and whether it is showing. It is a SMALL pill at
  /// the edge where the tap happened — never a big box in the centre
  /// (the centre pill annoyed the viewer). It fades out quickly.
  int _seekFlashDir = 0;
  bool _seekFlashVisible = false;
  Timer? _flashTimer;

  /// Tap-and-hold 2x speed (right side): a press held ~550 ms plays at
  /// 2x until the finger lifts, then restores [_speed]. 550 ms is longer
  /// than the subtitle long-press timeout (500 ms), so grabbing a
  /// subtitle wins first and 2x never fires on it.
  Timer? _holdSpeedTimer;
  bool _holdSpeedActive = false;
  double _speedBeforeHold = 1.0;
  // A hold that just ended must not also toggle the controls (the tap
  // up after a long hold still counts as a tap).
  bool _justEndedHoldSpeed = false;

  /// Horizontal scrub: drag left/right to move through the video. The
  /// target is only previewed while dragging; the seek happens on
  /// release, so the mpv backward cache makes a backward scrub instant.
  bool _scrubbing = false;
  Duration _scrubStartPosition = Duration.zero;
  double _scrubDx = 0;
  Duration? _scrubTarget;
  bool _scrubVisible = false;
  Timer? _scrubTimer;

  /// Tap the time display to show the remaining time ("-23:09")
  /// instead of elapsed/total. Session state.
  bool _showRemainingTime = false;

  /// Last position-update setState, so mpv's frequent ticks do not rebuild
  /// the whole screen at full rate.
  DateTime _lastPositionUi = DateTime.fromMicrosecondsSinceEpoch(0);

  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  PlayerBrightness get _brightnessApi => PlatformPlayerBrightness();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _episode = widget.episode;
    _videoUrl = widget.videoUrl;
    _preloaded = widget.preloadedStreams;
    // Landscape on a portrait handset, as the VLC screen does; restored on
    // the way out.
    _forceLandscapeIfPortrait();
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    // A resolve still running must not hang on the pick race behind a dead
    // screen: abandon it, as the VLC screen does.
    _abandonPendingResolve();
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _watchdogTimer?.cancel();
    _hudTimer?.cancel();
    _holdSpeedTimer?.cancel();
    _scrubTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    try {
      _tracker?.finish();
    } catch (_) {
      // Tracking must never block leaving the player.
    }
    unawaited(_player.dispose());
    _restoreOrientation();
    super.dispose();
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
    unawaited(
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
    );
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

    _listen();
    _pipChannel.setMethodCallHandler(_onPipMethodCall);
    unawaited(_checkPipSupport());
    _loadSubtitlePrefs();
    await _resolveAndOpen();
    unawaited(_loadSkipSegments(_episode));
  }

  /// Reads the persisted subtitle position + style (the drag and the style
  /// panel) so a subtitle the viewer moved or restyled stays that way.
  /// Missing keys keep the built-in defaults.
  void _loadSubtitlePrefs() {
    try {
      final storage = ref.read(storageServiceProvider);
      final x = storage.getPlayerSetting<double>(_kSubPosXKey);
      final y = storage.getPlayerSetting<double>(_kSubPosYKey);
      if (x != null && y != null) {
        _subtitlePos = Offset(
          x.clamp(0.05, 0.95),
          y.clamp(0.05, 0.95),
        );
      }
      final size = storage.getPlayerSetting<double>(_kSubSizeKey);
      if (size != null) _subSize = size.clamp(12, 48);
      final color = storage.getPlayerSetting<int>(_kSubColorKey);
      if (color != null) _subColor = color;
      final bg = storage.getPlayerSetting<int>(_kSubBgKey);
      if (bg != null) _subBg = bg;
      final outline = storage.getPlayerSetting<String>(_kSubOutlineKey);
      if (outline != null) {
        _subOutline = SubtitleOutline.values.firstWhere(
          (o) => o.name == outline,
          orElse: () => SubtitleOutline.thin,
        );
      }
    } catch (_) {
      // A missing or unreadable box keeps the defaults.
    }
  }

  /// Persists one subtitle preference (called on a drag drop / style change).
  void _saveSubtitlePref(String key, Object value) {
    try {
      unawaited(
        ref.read(storageServiceProvider).setPlayerSetting(key, value),
      );
    } catch (_) {}
  }

  /// Calls from the native PiP side: it stopped (window closed), or it
  /// started (so the button can show its active state).
  Future<void> _onPipMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipStopped':
        // The native side already freed its software context and restored
        // the GL one; the Dart side only restores the decode path and the
        // button state.
        await _restoreAfterPip();
      case 'onPipStarted':
        if (!_pipActive && mounted) setState(() => _pipActive = true);
    }
  }

  /// Shared by the Dart-initiated exit and the native callback: back to the
  /// GPU decode path, and the button state.
  Future<void> _restoreAfterPip() async {
    try {
      await (_player.platform as NativePlayer)
          .setProperty('hwdec', 'videotoolbox');
    } catch (_) {}
    _pipActive = false;
    if (mounted) setState(() {});
  }

  /// Asks the native PiP side whether it can start PiP at all. The PiP
  /// button only shows when this says yes — a missing or incapable native
  /// side leaves the button out rather than a black PiP.
  Future<void> _checkPipSupport() async {
    try {
      final supported =
          await _pipChannel.invokeMethod<bool>('isSupported') ?? false;
      if (_disposed) return;
      if (mounted && supported != _pipAvailable) {
        setState(() => _pipAvailable = supported);
      }
    } catch (_) {
      // No native PiP side (or it refused): the button stays hidden.
    }
  }

  void _listen() {
    _subs.add(
      _player.stream.playing.listen((playing) {
        if (_disposed) return;
        _playing = playing;
        if (playing) {
          _startedPlaying = true;
          _watchdogTimer?.cancel();
        } else {
          _tracker?.onPaused();
        }
        _showControlsBriefly();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.position.listen((position) {
        if (_disposed) return;
        _position = position;
        // Auto Skip: if the position just entered an intro/recap/outro
        // segment and the setting is ON, jump to its end (once).
        _maybeAutoSkip();
        // Feed the tracker, as the VLC screen does: only samples taken while
        // playing count toward history / watched.
        if (_playing && _duration > Duration.zero) {
          _tracker?.onPlaying(
            ProgressSample(
              position: position,
              duration: _duration,
              token: _sessionToken,
            ),
          );
        }
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
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffer.listen((buffered) {
        if (_disposed) return;
        _buffered = buffered;
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.buffering.listen((buffering) {
        if (_disposed) return;
        _buffering = buffering;
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.completed.listen((completed) {
        if (_disposed) return;
        _completed = completed;
        if (completed) {
          try {
            _tracker?.finish();
          } catch (_) {}
          _showControls();
        }
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.tracks.listen((_) {
        if (_disposed) return;
        _applySubtitleAutoSelect();
        setState(() {});
      }),
    );
    _subs.add(
      _player.stream.error.listen((message) {
        if (_disposed) return;
        if (kDebugMode) debugPrint('mpv error: $message');
        // A dead source fails over; an error mid-play just shows in the log
        // — the watchdog owns startup, and a mid-play error is usually a
        // transient network hiccup mpv recovers from on its own.
        if (!_startedPlaying) _tryNextStream();
      }),
    );
  }

  Future<void> _resolveAndOpen() async {
    if (_disposed) return;
    // A fresh run is not abandoned; the flag belongs to the run the
    // viewer's Back cut short (see [_abandonAndPop]).
    _resolveAbandoned = false;
    // Everything this run learns is stamped with this, so the previous run's
    // stragglers can be told apart from this one's answers and dropped.
    final generation = ++_resolveGeneration;
    // Whatever the last run learned describes the last run. A retry
    // re-probes and an episode advance resolves different media, and either
    // one showing the previous attempt's list is worse than showing nothing.
    _forgetSources();
    _pickedBeforeOpen = null;
    final pick = _pick = Completer<int>();
    _abandonPendingResolve();
    final abandon = _abandonResolve = Completer<void>();
    // Asked alongside the plugin rather than after it: where to resume does
    // not depend on which source opens.
    final resumeLookup = resolveResumePoint(
      read: ref.read,
      item: widget.item,
      episode: _episode,
      videoUrl: _videoUrl,
    ).then<Duration?>(
      (point) => point?.position,
      onError: (Object e) {
        if (kDebugMode) debugPrint('mpv resume lookup failed: $e');
        return null;
      },
    );
    try {
      final resolved = await resolvePlayback(
        read: ref.read,
        item: widget.item,
        videoUrl: _videoUrl,
        preloadedStreams: _preloaded,
        isCancelled: () => _disposed,
        onCandidates: (streams) => _onCandidates(generation, streams),
        onProbe: (index, outcome) => _onProbe(generation, index, outcome),
        pick: pick.future,
        abandon: abandon.future,
      );
      if (_disposed || _resolveAbandoned) return;
      // The race is over. A pick from here on is held for the first open.
      _pick = null;
      _streams = resolved.streams;
      // A row picked while the race (or the resume lookup) was finishing is
      // the viewer's choice, and it outranks the resolver's.
      _streamIndex = _pickedBeforeOpen ?? resolved.index;
      _pickedBeforeOpen = null;
      _resumePosition = (await resumeLookup) ?? Duration.zero;
      if (_disposed) return;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      setState(() => _stage = _Stage.playing);
      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: _episode,
        videoUrl: _videoUrl,
        token: ++_sessionToken,
      );
      await _openStream(_streamIndex, start: _resumePosition);
    } on StreamResolutionException catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = describeStreamFailure(
          AppLocalizations.of(context)!,
          e,
        );
      });
    } catch (e) {
      if (_disposed) return;
      setState(() {
        _stage = _Stage.failed;
        _error = 'Could not load sources: $e';
      });
    }
  }

  void _abandonPendingResolve() {
    final abandon = _abandonResolve;
    if (abandon != null && !abandon.isCompleted) abandon.complete();
  }

  /// Drops everything the source list knew about the last resolve.
  void _forgetSources() {
    _candidates = const <StreamResult>[];
    _probes.clear();
  }

  /// The candidate list, the moment resolution has one.
  void _onCandidates(int generation, List<StreamResult> streams) {
    if (_disposed || !mounted || generation != _resolveGeneration) return;
    setState(() {
      _candidates = streams;
    });
  }

  /// One probe answered.
  void _onProbe(int generation, int index, ProbeOutcome outcome) {
    if (_disposed || !mounted || generation != _resolveGeneration) return;
    setState(() {
      _probes[index] = outcome;
    });
  }

  /// The viewer picked a row of the pre-play source list: the row is the
  /// choice, and the race ends on it.
  void _pickSourceRow(int index) {
    if (index < 0 || index >= _candidates.length) return;
    _pickedBeforeOpen = index;
    final pick = _pick;
    if (pick != null && !pick.isCompleted) pick.complete(index);
    setState(() {});
  }

  /// Backing out of the pre-play list abandons the resolve and leaves the
  /// player. The flag matters as much as the completer: resolvePlayback
  /// answers an abandon with the default source, so without it the resolve
  /// would open that source behind the screen the viewer just left.
  void _abandonAndPop() {
    _resolveAbandoned = true;
    _abandonPendingResolve();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _openStream(int index, {Duration? start}) async {
    if (_disposed || _streams.isEmpty) return;
    _streamIndex = index;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    final stream = _streams[index];
    _sessionToken++;
    _tracker = PlaybackTracker(
      read: ref.read,
      item: widget.item,
      episode: _episode,
      videoUrl: _videoUrl,
      token: _sessionToken,
    );
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
      return;
    }
    // Fail over near where the viewer was, rather than from the top.
    final resumeAt = _position > const Duration(seconds: 5)
        ? _position
        : Duration.zero;
    unawaited(_openStream(next, start: resumeAt));
  }

  /// Switches to another episode: per-episode reset, then a fresh resolve
  /// for the new episode (which shows the pre-play source list again).
  /// Manual switching only — there is no auto-advance in v19.
  /// Looks up intro/outro segments in the background.
  ///
  /// Never awaited by the open path: both sources are network lookups
  /// against crowdsourced databases, and playback must not wait on a
  /// convenience.
  Future<void> _loadSkipSegments(Episode? episode) async {
    if (episode == null) return;
    final generation = _resolveGeneration;
    final segments = await fetchSkipSegments(
      read: ref.read,
      item: widget.item,
      episode: episode,
    );
    if (_disposed || generation != _resolveGeneration || segments.isEmpty) {
      return;
    }
    setState(() => _skipSegments = segments);
  }

  /// Auto Skip (Settings → Player, default ON): when the position enters
  /// an intro/recap/outro segment, jump to its end. The guard is why a
  /// seek in flight does not re-fire: ticks still land inside the band
  /// for a frame or two after `seekTo`.
  void _maybeAutoSkip() {
    final autoSkip =
        ref.read(playerSettingsProvider).asData?.value.autoSkip ?? true;
    if (!autoSkip) return;
    if (!_playing) return;
    if (_skipSegments.isEmpty) return;
    final segment = segmentAt(_skipSegments, _position);
    if (segment == null) {
      _autoSkippedSegment = null;
      return;
    }
    if (segment.type != SkipType.intro &&
        segment.type != SkipType.recap &&
        segment.type != SkipType.outro) {
      return;
    }
    if (_sameSegment(segment, _autoSkippedSegment)) return;
    _autoSkippedSegment = segment;
    unawaited(
      _seekTo(
        Duration(milliseconds: (segment.endTime * 1000).round()),
      ),
    );
  }

  /// Same band (start + end + type), for the auto-skip guard.
  bool _sameSegment(SkipSegment a, SkipSegment? b) =>
      b != null &&
      a.startTime == b.startTime &&
      a.endTime == b.endTime &&
      a.type == b.type;

  static String _skipLabel(AppLocalizations l10n, SkipType type) =>
      switch (type) {
        SkipType.intro => l10n.skipIntro,
        SkipType.outro => l10n.skipOutro,
        SkipType.recap => l10n.skipRecap,
        SkipType.unknown => l10n.skip,
      };

  Future<void> _startEpisode(Episode next) async {
    if (_disposed) return;
    // Per-episode reset. The tracker and the resume point are rebuilt by
    // _resolveAndOpen; these are the ones nothing else clears.
    try {
      _tracker?.finish();
    } catch (_) {}
    _tracker = null;
    _forgetSources();
    _pickedBeforeOpen = null;
    _streams = const [];
    _streamIndex = 0;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _completed = false;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _resumePosition = Duration.zero;
    _watchdogTimer?.cancel();
    _preloaded = null; // route sources belong to the first episode only
    _skipSegments = const []; // previous episode's intro/outro
    _autoSkippedSegment = null;
    _episode = next;
    // A downloaded episode plays from disk, exactly as the details screen
    // does when it launches the first one.
    var nextUrl = next.url;
    try {
      final local = await ref
          .read(downloadServiceProvider)
          .getDownloadedFile(widget.item, episode: next);
      if (local != null) nextUrl = local.path;
    } catch (_) {
      // The lookup is a convenience; fall back to streaming.
    }
    if (_disposed) return;
    _videoUrl = AppUtils.normalizeUrl(nextUrl);
    setState(() => _stage = _Stage.resolving);
    await _resolveAndOpen();
    unawaited(_loadSkipSegments(next));
  }

  /// The episode list to navigate, filtered to one dub track when the series
  /// carries both (see [effectiveEpisodes]).
  List<Episode> get _episodes =>
      effectiveEpisodes(widget.item, _episode);

  Episode? get _nextEpisode =>
      nextEpisodeFor(
        item: widget.item,
        current: _episode,
        videoUrl: _videoUrl,
      ).next;

  Episode? get _previousEpisode => previousEpisodeFor(
        item: widget.item,
        current: _episode,
        videoUrl: _videoUrl,
      );

  /// "S1 E1 · Episode 1", mirroring the VLC episodes tab.
  String _episodeTitle(AppLocalizations l10n, Episode episode) {
    final name = episode.name.trim();
    final number = episode.season > 0
        ? l10n.playerSeasonEpisode(episode.season, episode.episode)
        : (episode.episode > 0
              ? l10n.playerEpisodeNumber(episode.episode)
              : '');
    if (number.isEmpty) return name.isEmpty ? l10n.unknown : name;
    return name.isEmpty ? number : '$number · $name';
  }

  String get _episodeLine {
    final episode = _episode;
    if (episode == null) return '';
    final l10n = AppLocalizations.of(context);
    return l10n == null ? episode.name : _episodeTitle(l10n, episode);
  }

  /// Picks a subtitle without being asked: the plugin's own subtitle file
  /// first (usually the right language), else the first embedded track.
  /// Runs once per source, when mpv reports its tracks.
  void _applySubtitleAutoSelect() {
    if (_disposed || _subtitleAppliedFor == _streamIndex) return;
    final stream = _selected;
    if (stream == null) return;
    final embedded = _player.state.tracks.subtitle
        // media_kit seeds the list with 'auto'/'no' pseudo-tracks; the
        // first REAL embedded track is the auto-select target, not 'auto'.
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
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

  // -- draggable subtitle ---------------------------------------------------

  /// The subtitle, drawn here instead of media_kit's built-in overlay
  /// (hidden in the Video widget above). Long-press the text to grab it,
  /// drag it anywhere on the picture, release to drop it there. The
  /// position is a fraction of the video area and is persisted, so it
  /// stays put across videos and sessions. It applies to embedded
  /// subtitles and plugin subtitle files alike — both arrive as `sub-text`
  /// on the same stream.
  ///
  /// The overlay sits inside the pinch-zoom Transform, so it moves and
  /// scales with the picture. Only the text itself is a hit target; a tap
  /// anywhere else still reaches the video gestures (controls toggle,
  /// volume/brightness, zoom). The drag reads the pointer's screen
  /// position through the video area's key: a local delta would chase
  /// itself, because the text (and its box) moves under the finger.
  Widget _buildDraggableSubtitle() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final area = Size(constraints.maxWidth, constraints.maxHeight);
        return StreamBuilder<List<String>>(
          stream: _player.stream.subtitle,
          initialData: _player.state.subtitle,
          builder: (context, snapshot) {
            final lines = [
              for (final line in (snapshot.data ?? const <String>[]))
                if (line.trim().isNotEmpty) line.trim(),
            ];
            final text = lines.join('\n');
            if (text.isEmpty) return const SizedBox.shrink();
            // The controls bar lifts the subtitle while it is up, as the
            // built-in padding did before (40 -> 116).
            final lift = _controlsVisible ? 0.095 : 0.0;
            final y = (_subtitlePos.dy - lift).clamp(0.05, 0.95);
            final x = _subtitlePos.dx.clamp(0.05, 0.95);
            return Positioned.fill(
              child: Align(
                alignment: Alignment(x * 2 - 1, y * 2 - 1),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPressStart: (details) {
                    if (_locked) return;
                    final box = _videoAreaKey.currentContext
                        ?.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final local =
                        box.globalToLocal(details.globalPosition);
                    _dragGrab = local -
                        Offset(
                          _subtitlePos.dx * area.width,
                          _subtitlePos.dy * area.height,
                        );
                    setState(() => _subtitleDragging = true);
                    _showToast('Drag the subtitle to move it');
                  },
                  onLongPressMoveUpdate: (details) {
                    if (!_subtitleDragging) return;
                    final box = _videoAreaKey.currentContext
                        ?.findRenderObject() as RenderBox?;
                    if (box == null) return;
                    final local =
                        box.globalToLocal(details.globalPosition);
                    final centre = local - _dragGrab;
                    setState(() {
                      _subtitlePos = Offset(
                        (centre.dx / area.width).clamp(0.05, 0.95),
                        (centre.dy / area.height).clamp(0.05, 0.95),
                      );
                    });
                  },
                  onLongPressEnd: (_) => _dropSubtitle(),
                  onLongPressCancel: () {
                    if (_subtitleDragging) {
                      setState(() => _subtitleDragging = false);
                    }
                  },
                  child: Container(
                    decoration: _subtitleDragging
                        ? BoxDecoration(
                            border: Border.all(
                              color: const Color(0xffd4af37),
                              width: 1.5,
                            ),
                            borderRadius: BorderRadius.circular(6),
                          )
                        : null,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: _styledSubtitleText(text),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// The drop: the drag ends, the gold outline goes away, and the spot is
  /// saved so the subtitle stays there.
  void _dropSubtitle() {
    if (!_subtitleDragging) return;
    setState(() => _subtitleDragging = false);
    _saveSubtitlePref(_kSubPosXKey, _subtitlePos.dx);
    _saveSubtitlePref(_kSubPosYKey, _subtitlePos.dy);
  }

  /// The subtitle text in the style panel's values: size, colour, the box
  /// behind it, and an outline (a stroked copy under the filled one —
  /// Flutter's TextStyle has no border of its own).
  Widget _styledSubtitleText(String text) {
    final fill = TextStyle(
      height: 1.4,
      fontSize: _subSize,
      color: Color(_subColor),
      fontWeight: FontWeight.w500,
      backgroundColor: _subBg == 0 ? Colors.transparent : Color(_subBg),
    );
    const align = TextAlign.center;
    if (_subOutline == SubtitleOutline.none) {
      return Text(text, style: fill, textAlign: align);
    }
    final strokeWidth = switch (_subOutline) {
      SubtitleOutline.thin => 1.0,
      SubtitleOutline.normal => 2.0,
      SubtitleOutline.thick => 3.0,
      SubtitleOutline.none => 0.0,
    };
    return Stack(
      alignment: Alignment.center,
      children: [
        Text(
          text,
          textAlign: align,
          style: TextStyle(
            height: 1.4,
            fontSize: _subSize,
            fontWeight: FontWeight.w500,
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = strokeWidth
              ..strokeJoin = StrokeJoin.round
              ..color = Colors.black,
          ),
        ),
        Text(text, style: fill, textAlign: align),
      ],
    );
  }

  // -- transport -----------------------------------------------------------

  Future<void> _togglePlayPause() async {
    if (_completed) {
      await _player.seek(Duration.zero);
      await _player.play();
      return;
    }
    await _player.playOrPause();
  }

  Future<void> _seekBy(Duration delta) async {
    if (_duration <= Duration.zero) return;
    final target = _clampDuration(
      _position + delta,
      Duration.zero,
      _duration,
    );
    _flashSeek(delta);
    await _player.seek(target);
  }

  Future<void> _seekTo(Duration target) async {
    if (_duration <= Duration.zero) return;
    await _player.seek(
      _clampDuration(target, Duration.zero, _duration),
    );
  }

  /// Duration has no `clamp`; this is the same bound, in milliseconds.
  Duration _clampDuration(Duration value, Duration min, Duration max) {
    if (value < min) return min;
    if (value > max) return max;
    return value;
  }

  Future<void> _setSpeed(double speed) async {
    _speed = speed;
    await _player.setRate(speed);
    if (mounted) setState(() {});
  }

  // -- subtitles / audio / source sheets -----------------------------------

  /// Opens a Gold & Black bottom sheet (drag handle, swipe down to dismiss).
  Future<T?> _goldSheet<T>(WidgetBuilder builder) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: const Color(0xff0a0a0b),
      showDragHandle: true,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        side: BorderSide(color: Color(0xff262626)),
      ),
      builder: (context) => SafeArea(child: builder(context)),
    );
  }

  void _showToast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: const Color(0xff1a1a1a),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// A section header inside a bottom sheet.
  Widget _sheetHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        title,
        style: const TextStyle(
          color: Color(0xffd4af37),
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// One Gold & Black panel with tabs at the top, replacing the three
  /// separate sheets: the settings sheet (Sources), the subtitle picker
  /// (Subtitles), the audio picker (Audio), and the episode list
  /// (Episodes). The Episodes tab only shows for a series. A row tap
  /// applies the choice and closes the panel — except the Subtitle style
  /// row, which opens the style panel in its place.
  Future<void> _showPanel(_PanelTab initialTab) async {
    if (!mounted) return;
    final tabs = <_PanelTab>[
      _PanelTab.sources,
      _PanelTab.audio,
      _PanelTab.subtitles,
      if (_episodes.length > 1) _PanelTab.episodes,
    ];
    var tab = tabs.contains(initialTab) ? initialTab : _PanelTab.sources;
    await _goldSheet<void>((context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          // Rebuilds when mpv reports tracks, so every tab fills in.
          return StreamBuilder<Tracks>(
            stream: _player.stream.tracks,
            initialData: _player.state.tracks,
            builder: (context, snapshot) {
              final tracks = snapshot.data ?? _player.state.tracks;
              final l10n = AppLocalizations.of(context)!;
              final tabWidgets = switch (tab) {
                _PanelTab.sources => _sourcesTab(tracks, context),
                _PanelTab.audio => _audioTab(tracks, context),
                _PanelTab.subtitles => _subtitlesTab(tracks, l10n, context),
                _PanelTab.episodes => _episodesTab(l10n, context),
              };
              return SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.65,
                child: Column(
                  children: [
                    // The tab bar, pinned at the top.
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final t in tabs)
                            _panelTabChip(
                              _panelTabLabel(t),
                              t == tab,
                              () => setSheetState(() => tab = t),
                            ),
                        ],
                      ),
                    ),
                    const Divider(color: Colors.white12, height: 1),
                    Expanded(
                      child: ListView(children: tabWidgets),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    });
  }

  String _panelTabLabel(_PanelTab tab) => switch (tab) {
        _PanelTab.sources => 'Sources',
        _PanelTab.audio => 'Audio',
        _PanelTab.subtitles => 'Subtitles',
        _PanelTab.episodes => 'Episodes',
      };

  Widget _panelTabChip(String label, bool active, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: active,
        onSelected: (_) => onTap(),
        selectedColor: const Color(0xffd4af37),
        backgroundColor: const Color(0xff1a1a1a),
        labelStyle: TextStyle(
          color: active ? Colors.black : Colors.white,
          fontWeight: active ? FontWeight.w700 : FontWeight.w400,
        ),
        side: BorderSide(
          color: active
              ? const Color(0xffd4af37)
              : Colors.white24,
        ),
      ),
    );
  }

  /// The Sources tab: the open source list, then Quality (the video
  /// tracks). A row tap applies the choice and closes the panel.
  List<Widget> _sourcesTab(Tracks tracks, BuildContext context) {
    final videoTracks = tracks.video
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final currentVideo = _player.state.track.video;
    return [
      _sheetHeader('Sources'),
      for (var i = 0; i < _streams.length; i++)
        ListTile(
          title: Text(
            _streams[i].displaySource,
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: _probeSubtitle(i),
          trailing: i == _streamIndex
              ? const Icon(Icons.check, color: Color(0xffd4af37))
              : null,
          onTap: () {
            Navigator.pop(context);
            if (i != _streamIndex) {
              unawaited(_openStream(i, start: _position));
            }
          },
        ),
      _sheetHeader('Quality'),
      ListTile(
        title: const Text(
          'Auto',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'mpv picks the best rendition',
          style: TextStyle(color: Colors.white54),
        ),
        trailing: currentVideo.id == 'auto'
            ? const Icon(Icons.check, color: Color(0xffd4af37))
            : null,
        onTap: () {
          Navigator.pop(context);
          unawaited(_player.setVideoTrack(VideoTrack.auto()));
        },
      ),
      if (videoTracks.isEmpty)
        const ListTile(
          title: Text(
            'No other renditions reported',
            style: TextStyle(color: Colors.white54),
          ),
        )
      else
        for (final vt in videoTracks)
          ListTile(
            title: Text(
              _videoTrackLabel(vt),
              style: const TextStyle(color: Colors.white),
            ),
            trailing: currentVideo.id == vt.id
                ? const Icon(Icons.check, color: Color(0xffd4af37))
                : null,
            onTap: () {
              Navigator.pop(context);
              unawaited(_player.setVideoTrack(vt));
            },
          ),
    ];
  }

  /// The Audio tab (like the VLC Audio tab): one row per audio track —
  /// "Track N - [Language]" with the channel layout below (e.g. "5.1")
  /// — a gold check on the active one, and a Retry (re-resolve) at the
  /// bottom for a list that never arrived.
  List<Widget> _audioTab(Tracks tracks, BuildContext context) {
    // media_kit seeds the list with 'auto'/'no' pseudo-tracks; only the
    // real audio tracks belong here. Filtering also makes the empty case
    // (still loading) real instead of two pseudo-rows.
    final audio = tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final current = _player.state.track.audio;
    if (audio.isEmpty) {
      return [
        _sheetHeader('Audio'),
        const Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xffd4af37),
                ),
              ),
              SizedBox(width: 12),
              Text(
                'Loading audio tracks…',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        _audioRetryRow(context),
      ];
    }
    return [
      _sheetHeader('Audio'),
      for (var i = 0; i < audio.length; i++)
        ListTile(
          title: Text(
            _audioTrackTitle(audio[i], i + 1),
            style: const TextStyle(color: Colors.white),
          ),
          subtitle: _audioTrackDetail(audio[i]) == null
              ? null
              : Text(
                  _audioTrackDetail(audio[i])!,
                  style: const TextStyle(color: Colors.white54),
                ),
          trailing: current.id == audio[i].id
              ? const Icon(Icons.check, color: Color(0xffd4af37))
              : null,
          onTap: () {
            Navigator.pop(context);
            unawaited(_player.setAudioTrack(audio[i]));
            if (mounted) setState(() {});
          },
        ),
      _audioRetryRow(context),
    ];
  }

  /// "Track N - [Language]": the engine's own title only when it is not
  /// a bare counter; otherwise the language name (ISO code looked up),
  /// otherwise the bare number.
  String _audioTrackTitle(AudioTrack track, int number) {
    final title = track.title?.trim() ?? '';
    if (title.isNotEmpty && !_isPlaceholderTrackName(title)) return title;
    final language = languageNameForCode(track.language ?? '') ??
        track.language?.trim();
    if (language != null && language.isNotEmpty) {
      return 'Track $number - $language';
    }
    return title.isEmpty ? 'Track $number' : title;
  }

  /// Whether [name] is the engine counting rather than naming.
  bool _isPlaceholderTrackName(String name) => RegExp(
        r'^(audio |subtitle |spu )?track\s*#?\d*$',
        caseSensitive: false,
      ).hasMatch(name);

  /// The second line: the channel layout (e.g. "5.1") and the codec,
  /// whichever of them exist.
  String? _audioTrackDetail(AudioTrack track) {
    final parts = <String>[];
    if (track.channels != null && track.channels!.isNotEmpty) {
      parts.add(track.channels!);
    } else if (track.channelscount != null) {
      parts.add('${track.channelscount}ch');
    }
    if (track.codec != null && track.codec!.isNotEmpty) {
      parts.add(track.codec!.toUpperCase());
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// The Retry row: re-resolves the sources (so a track list that never
  /// arrived gets another chance) and re-opens from the resume point.
  Widget _audioRetryRow(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.refresh, color: Colors.white70),
      title: const Text(
        'Retry',
        style: TextStyle(color: Colors.white),
      ),
      subtitle: const Text(
        'Re-resolve the sources',
        style: TextStyle(color: Colors.white54),
      ),
      onTap: () {
        Navigator.pop(context);
        setState(() => _stage = _Stage.resolving);
        unawaited(_resolveAndOpen());
      },
    );
  }

  /// The Subtitles tab: Off, the plugin's subtitle files, the tracks
  /// inside the video, and the Subtitle style row (which opens the style
  /// panel in this panel's place). A hint for the drag sits under the
  /// style row.
  List<Widget> _subtitlesTab(
    Tracks tracks,
    AppLocalizations l10n,
    BuildContext context,
  ) {
    // As in the audio tab: only the real embedded tracks belong here.
    final embedded = tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .toList();
    final external = _selected?.subtitles ?? const [];
    final current = _player.state.track.subtitle;
    return [
      _sheetHeader('Subtitles'),
      ListTile(
        title: const Text(
          'Off',
          style: TextStyle(color: Colors.white),
        ),
        trailing: current.id == 'no'
            ? const Icon(Icons.check, color: Color(0xffd4af37))
            : null,
        onTap: () {
          Navigator.pop(context);
          unawaited(_player.setSubtitleTrack(SubtitleTrack.no()));
          if (mounted) setState(() {});
        },
      ),
      for (final sub in external)
        ListTile(
          title: Text(
            '${sub.label} (source)',
            style: const TextStyle(color: Colors.white),
          ),
          trailing: current.title == sub.label
              ? const Icon(Icons.check, color: Color(0xffd4af37))
              : null,
          onTap: () {
            Navigator.pop(context);
            unawaited(
              _player.setSubtitleTrack(
                SubtitleTrack.uri(sub.url, title: sub.label),
              ),
            );
            if (mounted) setState(() {});
          },
        ),
      for (final sub in embedded)
        ListTile(
          title: Text(
            sub.title ?? 'Subtitle ${sub.id}',
            style: const TextStyle(color: Colors.white),
          ),
          trailing: current.id == sub.id
              ? const Icon(Icons.check, color: Color(0xffd4af37))
              : null,
          onTap: () {
            Navigator.pop(context);
            unawaited(_player.setSubtitleTrack(sub));
            if (mounted) setState(() {});
          },
        ),
      if (embedded.isEmpty && external.isEmpty)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Row(
            children: [
              SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Color(0xffd4af37),
                ),
              ),
              SizedBox(width: 12),
              Text(
                'Loading subtitles…',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      const Divider(color: Colors.white12, height: 1),
      ListTile(
        leading: const Icon(Icons.tune, color: Color(0xffd4af37)),
        title: const Text(
          'Subtitle style',
          style: TextStyle(color: Colors.white),
        ),
        subtitle: const Text(
          'Size · Colour · Background · Outline · Position',
          style: TextStyle(color: Colors.white54),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          color: Colors.white54,
        ),
        onTap: () {
          Navigator.pop(context);
          unawaited(_showSubtitleStylePanel());
        },
      ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text(
          'Tip: long-press a subtitle on the video to drag it where you want it.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
    ];
  }

  /// The Episodes tab: one row per episode ("S1 E1 · Episode 1"), the
  /// current one checked. A row tap switches to it.
  List<Widget> _episodesTab(AppLocalizations l10n, BuildContext context) {
    final episodes = _episodes;
    return [
      _sheetHeader('Episodes'),
      for (final ep in episodes)
        ListTile(
          title: Text(
            _episodeTitle(l10n, ep),
            style: const TextStyle(color: Colors.white),
          ),
          trailing: ep == _episode
              ? const Icon(Icons.check, color: Color(0xffd4af37))
              : null,
          onTap: () {
            Navigator.pop(context);
            if (ep != _episode) unawaited(_startEpisode(ep));
          },
        ),
    ];
  }

  /// The Subtitle Style (customize) panel: the appearance rows, each with
  /// a - / + stepper. It applies to subtitle files and the subtitles
  /// inside the video alike, because both are drawn by the same Flutter
  /// overlay ([_styledSubtitleText]) — mpv's own sub-* properties render
  /// nothing while libass is off, so the overlay is where style lives.
  /// The Position preset (Bottom/Top) resets the dragged position; the
  /// long-press drag is the free custom position.
  Future<void> _showSubtitleStylePanel() async {
    if (!mounted) return;
    await _goldSheet<void>((context) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          void update(void Function() change) {
            setSheetState(change);
            if (mounted) setState(() {});
          }

          final l10n = AppLocalizations.of(context)!;
          return SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.6,
            child: ListView(
              children: [
                _sheetHeader('Subtitle style'),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'These change how subtitles look — for subtitle files and subtitles inside the video.',
                    style: TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ),
                _stepperRow(
                  label: 'Text size',
                  value: _subSize.round().toString(),
                  onMinus: () => update(() {
                    _subSize = (_subSize - 2).clamp(12, 48);
                    _saveSubtitlePref(_kSubSizeKey, _subSize);
                  }),
                  onPlus: () => update(() {
                    _subSize = (_subSize + 2).clamp(12, 48);
                    _saveSubtitlePref(_kSubSizeKey, _subSize);
                  }),
                  onReset: () => update(() {
                    _subSize = _kSubtitleFontSize;
                    _saveSubtitlePref(_kSubSizeKey, _subSize);
                  }),
                ),
                _stepperRow(
                  label: 'Text colour',
                  value: subtitleColorLabel(l10n, _subColor),
                  onMinus: () => update(() {
                    _subColor = _cycleColor(_subColor, -1);
                    _saveSubtitlePref(_kSubColorKey, _subColor);
                  }),
                  onPlus: () => update(() {
                    _subColor = _cycleColor(_subColor, 1);
                    _saveSubtitlePref(_kSubColorKey, _subColor);
                  }),
                  onReset: () => update(() {
                    _subColor = 0xFFFFFFFF;
                    _saveSubtitlePref(_kSubColorKey, _subColor);
                  }),
                ),
                _stepperRow(
                  label: 'Background',
                  value: _subBg == 0
                      ? 'Off'
                      : subtitleColorLabel(l10n, _subBg),
                  onMinus: () => update(() {
                    _subBg = _cycleBackground(_subBg, -1);
                    _saveSubtitlePref(_kSubBgKey, _subBg);
                  }),
                  onPlus: () => update(() {
                    _subBg = _cycleBackground(_subBg, 1);
                    _saveSubtitlePref(_kSubBgKey, _subBg);
                  }),
                  onReset: () => update(() {
                    _subBg = 0;
                    _saveSubtitlePref(_kSubBgKey, _subBg);
                  }),
                ),
                _stepperRow(
                  label: 'Outline',
                  value: subtitleOutlineLabel(l10n, _subOutline),
                  onMinus: () => update(() {
                    _subOutline = _cycleOutline(_subOutline, -1);
                    _saveSubtitlePref(
                      _kSubOutlineKey,
                      _subOutline.name,
                    );
                  }),
                  onPlus: () => update(() {
                    _subOutline = _cycleOutline(_subOutline, 1);
                    _saveSubtitlePref(
                      _kSubOutlineKey,
                      _subOutline.name,
                    );
                  }),
                  onReset: () => update(() {
                    _subOutline = SubtitleOutline.thin;
                    _saveSubtitlePref(
                      _kSubOutlineKey,
                      _subOutline.name,
                    );
                  }),
                ),
                _stepperRow(
                  label: 'Position',
                  value: _subtitlePositionLabel(),
                  onMinus: () => update(() {
                    _setSubtitlePositionPreset(top: false);
                  }),
                  onPlus: () => update(() {
                    _setSubtitlePositionPreset(top: true);
                  }),
                  onReset: () => update(() {
                    _setSubtitlePositionPreset(top: false);
                  }),
                ),
                const Divider(color: Colors.white12, height: 1),
                ListTile(
                  leading: const Icon(
                    Icons.restart_alt_rounded,
                    color: Color(0xffd4af37),
                  ),
                  title: const Text(
                    'Reset subtitle style',
                    style: TextStyle(color: Colors.white),
                  ),
                  onTap: () => update(() {
                    _subSize = _kSubtitleFontSize;
                    _subColor = 0xFFFFFFFF;
                    _subBg = 0;
                    _subOutline = SubtitleOutline.thin;
                    _subtitlePos = _kDefaultSubtitlePos;
                    _saveSubtitlePref(_kSubSizeKey, _subSize);
                    _saveSubtitlePref(_kSubColorKey, _subColor);
                    _saveSubtitlePref(_kSubBgKey, _subBg);
                    _saveSubtitlePref(
                      _kSubOutlineKey,
                      _subOutline.name,
                    );
                    _saveSubtitlePref(_kSubPosXKey, _subtitlePos.dx);
                    _saveSubtitlePref(_kSubPosYKey, _subtitlePos.dy);
                  }),
                ),
              ],
            ),
          );
        },
      );
    });
  }

  /// One appearance row: the label, the current value, and - / + steppers
  /// (plus an optional reset, for the rows that have one).
  Widget _stepperRow({
    required String label,
    required String value,
    required VoidCallback onMinus,
    required VoidCallback onPlus,
    VoidCallback? onReset,
  }) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      subtitle: Text(value, style: const TextStyle(color: Colors.white54)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onReset != null)
            IconButton(
              onPressed: onReset,
              icon: const Icon(
                Icons.restart_alt_rounded,
                color: Color(0xffd4af37),
                size: 20,
              ),
              tooltip: 'Reset',
            ),
          IconButton(
            onPressed: onMinus,
            icon: const Icon(Icons.remove, color: Colors.white, size: 20),
            tooltip: 'Decrease',
          ),
          IconButton(
            onPressed: onPlus,
            icon: const Icon(Icons.add, color: Colors.white, size: 20),
            tooltip: 'Increase',
          ),
        ],
      ),
    );
  }

  /// The next colour in the caption list, wrapping around.
  int _cycleColor(int current, int step) {
    final i = kSubtitleTextColors.indexOf(current);
    final next = (i < 0 ? 0 : i + step) % kSubtitleTextColors.length;
    return kSubtitleTextColors[next < 0
        ? next + kSubtitleTextColors.length
        : next];
  }

  /// The next background: Off, then the box colours, wrapping around.
  int _cycleBackground(int current, int step) {
    final choices = <int>[0, ...kSubtitleBackgroundColors];
    final i = choices.indexOf(current);
    final next = (i < 0 ? 0 : i + step) % choices.length;
    return choices[next < 0 ? next + choices.length : next];
  }

  /// The next outline in the order None, Thin, Normal, Thick.
  SubtitleOutline _cycleOutline(SubtitleOutline current, int step) {
    const values = SubtitleOutline.values;
    final next = (values.indexOf(current) + step) % values.length;
    return values[next < 0 ? next + values.length : next];
  }

  /// What the Position row reads: Bottom or Top for the presets, Custom
  /// when the viewer dragged the subtitle somewhere else.
  String _subtitlePositionLabel() {
    const tolerance = 0.02;
    if ((_subtitlePos - _kDefaultSubtitlePos).distance < tolerance) {
      return 'Bottom';
    }
    if ((_subtitlePos - _kTopSubtitlePos).distance < tolerance) {
      return 'Top';
    }
    return 'Custom';
  }

  /// A Position preset: Bottom puts the subtitle back at its default spot,
  /// Top puts it near the top edge. Either also clears a dragged custom
  /// spot for the preset one (the drag can move it again after).
  void _setSubtitlePositionPreset({required bool top}) {
    _subtitlePos = top ? _kTopSubtitlePos : _kDefaultSubtitlePos;
    _saveSubtitlePref(_kSubPosXKey, _subtitlePos.dx);
    _saveSubtitlePref(_kSubPosYKey, _subtitlePos.dy);
  }

  /// A source row's probe status, as a subtitle line (or null).
  Widget? _probeSubtitle(int index) {
    final outcome = _probes[index];
    if (outcome == null) return null;
    final reachability = sourceReachabilityOf(
      _streams[index],
      outcome,
    );
    final label = sourceReachabilityLabel(
      AppLocalizations.of(context)!,
      reachability,
    );
    return Text(label, style: const TextStyle(color: Colors.white54));
  }

  /// "1920×1080", falling back to the track's own title.
  String _videoTrackLabel(VideoTrack track) {
    if (track.w != null && track.h != null) {
      return '${track.w}×${track.h}';
    }
    if (track.title != null && track.title!.isNotEmpty) return track.title!;
    return 'Video ${track.id}';
  }

  Future<void> _pickSpeed() async {
    if (!mounted) return;
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 3.0];
    final choice = await _goldSheet<double>((context) {
      return ListView(
        shrinkWrap: true,
        children: [
          _sheetHeader('Playback speed'),
          for (final speed in speeds)
            ListTile(
              title: Text(
                '${speed}x',
                style: const TextStyle(color: Colors.white),
              ),
              trailing: speed == _speed
                  ? const Icon(Icons.check, color: Color(0xffd4af37))
                  : null,
              onTap: () => Navigator.pop(context, speed),
            ),
        ],
      );
    });
    if (choice != null) await _setSpeed(choice);
  }

  // -- picture-in-picture (forked media_kit_video) -------------------------

  /// The fork's PiP channel. The native side (MpvPip in the fork) swaps the
  /// GL render context for a software one and feeds the frames to an
  /// AVSampleBufferDisplayLayer.
  static const MethodChannel _pipChannel =
      MethodChannel('dev.akash.skystream.mpv_pip');

  /// The PiP button toggles: enter when off, leave when on.
  Future<void> _togglePip() async {
    if (_pipActive) {
      await _exitPip();
    } else {
      await _enterPip();
    }
  }

  /// Enters PiP. Manual button only for this build — auto-PiP on a Home
  /// swipe gives almost no time to swap render contexts.
  ///
  /// If the native side cannot show real video, it throws and the button
  /// stays out of the way: no black PiP is ever shipped.
  Future<void> _enterPip() async {
    if (_pipActive || !mounted || _stage != _Stage.playing) return;
    try {
      // GPU-free decode path first: hardware decode, frames copied to
      // system memory, so the software render context has something to draw.
      final native = _player.platform as NativePlayer;
      await native.setProperty('hwdec', 'videotoolbox-copy');
      final handle = await _player.handle;
      await _pipChannel.invokeMethod('start', {
        'handle': handle,
        'duration': _duration.inMilliseconds / 1000.0,
      });
      _pipActive = true;
      if (mounted) setState(() {});
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('mpv pip start failed: $e');
      _showToast('Picture-in-picture is not available right now');
      // Back to the GPU decode path.
      try {
        await (_player.platform as NativePlayer)
            .setProperty('hwdec', 'videotoolbox');
      } catch (_) {}
    } catch (e) {
      if (kDebugMode) debugPrint('mpv pip start failed: $e');
      _showToast('Picture-in-picture is not available right now');
      try {
        await (_player.platform as NativePlayer)
            .setProperty('hwdec', 'videotoolbox');
      } catch (_) {}
    }
  }

  /// Leaves PiP (Dart-initiated). The native callback path uses
  /// [_restoreAfterPip] directly, since the native side has already stopped.
  Future<void> _exitPip() async {
    if (!_pipActive) return;
    try {
      await _pipChannel.invokeMethod('stop');
    } catch (_) {}
    await _restoreAfterPip();
  }

  // -- lock / orientation ---------------------------------------------------

  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      if (_locked) {
        _hideTimer?.cancel();
        _controlsVisible = false;
      } else {
        _showControls();
      }
    });
  }

  /// Rotates between landscape and portrait. The player forces landscape on
  /// a portrait handset at start; this lets the viewer turn it back.
  Future<void> _toggleOrientation() async {
    final size = MediaQuery.sizeOf(context);
    final portrait = size.width < size.height;
    await SystemChrome.setPreferredOrientations(
      portrait
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
  }

  // -- gestures -------------------------------------------------------------

  void _showControls() {
    if (_disposed) return;
    _controlsVisible = true;
    _hideTimer?.cancel();
    _hideTimer = Timer(_kControlsAutoHide, () {
      if (_disposed) return;
      setState(() => _controlsVisible = false);
    });
    if (mounted) setState(() {});
  }

  void _showControlsBriefly() {
    // A play/pause change brings the bars up, then they hide themselves.
    _showControls();
  }

  void _toggleControls() {
    if (_locked) return;
    // A tap up after a long hold still counts as a tap; a hold that
    // just ended (2x) must not also toggle the controls.
    if (_justEndedHoldSpeed) {
      _justEndedHoldSpeed = false;
      return;
    }
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  void _flashSeek(Duration delta) {
    // A small side pill, not a centre box: left edge for -10 s, right
    // edge for +10 s. It fades out quickly (700 ms).
    _seekFlashDir = delta.inSeconds > 0 ? 1 : -1;
    _seekFlashVisible = true;
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (_disposed) return;
      setState(() => _seekFlashVisible = false);
    });
    setState(() {});
  }

  /// Press-and-hold on the right half: 2x while held (YouTube-style).
  /// Uses the tap recognizer + a timer, not a long-press recognizer, so
  /// it cannot steal the arena from the subtitle's long-press drag.
  /// A quick tap or a drag never reaches the timer, so double-tap seek
  /// and vertical volume swipes are unaffected.
  void _onTapDownForHoldSpeed(TapDownDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    if (details.globalPosition.dx <= width / 2) return;
    _holdSpeedTimer?.cancel();
    _holdSpeedTimer = Timer(const Duration(milliseconds: 550), () {
      if (_disposed || _subtitleDragging || _locked) return;
      _activateHoldSpeed();
    });
  }

  void _activateHoldSpeed() {
    _speedBeforeHold = _speed;
    _holdSpeedActive = true;
    unawaited(_player.setRate(2.0));
    setState(() {});
  }

  void _endHoldSpeed() {
    _holdSpeedTimer?.cancel();
    if (!_holdSpeedActive) return;
    _holdSpeedActive = false;
    _justEndedHoldSpeed = true;
    unawaited(_player.setRate(_speedBeforeHold));
    setState(() {});
  }

  /// Horizontal scrub: drag left/right to move through the video. The
  /// target is only previewed while dragging; the seek happens on
  /// release, so the mpv backward cache makes a backward scrub instant.
  /// Flutter's gesture arena sends mostly-horizontal drags here and
  /// mostly-vertical ones to the brightness/volume handler, so the two
  /// never fight; a double-tap is a tap, not a drag.
  void _onHorizontalDragStart(DragStartDetails details) {
    if (_isLive || _duration <= Duration.zero || !_canSeek) return;
    _scrubTimer?.cancel();
    _scrubbing = true;
    _scrubStartPosition = _position;
    _scrubDx = 0;
    _scrubTarget = _position;
    _scrubVisible = true;
    setState(() {});
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details, double width) {
    if (!_scrubbing || _duration <= Duration.zero) return;
    _scrubDx += details.delta.dx;
    // A full-width drag moves 10% of the duration.
    final deltaMs =
        (_scrubDx / width * _duration.inMilliseconds * 0.1).round();
    _scrubTarget = _clampDuration(
      _scrubStartPosition + Duration(milliseconds: deltaMs),
      Duration.zero,
      _duration,
    );
    setState(() {});
  }

  void _onHorizontalDragEnd(_) {
    if (!_scrubbing) return;
    _scrubbing = false;
    final target = _scrubTarget;
    if (target != null) unawaited(_seekTo(target));
    // Fade the preview out shortly after the seek.
    _scrubTimer?.cancel();
    _scrubTimer = Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      setState(() => _scrubVisible = false);
    });
    setState(() {});
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_locked) return;
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (x < width / 3) {
      unawaited(_seekBy(-_kSeekStep));
    } else if (x > width * 2 / 3) {
      unawaited(_seekBy(_kSeekStep));
    } else {
      // Centre double-tap toggles play/pause; no centre flash — the
      // viewer asked for nothing big in the middle of the video.
      unawaited(_togglePlayPause());
    }
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double width) {
    final x = details.globalPosition.dx;
    final delta = -details.delta.dy / 200;
    // A new swipe cancels the fade-out and brings the HUD back.
    _hudTimer?.cancel();
    if (x < width / 2) {
      // Left half: brightness.
      _brightness = (_brightness + delta).clamp(0.05, 1.0);
      _brightnessApi.set(_brightness);
      _hudKind = _HudKind.brightness;
      _hudValue = _brightness;
    } else {
      // Right half: engine volume.
      _volume = (_volume + delta * 100).clamp(0.0, 100.0);
      unawaited(_player.setVolume(_volume));
      _hudKind = _HudKind.volume;
      _hudValue = _volume / 100;
    }
    _hudVisible = true;
    setState(() {});
  }

  void _onVerticalDragEnd(_) {
    // The HUD lingers ~1.5 s after the swipe ends, then fades out.
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_disposed) return;
      if (mounted) setState(() => _hudVisible = false);
    });
  }

  /// The swipe HUD: a dark pill at the top centre with the sun (brightness)
  /// or speaker (volume) icon, a gold fill bar for the level, and the %
  /// value. It fades and slides in on a swipe and fades out after the
  /// swipe ends; it is display-only, so it never eats a tap.
  Widget _buildHud() {
    final kind = _hudKind!;
    final percent = (_hudValue * 100).round();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: IgnorePointer(
          child: AnimatedOpacity(
            opacity: _hudVisible ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 250),
            child: AnimatedSlide(
              offset: _hudVisible ? Offset.zero : const Offset(0, -0.4),
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOut,
              child: Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 56),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xcc1a1a1a),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          kind == _HudKind.brightness
                              ? Icons.wb_sunny
                              : Icons.volume_up,
                          color: const Color(0xffd4af37),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        // The level bar: a dark track with a gold fill.
                        Stack(
                          children: [
                            Container(
                              width: 120,
                              height: 5,
                              decoration: BoxDecoration(
                                color: Colors.white24,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 100),
                              width: 120 * _hudValue.clamp(0.0, 1.0),
                              height: 5,
                              decoration: BoxDecoration(
                                color: const Color(0xffd4af37),
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 44,
                          child: Text(
                            '$percent%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // -- build ----------------------------------------------------------------

  String _format(Duration d) {
    final total = math.max(0, d.inSeconds);
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  bool get _canSeek => _duration > Duration.zero && !_isLive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const gold = Color(0xffd4af37);
    final position = _position;
    final duration = _duration;
    // The intro/recap/outro segment the position is inside right now,
    // if any — drives the Skip Intro chip (and only that).
    final skipSegment = segmentAt(_skipSegments, _position);
    final bufferedFrac = _canSeek
        ? (_buffered.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video + gestures.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            // Press-and-hold 2x (right half): tap down starts the hold
            // timer; tap up / cancel ends it. A quick tap or a drag
            // cancels the timer before it fires.
            onTapDown: _onTapDownForHoldSpeed,
            onTapUp: (_) => _endHoldSpeed(),
            onTapCancel: () => _endHoldSpeed(),
            onDoubleTapDown: _onDoubleTapDown,
            onScaleStart: (_) => _zoomBase = _zoom,
            onScaleUpdate: (details) {
              setState(() {
                _zoom = (_zoomBase * details.scale).clamp(_kMinZoom, _kMaxZoom);
              });
            },
            // Horizontal drag = scrub; vertical drag = brightness/volume.
            // The arena picks the dominant direction, so they never fight.
            onHorizontalDragStart: _onHorizontalDragStart,
            onHorizontalDragUpdate: (details) => _onHorizontalDragUpdate(
              details,
              MediaQuery.sizeOf(context).width,
            ),
            onHorizontalDragEnd: _onHorizontalDragEnd,
            onVerticalDragUpdate: (details) => _onVerticalDragUpdate(
              details,
              MediaQuery.sizeOf(context).width,
            ),
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Center(
              child: Transform.scale(
                scale: _zoom,
                child: Stack(
                  key: _videoAreaKey,
                  children: [
                    Video(
                      controller: _videoController,
                      fit: BoxFit.contain,
                      fill: Colors.black,
                      // Custom controls below; media_kit's own are hidden.
                      controls: (_) => const SizedBox.shrink(),
                      wakelock: true,
                      pauseUponEnteringBackgroundMode: true,
                      // media_kit's own subtitle overlay is hidden: the
                      // subtitle is drawn by [_buildDraggableSubtitle]
                      // instead, so the viewer can long-press it and drag
                      // it anywhere on the picture, and the style panel
                      // can restyle it. One renderer only, never two.
                      subtitleViewConfiguration:
                          const SubtitleViewConfiguration(
                        visible: false,
                      ),
                    ),
                    // The draggable subtitle, over the video (same
                    // Transform, so it moves and scales with pinch zoom).
                    if (_stage == _Stage.playing && !_locked)
                      _buildDraggableSubtitle(),
                  ],
                ),
              ),
            ),
          ),

          // Resolving: the pre-play source list once the plugin has
          // answered, a spinner while it has not. The spinner has a Back
          // button too: a slow or stuck source must not trap the viewer
          // on a black screen (see [_abandonAndPop]).
          if (_stage == _Stage.resolving)
            _candidates.isEmpty
                ? Stack(
                    children: [
                      Container(
                        color: Colors.black,
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(
                                color: Color(0xffd4af37),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10n.loading,
                                style:
                                    const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: const EdgeInsets.all(8),
                            child: IconButton(
                              onPressed: _abandonAndPop,
                              icon: const Icon(
                                Icons.arrow_back,
                                color: Colors.white,
                              ),
                              tooltip: 'Back',
                            ),
                          ),
                        ),
                      ),
                    ],
                  )
                : _PrePlaySourceView(
                    title: widget.item.title,
                    episodeLine: _episodeLine.isEmpty ? null : _episodeLine,
                    candidates: _candidates,
                    probes: _probes,
                    selectedIndex: _pickedBeforeOpen ?? 0,
                    picked: _pickedBeforeOpen != null,
                    onPick: _pickSourceRow,
                    onBack: _abandonAndPop,
                  ),
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
                              });
                              unawaited(_resolveAndOpen());
                            },
                            child: Text(l10n.retry),
                          ),
                          const SizedBox(width: 12),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(l10n.cancel),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Buffering spinner (playing but waiting on data).
          if (_stage == _Stage.playing && _playing && _buffering)
            const Center(
              child: CircularProgressIndicator(color: Color(0xffd4af37)),
            ),

          // Double-tap seek flash: a SMALL pill at the edge where the
          // tap happened (left for -10 s, right for +10 s). Nothing big
          // in the centre — the viewer asked for that. It fades out
          // quickly, and is display-only.
          if (_seekFlashDir != 0)
            Align(
              alignment: Alignment(_seekFlashDir.toDouble(), 0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AnimatedOpacity(
                  opacity: _seekFlashVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xcc1a1a1a),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _seekFlashDir > 0
                                ? Icons.forward_10
                                : Icons.replay_10,
                            color: const Color(0xffd4af37),
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${_seekFlashDir > 0 ? '+' : '-'}${_kSeekStep.inSeconds}s',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Brightness / volume HUD (top-centre pill): fades and slides
          // in on a vertical swipe, follows the level live, and fades out
          // ~1.5 s after the swipe ends. Display-only, never interactive.
          if (_hudKind != null) _buildHud(),

          // Horizontal scrub preview: a small pill above the bottom bar
          // showing the time the drag will land on. The seek happens on
          // release; this is only the preview, and it fades out after.
          if (_scrubTarget != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 110,
              child: Align(
                alignment: Alignment.center,
                child: AnimatedOpacity(
                  opacity: _scrubVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xcc1a1a1a),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.fast_forward,
                            color: Color(0xffd4af37),
                            size: 18,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _format(_scrubTarget!),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),

          // Tap-and-hold 2x indicator: a small gold pill at the top
          // centre while the right half is held. Hidden the moment the
          // finger lifts.
          if (_holdSpeedActive)
            Positioned(
              top: 90,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.center,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xcc1a1a1a),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.fast_forward,
                          color: Color(0xffd4af37),
                          size: 18,
                        ),
                        SizedBox(width: 6),
                        Text(
                          '2x speed',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Skip Intro chip (bottom-right, above the bottom bar): shows
          // only while the position is inside an intro/recap/outro
          // segment — for any series with timestamps (anime, drama,
          // Netflix shows). Tapping jumps to the end of the segment.
          // When Auto Skip is ON the position never lingers here, so the
          // chip is mostly seen when it is OFF. No chip when the episode
          // has no segments.
          if (skipSegment != null)
            Positioned(
              right: 16,
              bottom: 110,
              child: GestureDetector(
                onTap: () {
                  _autoSkippedSegment = skipSegment;
                  unawaited(
                    _seekTo(
                      Duration(
                        milliseconds: (skipSegment.endTime * 1000).round(),
                      ),
                    ),
                  );
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xcc1a1a1a),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.fast_forward_rounded,
                        color: Color(0xffd4af37),
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _skipLabel(l10n, skipSegment.type),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Ended card.
          if (_stage == _Stage.playing && _completed)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.item.title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        FilledButton.icon(
                          onPressed: () async {
                            await _player.seek(Duration.zero);
                            await _player.play();
                          },
                          icon: const Icon(Icons.replay),
                          label: const Text('Replay'),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(l10n.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Locked: only an unlock button; the video keeps playing.
          if (_stage == _Stage.playing && _locked)
            Center(
              child: Container(
                decoration: const BoxDecoration(
                  color: Colors.black54,
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  onPressed: _toggleLock,
                  icon: const Icon(Icons.lock_open, color: Colors.white),
                  iconSize: 32,
                  tooltip: 'Unlock',
                ),
              ),
            ),

          // Controls overlay.
          if (_stage == _Stage.playing &&
              _controlsVisible &&
              !_completed &&
              !_locked)
            _ControlsOverlay(
              gold: gold,
              title: widget.item.title,
              episodeLine: _episodeLine.isEmpty ? null : _episodeLine,
              isLive: _isLive,
              playing: _playing,
              buffering: _buffering,
              position: position,
              duration: duration,
              bufferedFraction: bufferedFrac,
              canSeek: _canSeek,
              sourceLabel: _selected?.displaySource,
              hasEpisodes: _episodes.length > 1,
              hasPreviousEpisode: _previousEpisode != null,
              hasNextEpisode: _nextEpisode != null,
              pipAvailable: _pipAvailable,
              pipActive: _pipActive,
              onBack: () => Navigator.of(context).pop(),
              onPlayPause: _togglePlayPause,
              onSeekBack: () => unawaited(_seekBy(-_kSeekStep)),
              onSeekForward: () => unawaited(_seekBy(_kSeekStep)),
              onSeekTo: (value) => unawaited(
                _seekTo(
                  Duration(
                    milliseconds: (value * duration.inMilliseconds).round(),
                  ),
                ),
              ),
              onSettings: () => unawaited(_showPanel(_PanelTab.sources)),
              onSubtitle: () =>
                  unawaited(_showPanel(_PanelTab.subtitles)),
              onAudio: () => unawaited(_showPanel(_PanelTab.audio)),
              onSpeed: _pickSpeed,
              onPip: _togglePip,
              onLock: _toggleLock,
              onRotate: _toggleOrientation,
              onFullscreen: () =>
                  _showToast('Already fullscreen'),
              onPreviousEpisode: () {
                final prev = _previousEpisode;
                if (prev != null) unawaited(_startEpisode(prev));
              },
              onNextEpisode: () {
                final next = _nextEpisode;
                if (next != null) unawaited(_startEpisode(next));
              },
              showRemainingTime: _showRemainingTime,
              onToggleTime: () =>
                  setState(() => _showRemainingTime = !_showRemainingTime),
              format: _format,
            ),
        ],
      ),
    );
  }
}

/// Top bar + centre transport + compact bottom icon toolbar, Gold & Black.
///
/// The bottom toolbar is the approved v19 design: a gold seek bar above a
/// single row whose left side is previous/next episode + time and whose
/// right side is a dark pill of small gold icons (settings, subtitles,
/// audio, speed, lock, PiP, rotate, fullscreen). No big text chips.
class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.gold,
    required this.title,
    required this.episodeLine,
    required this.isLive,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedFraction,
    required this.canSeek,
    required this.sourceLabel,
    required this.hasEpisodes,
    required this.hasPreviousEpisode,
    required this.hasNextEpisode,
    required this.pipAvailable,
    required this.pipActive,
    required this.onBack,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onSettings,
    required this.onSubtitle,
    required this.onAudio,
    required this.onSpeed,
    required this.onPip,
    required this.onLock,
    required this.onRotate,
    required this.onFullscreen,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.showRemainingTime,
    required this.onToggleTime,
    required this.format,
  });

  final Color gold;
  final String title;
  final String? episodeLine;
  final bool isLive;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final double bufferedFraction;
  final bool canSeek;
  final String? sourceLabel;
  final bool hasEpisodes;
  final bool hasPreviousEpisode;
  final bool hasNextEpisode;
  final bool pipAvailable;
  final bool pipActive;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<double> onSeekTo;
  final VoidCallback onSettings;
  final VoidCallback onSubtitle;
  final VoidCallback onAudio;
  final VoidCallback onSpeed;
  final VoidCallback onPip;
  final VoidCallback onLock;
  final VoidCallback onRotate;
  final VoidCallback onFullscreen;
  final VoidCallback onPreviousEpisode;
  final VoidCallback onNextEpisode;
  final bool showRemainingTime;
  final VoidCallback onToggleTime;
  final String Function(Duration) format;

  @override
  Widget build(BuildContext context) {
    final positionFrac = canSeek && duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final subLine = [
      ?episodeLine,
      ?sourceLabel,
    ].where((line) => line.isNotEmpty).join(' · ');
    // Tap the time to toggle the remaining time ("-23:09"): remaining
    // = total - position, with a "-" prefix. LIVE stays LIVE.
    final timeText = isLive
        ? 'LIVE'
        : showRemainingTime
            ? '-${format(duration - position)}'
            : '${format(position)} / ${format(duration)}';
    return Column(
      children: [
        // Top bar.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: EdgeInsets.only(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 8,
            right: 8,
            bottom: 24,
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                    if (subLine.isNotEmpty)
                      Text(
                        subLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              if (isLive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.red,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              if (pipAvailable)
                IconButton(
                  onPressed: onPip,
                  icon: Icon(
                    Icons.picture_in_picture_alt,
                    color: pipActive ? gold : Colors.white,
                  ),
                  tooltip: 'Picture-in-picture',
                ),
            ],
          ),
        ),
        // Centre transport.
        Expanded(
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: canSeek ? onSeekBack : null,
                  icon: const Icon(Icons.replay_10, color: Colors.white),
                  iconSize: 30,
                ),
                const SizedBox(width: 16),
                Container(
                  decoration: BoxDecoration(
                    color: gold,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    onPressed: onPlayPause,
                    icon: Icon(
                      buffering
                          ? Icons.hourglass_top
                          : playing
                              ? Icons.pause
                              : Icons.play_arrow,
                      color: Colors.black,
                    ),
                    iconSize: 34,
                  ),
                ),
                const SizedBox(width: 16),
                IconButton(
                  onPressed: canSeek ? onSeekForward : null,
                  icon: const Icon(Icons.forward_10, color: Colors.white),
                  iconSize: 30,
                ),
              ],
            ),
          ),
        ),
        // Bottom bar: gold seek bar, then the icon toolbar.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: EdgeInsets.only(
            left: 12,
            right: 12,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 4,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 14,
                  ),
                  activeTrackColor: gold,
                  inactiveTrackColor: Colors.white24,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbColor: gold,
                ),
                child: Slider(
                  value: positionFrac,
                  secondaryTrackValue: bufferedFraction,
                  onChanged: canSeek ? onSeekTo : null,
                ),
              ),
              Row(
                children: [
                  // Left: previous / next episode + time.
                  if (hasEpisodes) ...[
                    IconButton(
                      onPressed: hasPreviousEpisode ? onPreviousEpisode : null,
                      // An explicitly coloured Icon overrides the
                      // disabled grey, so grey it by hand at the ends.
                      icon: Icon(
                        Icons.skip_previous,
                        color: hasPreviousEpisode
                            ? Colors.white
                            : Colors.white38,
                      ),
                      iconSize: 26,
                      // A real tap target (42x42), not just the icon.
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                      tooltip: 'Previous episode',
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      onPressed: hasNextEpisode ? onNextEpisode : null,
                      icon: Icon(
                        Icons.skip_next,
                        color:
                            hasNextEpisode ? Colors.white : Colors.white38,
                      ),
                      iconSize: 26,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                      tooltip: 'Next episode',
                    ),
                    const SizedBox(width: 10),
                  ],
                  // Tappable time: tap toggles elapsed/total <-> remaining.
                  // Padded, so the tap target is bigger than the text.
                  GestureDetector(
                    onTap: isLive ? null : onToggleTime,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 8,
                      ),
                      child: Text(
                        timeText,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Right: dark pill of gold icons.
                  Container(
                    decoration: BoxDecoration(
                      color: const Color(0xcc1a1a1a),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _pillIcon(
                          Icons.tune,
                          'Settings',
                          onSettings,
                          gold,
                        ),
                        _pillIcon(
                          Icons.closed_caption,
                          'Subtitles',
                          onSubtitle,
                          gold,
                        ),
                        _pillIcon(
                          Icons.volume_up,
                          'Audio',
                          onAudio,
                          gold,
                        ),
                        _pillIcon(
                          Icons.speed,
                          'Speed',
                          onSpeed,
                          gold,
                        ),
                        _pillIcon(Icons.lock_outline, 'Lock', onLock, gold),
                        if (pipAvailable)
                          _pillIcon(
                            Icons.picture_in_picture_alt,
                            'Picture-in-picture',
                            onPip,
                            gold,
                            active: pipActive,
                          ),
                        _pillIcon(
                          Icons.screen_rotation,
                          'Rotate',
                          onRotate,
                          gold,
                        ),
                        _pillIcon(
                          Icons.fullscreen,
                          'Fullscreen',
                          onFullscreen,
                          gold,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// One small gold icon in the toolbar pill.
  Widget _pillIcon(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
    Color gold, {
    bool active = false,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: active ? gold : Colors.white, size: 20),
      iconSize: 20,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(),
      tooltip: tooltip,
    );
  }
}

/// The pre-play source list: title, episode line, a "Source X of N" pill,
/// and the resolved sources with their probe status. Tapping a row plays
/// that source; backing out abandons the resolve and leaves the player.
/// Mirrors the VLC startup view, in Gold & Black.
class _PrePlaySourceView extends StatelessWidget {
  const _PrePlaySourceView({
    required this.title,
    required this.episodeLine,
    required this.candidates,
    required this.probes,
    required this.selectedIndex,
    required this.picked,
    required this.onPick,
    required this.onBack,
  });

  final String title;
  final String? episodeLine;
  final List<StreamResult> candidates;
  final Map<int, ProbeOutcome> probes;
  final int selectedIndex;
  final bool picked;
  final ValueChanged<int> onPick;
  final VoidCallback onBack;

  /// Identifies row [index], matching the VLC startup view's keys.
  static Key rowKey(int index) => ValueKey<String>('player-startup-row-$index');

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox.square(
                        dimension: 42,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xffd4af37),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                        ),
                      ),
                      if (episodeLine != null && episodeLine!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          episodeLine!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Text(
                        picked
                            ? 'Opening the source you picked…'
                            : 'Pick a source to play it — or wait for the best one.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 14,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 12),
                      DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            l10n.sourceAttempt(
                              selectedIndex + 1,
                              candidates.length,
                            ),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 260),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.35),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: ListView.builder(
                                padding: EdgeInsets.zero,
                                shrinkWrap: true,
                                itemCount: candidates.length,
                                itemBuilder: (context, index) {
                                  final stream = candidates[index];
                                  final outcome = probes[index];
                                  final reachability = sourceReachabilityOf(
                                    stream,
                                    outcome,
                                  );
                                  final isCurrent = index == selectedIndex;
                                  return DecoratedBox(
                                    key: rowKey(index),
                                    decoration: BoxDecoration(
                                      border: index == candidates.length - 1
                                          ? null
                                          : Border(
                                              bottom: BorderSide(
                                                color: Colors.white
                                                    .withValues(alpha: 0.06),
                                              ),
                                            ),
                                    ),
                                    child: Material(
                                      color: isCurrent
                                          ? Colors.white
                                              .withValues(alpha: 0.08)
                                          : Colors.transparent,
                                      child: InkWell(
                                        onTap: () => onPick(index),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 14,
                                            vertical: 12,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  stream.displaySource,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              if (picked && isCurrent)
                                                const SizedBox.square(
                                                  dimension: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    valueColor:
                                                        AlwaysStoppedAnimation<
                                                            Color>(
                                                      Colors.white,
                                                    ),
                                                  ),
                                                )
                                              else
                                                _reachabilityIcon(
                                                  l10n,
                                                  reachability,
                                                ),
                                              if (isCurrent) ...[
                                                const SizedBox(width: 10),
                                                const Icon(
                                                  Icons.check,
                                                  size: 18,
                                                  color: Color(0xffd4af37),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: 'Back',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The probe outcome's icon (or nothing when the source was not checked).
  static Widget _reachabilityIcon(
    AppLocalizations l10n,
    SourceReachability reachability,
  ) {
    final label = sourceReachabilityLabel(l10n, reachability);
    Widget icon(IconData data, Color colour) =>
        Icon(data, size: 16, color: colour, semanticLabel: label);
    return switch (reachability) {
      SourceReachability.checking => const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
          ),
        ),
      SourceReachability.reachable =>
        icon(Icons.check_rounded, Colors.green.shade300),
      SourceReachability.unseekable =>
        icon(Icons.first_page_rounded, Colors.amber.shade300),
      SourceReachability.unreachable =>
        icon(Icons.help_outline_rounded, Colors.amber.shade300),
      SourceReachability.notVideo => icon(Icons.web_rounded, Colors.red.shade300),
      SourceReachability.notChecked => const SizedBox(width: 16),
    };
  }
}
