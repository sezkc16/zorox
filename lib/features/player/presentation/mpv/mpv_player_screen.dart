/// Playback on the mpv engine (via media_kit) — ZoroX v18-fixes (2.9.17+3).
///
/// The v18-mpv player, restyled to the approved Claude-spec controls and
/// with the behaviour fixes the v19 line never landed:
///
///   * the Claude-spec overlay — gold #D4AF37, top bar (back, title,
///     episode · quality · source, cast), centre ±10 s around a 52 px gold
///     play button, bottom seekbar (elapsed, gold track, remaining with a
///     minus sign) and a button row (Lock, speed chip, Episodes pill on the
///     left; CC, audio, next episode on the right);
///   * the CC sheet — Subtitles (Off, languages, add a local file) and
///     Style (live preview, size, colour, background, edge, position
///     slider + the +5/+10/−5/−10 nudge buttons) tabs, persisted;
///   * the Episodes sheet — season dropdown, rows with thumbnail, progress,
///     gold "Now playing" border, dimmed watched;
///   * Continue Watching resume — a [PlaybackProgressRecorder] is fed the
///     same samples as the tracker and flushed on pause and teardown, so
///     leaving and coming back resumes where the viewer was;
///   * the source list before play — the startup view shows the resolving
///     sources (portrait, quality labels) and auto-plays the first working
///     one; tapping a row plays that source instead;
///   * landscape only once the video itself starts playing, so the source
///     list stays portrait;
///   * Back stops the player and returns to portrait;
///   * no centre "+10s"/"−10s" pop-up on a double-tap seek;
///   * a right-side long-press holds 2x until released;
///   * the seekbar drags a local preview and commits the seek on release.
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
/// What this build deliberately does NOT carry over (secondary — reported
/// honestly, not silently broken):
///   * PiP — NOT available on this build, and there is no PiP button. This
///     was investigated properly (2026-11-12) and is a real platform wall,
///     not a wiring oversight:
///       - iOS grants a PiP window only to an AVPlayerLayer (what
///         video_player / AVPlayer render through) or to an
///         AVSampleBufferDisplayLayer fed with CMSampleBuffers. mpv renders
///         through a Metal/Flutter texture — it has no AVPlayerLayer, so
///         the AVPlayerLayer route (pip_kit, orvexa_player's iOS backend)
///         does not apply; orvexa's iOS PiP works by switching the engine
///         to AVPlayer, which cannot play MKV.
///       - The AVSampleBufferDisplayLayer route needs a custom native
///         renderer that pumps decoded mpv frames as sample buffers, and
///         in the background iOS revokes GPU access, so frames must be
///         produced by software rendering — which is exactly the wall the
///         only community attempt hit: media_kit PR #206 (2023, draft,
///         unmerged) reports "sometimes the PIP displays a black screen,
///         especially when I switch to network videos" and HEVC
///         colorimetry problems in background software rendering, and its
///         maintainer refused to merge it for that reason.
///       - Building that renderer is a multi-day native subsystem that
///         cannot be verified without a device (no macOS/iPhone here).
///         Shipping it untested would risk the same black PiP the user
///         is trying to escape. So: no PiP button here. Audio DOES keep
///         playing in the background (the app declares the `audio`
///         background mode). PiP with video is the job of the libVLC line,
///         whose PiP pipeline is proven (v16 worked) — fix the v17 black
///         PiP there (v19), not on mpv.
///   * Side-car subtitle download (OpenSubtitles etc.) — only the subtitles
///     the plugin already listed on the stream, plus embedded tracks, plus
///     a local file the viewer adds.
///   * ClearKey DRM (drmKid/drmKey) — media_kit exposes no ClearKey path; a
///     DRM stream will fail to play and the failover moves to the next source.
///   * Subtitle delay — media_kit 1.2.6 exposes no subtitle-delay API (no
///     `setSubtitleDelay`, no property setter), so the CC sheet's delay
///     stepper is shown disabled with the reason, rather than a stepper
///     that moves a number without moving the captions.
///   * Skip Intro/Outro, HLS quality picker (mpv's ABR picks the rendition).
///     Ended shows Replay + Close.
///   * Volume is the engine's gain (`setVolume`), not the system volume the
///     VLC screen drives; brightness reuses the same platform channel as the
///     VLC screen ([PlatformPlayerBrightness]).
///   * There is no stall watchdog / auto-reconnect here on purpose: the v17
///     pause bug was exactly a watchdog reading a pause as a stall. A pause
///     is a pause; a genuinely dead source is handled by the startup failover
///     only.
///
/// The VLC screen stays in the repo untouched; the route points here for this
/// build, and flipping it back is a one-line change in `app_router.dart`.
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
import '../../../../l10n/generated/app_localizations.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/source_row_status.dart';
import '../../domain/stream_resolver.dart';
import '../player_brightness.dart';
import '../vlc/player_startup_view.dart';
import 'mpv_cc_sheet.dart';
import 'mpv_episodes_sheet.dart';
import 'mpv_subtitle_style.dart';

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

/// The gold accent, and the dark text/icon colour on gold.
const Color _kGold = Color(0xffd4af37);
const Color _kOnGold = Color(0xff1b1b1b);

enum _Stage { resolving, playing, failed }

/// The mpv player. Same constructor as VlcPlayerScreen so the route
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

  /// Sources that were opened and would not play, so the startup list can
  /// say so instead of leaving them looking untried.
  final Set<int> _failedStreams = <int>{};

  /// The episode (and its resolution token) this screen is playing. A
  /// switch from the Episodes sheet or Next Episode changes these in place
  /// and re-resolves, rather than pushing a new player route.
  late Episode? _currentEpisode;
  late String _currentVideoUrl;

  /// Whether the first resolve may use the route's preloaded streams. An
  /// episode switch resolves fresh (or from the new episode's own streams).
  bool _firstResolve = true;

  /// Where to resume, resolved once before the first open.
  Duration _resumePosition = Duration.zero;

  /// Progress tracking (history, scrobbling, watched) — the same tracker the
  /// VLC screen uses, fed from mpv's state stream.
  PlaybackTracker? _tracker;
  int _sessionToken = 0;

  /// Continue Watching — the VLC screen's recorder, fed the same samples as
  /// the tracker and flushed on pause and teardown. Without it the screen
  /// never wrote a position, so coming back always started at 0:00.
  PlaybackProgressRecorder? _recorder;
  ProgressSample? _sample;
  bool _recordedLivestream = false;

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

  /// True once playback has actually started for the open source (used by the
  /// startup watchdog, and by the first-play landscape switch).
  bool _startedPlaying = false;
  Timer? _watchdogTimer;

  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// Lock: all controls hidden, only an Unlock chip shown. Gestures are
  /// ignored while locked (pinch zoom is not a control and still works).
  bool _locked = false;

  /// Pinch zoom factor, applied with a Transform around the Video widget.
  double _zoom = 1.0;
  double _zoomBase = 1.0;

  /// Engine gain (0..100) and screen brightness (0..1) for the vertical
  /// swipe gestures. Volume here is the engine's, not the system volume.
  double _volume = 100;
  double _brightness = 1.0;
  String? _gestureIndicator;

  /// Speed (1.0 = normal).
  double _speed = 1.0;

  /// The speed a right-side long-press is holding 2x over, restored on
  /// release. Null when no long-press is holding.
  double? _speedBeforeLongPress;

  /// When the last double-tap landed, so a second tap held down does not
  /// also engage the long-press 2x.
  DateTime? _lastDoubleTapAt;

  /// Centre flash after a centre double-tap play-pause ("❚❚" / "▶"). The
  /// ±10 s flash is deliberately gone: a double-tap seek shows nothing.
  String? _flash;
  Timer? _flashTimer;

  /// Last position-update setState, so mpv's frequent ticks do not rebuild
  /// the whole screen at full rate.
  DateTime _lastPositionUi = DateTime.fromMicrosecondsSinceEpoch(0);

  bool _disposed = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  PlayerBrightness get _brightnessApi => PlatformPlayerBrightness();

  bool get _isSeries =>
      widget.item.contentType == MultimediaContentType.series ||
      widget.item.contentType == MultimediaContentType.anime;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _currentEpisode = widget.episode;
    _currentVideoUrl = widget.videoUrl;
    // No landscape here: the source list shown before play stays portrait,
    // and landscape is forced only when the video itself first starts
    // playing (see the playing listener).
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _flashTimer?.cancel();
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
    unawaited(_player.stop());
    unawaited(_player.dispose());
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
        _showControlsBriefly();
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
          _flushProgress();
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
    try {
      final resolved = await resolvePlayback(
        read: ref.read,
        item: widget.item,
        videoUrl: _currentVideoUrl,
        preloadedStreams: _firstResolve
            ? widget.preloadedStreams
            : _currentEpisode?.streams,
      );
      _firstResolve = false;
      final resume = await resolveResumePoint(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
      );
      if (_disposed) return;
      _streams = resolved.streams;
      _streamIndex = resolved.index;
      _resumePosition = resume?.position ?? Duration.zero;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      // The stage stays resolving: the startup view now lists the sources,
      // and it only gives way to the video when the first one actually
      // plays. The first open is automatic — the list is the control, not
      // a gate.
      if (mounted) setState(() {});
      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _currentVideoUrl,
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

  Future<void> _openStream(int index, {Duration? start}) async {
    if (_disposed || _streams.isEmpty) return;
    _streamIndex = index;
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _recordedLivestream = false;
    _sample = null;
    final stream = _streams[index];
    _sessionToken++;
    _tracker = PlaybackTracker(
      read: ref.read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
      token: _sessionToken,
    );
    // One recorder per open, stamped with this session's token, so a sample
    // from a previous source can never be written under this one.
    _recorder = PlaybackProgressRecorder(
      read: ref.read,
      item: widget.item,
      episode: _currentEpisode,
      videoUrl: _currentVideoUrl,
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
    _failedStreams.add(_streamIndex);
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

  /// A row picked on the startup list, before anything is playing: open
  /// that source instead of the one the auto-open chose. The list stays up
  /// until the picked source plays, so a pick that fails falls over to the
  /// next one the same way.
  void _pickFromStartup(int index) {
    if (_disposed || index < 0 || index >= _streams.length) return;
    if (index == _streamIndex && !_startedPlaying) return;
    unawaited(_openStream(index, start: _position));
  }

  /// Switches to another episode in place: the current episode's progress
  /// is flushed, the engine is stopped, and the new episode resolves and
  /// opens through the same startup list. A saved position on the new
  /// episode resumes from there.
  Future<void> _switchEpisode(Episode next) async {
    if (_disposed) return;
    _flushProgress();
    try {
      _tracker?.finish();
    } catch (_) {}
    await _player.stop();
    if (_disposed) return;
    _currentEpisode = next;
    _currentVideoUrl = next.url;
    _streams = const [];
    _streamIndex = 0;
    _failedStreams.clear();
    _startedPlaying = false;
    _subtitleAppliedFor = -1;
    _position = Duration.zero;
    _duration = Duration.zero;
    _buffered = Duration.zero;
    _completed = false;
    _resumePosition = Duration.zero;
    _sample = null;
    _recorder = null;
    setState(() => _stage = _Stage.resolving);
    await _resolveAndOpen();
  }

  /// Picks a subtitle without being asked: the plugin's own subtitle file
  /// first (usually the right language), else the first embedded track.
  /// Runs once per source, when mpv reports its tracks.
  void _applySubtitleAutoSelect() {
    if (_disposed || _subtitleAppliedFor == _streamIndex) return;
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
    // No centre flash: a double-tap seek seeks, and shows nothing.
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

  // -- sheets ---------------------------------------------------------------

  /// The CC sheet: Subtitles (track pick, add a local file) and Style
  /// (live restyle, persisted). A track pick is applied; a style change
  /// needs nothing — it already restyled the caption live.
  Future<void> _openCcSheet() async {
    if (!mounted) return;
    final embedded = _player.state.tracks.subtitle;
    final external = _selected?.subtitles ?? const [];
    final choice = await showMpvCcSheet(
      context: context,
      embedded: embedded,
      external: external,
      current: _player.state.track.subtitle,
    );
    if (choice != null) {
      await _player.setSubtitleTrack(choice);
      if (mounted) setState(() {});
    }
    _showControls();
  }

  Future<void> _pickAudio() async {
    final tracks = _player.state.tracks.audio;
    if (!mounted || tracks.isEmpty) return;
    final choice = await showModalBottomSheet<AudioTrack?>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        final current = _player.state.track.audio;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final track in tracks)
                ListTile(
                  title: Text(
                    track.title ?? 'Audio ${track.id}',
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: track.language == null
                      ? null
                      : Text(
                          track.language!,
                          style: const TextStyle(color: Colors.white54),
                        ),
                  trailing: current.id == track.id
                      ? const Icon(Icons.check, color: _kGold)
                      : null,
                  onTap: () => Navigator.pop(context, track),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null) {
      await _player.setAudioTrack(choice);
      if (mounted) setState(() {});
    }
    _showControls();
  }

  Future<void> _pickSpeed() async {
    if (!mounted) return;
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final choice = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final speed in speeds)
                ListTile(
                  title: Text(
                    '${speed}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: speed == _speed
                      ? const Icon(Icons.check, color: _kGold)
                      : null,
                  onTap: () => Navigator.pop(context, speed),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null) await _setSpeed(choice);
    _showControls();
  }

  /// The Episodes sheet: a season dropdown and the season's rows. A pick
  /// switches episode in place.
  Future<void> _openEpisodesSheet() async {
    if (!mounted) return;
    final picked = await showMpvEpisodesSheet(
      context: context,
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    );
    if (picked != null && picked.url != _currentEpisode?.url) {
      await _switchEpisode(picked);
    }
    _showControls();
  }

  /// Next Episode: the episode after this one in the dub-filtered list, or
  /// nothing when this is the last. Hidden for films.
  void _onNextEpisode() {
    final next = nextEpisodeFor(
      item: widget.item,
      current: _currentEpisode,
      videoUrl: _currentVideoUrl,
    ).next;
    if (next == null) return;
    unawaited(_switchEpisode(next));
  }

  /// Cast is not a feature ZoroX has (Cast to TV was skipped), so the icon
  /// says so rather than pretending.
  void _onCast() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Casting isn't available in ZoroX yet"),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _lock() {
    _locked = true;
    _hideTimer?.cancel();
    if (mounted) setState(() {});
  }

  void _unlock() {
    _locked = false;
    _showControls();
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
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  void _flashPlayPause() {
    _flash = _playing ? '❚❚' : '▶';
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 700), () {
      if (_disposed) return;
      setState(() => _flash = null);
    });
    setState(() {});
  }

  void _onDoubleTapDown(TapDownDetails details) {
    if (_locked) return;
    _lastDoubleTapAt = DateTime.now();
    final width = MediaQuery.sizeOf(context).width;
    final x = details.globalPosition.dx;
    if (x < width / 3) {
      unawaited(_seekBy(-_kSeekStep));
    } else if (x > width * 2 / 3) {
      unawaited(_seekBy(_kSeekStep));
    } else {
      unawaited(_togglePlayPause());
      _flashPlayPause();
    }
  }

  /// A right-side long-press holds 2x while held, and restores the speed
  /// on release. Gated to the right third (the forward-seek zone) and
  /// ignored when it is really the second tap of a double-tap held down,
  /// so the two never fight.
  void _onLongPressStart(LongPressStartDetails details) {
    if (_disposed || _locked) return;
    final width = MediaQuery.sizeOf(context).width;
    if (details.globalPosition.dx <= width * 2 / 3) return;
    final lastDoubleTap = _lastDoubleTapAt;
    if (lastDoubleTap != null &&
        DateTime.now().difference(lastDoubleTap) <
            const Duration(milliseconds: 800)) {
      return;
    }
    if (_speed == 2.0) return;
    _speedBeforeLongPress = _speed;
    _gestureIndicator = '2x';
    unawaited(_player.setRate(2.0));
    setState(() {});
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _endLongPressSpeed();
  }

  void _onLongPressCancel() {
    _endLongPressSpeed();
  }

  void _endLongPressSpeed() {
    final previous = _speedBeforeLongPress;
    if (previous == null) return;
    _speedBeforeLongPress = null;
    if (_gestureIndicator == '2x') _gestureIndicator = null;
    unawaited(_setSpeed(previous));
  }

  void _onVerticalDragUpdate(DragUpdateDetails details, double width) {
    if (_locked) return;
    final x = details.globalPosition.dx;
    final delta = -details.delta.dy / 200;
    if (x < width / 2) {
      // Left half: brightness.
      _brightness = (_brightness + delta).clamp(0.05, 1.0);
      _brightnessApi.set(_brightness);
      _gestureIndicator =
          'Brightness ${(_brightness * 100).round()}%';
    } else {
      // Right half: engine volume.
      _volume = (_volume + delta * 100).clamp(0.0, 100.0);
      unawaited(_player.setVolume(_volume));
      _gestureIndicator = 'Volume ${_volume.round()}%';
    }
    setState(() {});
  }

  void _onVerticalDragEnd(_) {
    _gestureIndicator = null;
    if (mounted) setState(() {});
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

  /// "Show name · S1 E3" for a series, the bare title for a film.
  String get _playerTitle {
    final episode = _currentEpisode;
    if (_isSeries && episode != null) {
      return '${widget.item.title} · S${episode.season} E${episode.episode}';
    }
    return widget.item.title;
  }

  /// Episode name · quality · source, single line, ellipsis. The file size
  /// the spec's line wants is not known on this engine (no probe runs), so
  /// the source takes its place.
  String get _playerSubtitleLine {
    final quality = _selected?.quality;
    final qualityLabel = quality != null && quality > 0
        ? '${quality}p'
        : 'Auto';
    final source = _selected?.displaySource;
    final episode = _currentEpisode;
    if (_isSeries && episode != null) {
      return source == null
          ? '${episode.name} · $qualityLabel'
          : '${episode.name} · $qualityLabel · $source';
    }
    return source == null ? qualityLabel : '$qualityLabel · $source';
  }

  /// "S1 E3 · Episode name", for the startup list.
  String? get _episodeLine {
    final episode = _currentEpisode;
    if (!_isSeries || episode == null) return null;
    return 'S${episode.season} E${episode.episode} · ${episode.name}';
  }

  List<StartupRow> get _startupRows {
    return <StartupRow>[
      for (var i = 0; i < _streams.length; i++)
        StartupRow(
          label: _startupRowLabel(_streams[i]),
          reachability: SourceReachability.notChecked,
          playState: _failedStreams.contains(i)
              ? SourcePlayState.failed
              : i == _streamIndex
                  ? (_startedPlaying
                        ? SourcePlayState.playing
                        : SourcePlayState.opening)
                  : SourcePlayState.untried,
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The saved subtitle style, watched so a Style-tab change restyles the
    // caption live. An unloaded provider reads as a fresh install.
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final position = _position;
    final duration = _duration;
    final bufferedFrac = _canSeek
        ? (_buffered.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final nextEpisode = _isSeries
        ? nextEpisodeFor(
            item: widget.item,
            current: _currentEpisode,
            videoUrl: _currentVideoUrl,
          ).next
        : null;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video + gestures.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: _onDoubleTapDown,
            onLongPressStart: _onLongPressStart,
            onLongPressEnd: _onLongPressEnd,
            onLongPressCancel: _onLongPressCancel,
            onScaleStart: (_) => _zoomBase = _zoom,
            onScaleUpdate: (details) {
              setState(() {
                _zoom = (_zoomBase * details.scale).clamp(_kMinZoom, _kMaxZoom);
              });
            },
            onVerticalDragUpdate: (details) => _onVerticalDragUpdate(
              details,
              MediaQuery.sizeOf(context).width,
            ),
            onVerticalDragEnd: _onVerticalDragEnd,
            child: Center(
              child: Transform.scale(
                scale: _zoom,
                child: Video(
                  controller: _videoController,
                  fit: BoxFit.contain,
                  fill: Colors.black,
                  // Custom controls below; media_kit's own are hidden.
                  controls: (_) => const SizedBox.shrink(),
                  wakelock: true,
                  pauseUponEnteringBackgroundMode: true,
                  subtitleViewConfiguration:
                      mpvSubtitleViewConfiguration(
                        settings,
                        screenHeight: MediaQuery.sizeOf(context).height,
                        controlsVisible: _controlsVisible,
                      ),
                ),
              ),
            ),
          ),

          // Resolving: the source list. It stays up until the first source
          // actually plays — the list is the control, and the first open is
          // automatic.
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
              currentIndex: _streams.isEmpty ? null : _streamIndex,
              onPick: _pickFromStartup,
              onBack: _goBack,
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

          // Buffering spinner (playing but waiting on data).
          if (_stage == _Stage.playing && _playing && _buffering)
            const Center(
              child: CircularProgressIndicator(color: _kGold),
            ),

          // Centre flash (play-pause only — a seek shows nothing).
          if (_flash != null)
            Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _flash!,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),

          // Volume / brightness / 2x indicator.
          if (_gestureIndicator != null)
            Align(
              alignment: Alignment.center,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _gestureIndicator!,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
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
                          onPressed: _goBack,
                          child: Text(l10n.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Locked: every control hidden, only the Unlock chip, bottom
          // centre. Unlock restores the controls.
          if (_stage == _Stage.playing && _locked && !_completed)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: Center(
                child: GestureDetector(
                  onTap: _unlock,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.lock_open,
                          color: Colors.white,
                          size: 16,
                        ),
                        SizedBox(width: 6),
                        Text(
                          'Unlock',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Controls overlay.
          if (_stage == _Stage.playing &&
              _controlsVisible &&
              !_completed &&
              !_locked)
            _ControlsOverlay(
              title: _playerTitle,
              subtitleLine: _playerSubtitleLine,
              isLive: _isLive,
              isSeries: _isSeries,
              playing: _playing,
              buffering: _buffering,
              position: position,
              duration: duration,
              bufferedFraction: bufferedFrac,
              canSeek: _canSeek,
              speed: _speed,
              hasNextEpisode: nextEpisode != null,
              onBack: _goBack,
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
              onCast: _onCast,
              onLock: _lock,
              onSpeed: _pickSpeed,
              onEpisodes: _openEpisodesSheet,
              onSubtitle: _openCcSheet,
              onAudio: _pickAudio,
              onNextEpisode: _onNextEpisode,
              format: _format,
            ),
        ],
      ),
    );
  }
}

/// The Claude-spec controls overlay: a black 38% scrim over the video, a
/// top bar (back, title + episode · quality · source, cast), centre ±10 s
/// around a 52 px gold play button, and a bottom bar — seekbar (elapsed,
/// gold track, remaining with a minus sign), then a button row: Lock, speed
/// chip, Episodes pill on the left; CC, audio, next episode on the right.
///
/// The seekbar drags a local preview and commits the seek on release, as
/// the VLC scrubber does — seeking the engine on every move flooded mpv
/// with seeks and the bar looked dead.
class _ControlsOverlay extends StatefulWidget {
  const _ControlsOverlay({
    required this.title,
    required this.subtitleLine,
    required this.isLive,
    required this.isSeries,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedFraction,
    required this.canSeek,
    required this.speed,
    required this.hasNextEpisode,
    required this.onBack,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onCast,
    required this.onLock,
    required this.onSpeed,
    required this.onEpisodes,
    required this.onSubtitle,
    required this.onAudio,
    required this.onNextEpisode,
    required this.format,
  });

  final String title;
  final String subtitleLine;
  final bool isLive;
  final bool isSeries;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final double bufferedFraction;
  final bool canSeek;
  final double speed;
  final bool hasNextEpisode;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<double> onSeekTo;
  final VoidCallback onCast;
  final VoidCallback onLock;
  final VoidCallback onSpeed;
  final VoidCallback onEpisodes;
  final VoidCallback onSubtitle;
  final VoidCallback onAudio;
  final VoidCallback onNextEpisode;
  final String Function(Duration) format;

  @override
  State<_ControlsOverlay> createState() => _ControlsOverlayState();
}

class _ControlsOverlayState extends State<_ControlsOverlay> {
  /// The drag preview: a fraction the finger is holding, or null when no
  /// drag is in progress. Only the display follows it; the engine is
  /// sought once, on release.
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    final positionFrac =
        widget.canSeek && widget.duration > Duration.zero
        ? (widget.position.inMilliseconds /
                  widget.duration.inMilliseconds)
              .clamp(0.0, 1.0)
        : 0.0;
    final displayFrac = _dragFraction ?? positionFrac;
    final displayPosition = Duration(
      milliseconds:
          (displayFrac * widget.duration.inMilliseconds).round(),
    );
    final remaining = widget.duration - displayPosition;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Scrim: black at 38% over the whole video.
        const ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.38)),

        // Top bar.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 12,
              left: 12,
              right: 12,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                IconButton(
                  onPressed: widget.onBack,
                  icon: const Icon(
                    Icons.arrow_back,
                    color: Colors.white,
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.subtitleLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (widget.isLive)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
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
                IconButton(
                  onPressed: widget.onCast,
                  icon: const Icon(
                    Icons.cast,
                    color: Colors.white,
                    size: 20,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 28,
                    minHeight: 28,
                  ),
                  tooltip: 'Cast',
                ),
              ],
            ),
          ),
        ),

        // Centre controls, a bit above the middle.
        Align(
          alignment: const Alignment(0, -0.18),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                onPressed: widget.canSeek ? widget.onSeekBack : null,
                icon: const Icon(
                  Icons.replay_10,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 34),
              GestureDetector(
                onTap: widget.onPlayPause,
                child: Container(
                  width: 52,
                  height: 52,
                  decoration: const BoxDecoration(
                    color: _kGold,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    widget.buffering
                        ? Icons.hourglass_top
                        : widget.playing
                            ? Icons.pause
                            : Icons.play_arrow,
                    color: _kOnGold,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 34),
              IconButton(
                onPressed: widget.canSeek ? widget.onSeekForward : null,
                icon: const Icon(
                  Icons.forward_10,
                  color: Colors.white,
                  size: 30,
                ),
              ),
            ],
          ),
        ),

        // Bottom bar.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Padding(
            padding: EdgeInsets.only(
              left: 12,
              right: 12,
              bottom: MediaQuery.paddingOf(context).bottom + 8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Row 1: seekbar.
                Row(
                  children: [
                    SizedBox(
                      width: 38,
                      child: Text(
                        widget.format(displayPosition),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: _kGold,
                          inactiveTrackColor: Colors.white.withValues(
                            alpha: 0.3,
                          ),
                          secondaryActiveTrackColor: Colors.white38,
                          thumbColor: _kGold,
                        ),
                        child: Slider(
                          value: displayFrac,
                          secondaryTrackValue: widget.bufferedFraction,
                          onChanged: widget.canSeek
                              ? (value) =>
                                    setState(() => _dragFraction = value)
                              : null,
                          onChangeEnd: widget.canSeek
                              ? (value) {
                                  setState(() => _dragFraction = null);
                                  widget.onSeekTo(value);
                                }
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.isLive
                          ? 'LIVE'
                          : '-${widget.format(remaining)}',
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Row 2: buttons, space between.
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Left group: Lock, speed chip, Episodes pill.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _circleButton(
                          icon: Icons.lock,
                          onPressed: widget.onLock,
                          tooltip: 'Lock',
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: widget.onSpeed,
                          child: Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Text(
                              '${widget.speed}x',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                        if (widget.isSeries) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: widget.onEpisodes,
                            child: Container(
                              height: 28,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _kGold,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.list,
                                    color: _kOnGold,
                                    size: 16,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Episodes',
                                    style: TextStyle(
                                      color: _kOnGold,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // Right group: CC, audio, next episode.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _circleButton(
                          icon: Icons.closed_caption,
                          onPressed: widget.onSubtitle,
                          tooltip: 'Subtitles',
                        ),
                        const SizedBox(width: 6),
                        _circleButton(
                          icon: Icons.audiotrack,
                          onPressed: widget.onAudio,
                          tooltip: 'Audio',
                        ),
                        if (widget.hasNextEpisode) ...[
                          const SizedBox(width: 6),
                          _circleButton(
                            icon: Icons.skip_next,
                            onPressed: widget.onNextEpisode,
                            tooltip: 'Next episode',
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// A 28 px circle on a white 16% background, with a 16 px icon.
  Widget _circleButton({
    required IconData icon,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onPressed,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: Colors.white, size: 16),
        ),
      ),
    );
  }
}
