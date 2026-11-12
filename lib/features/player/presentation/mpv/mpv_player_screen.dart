/// Playback on the mpv engine (via media_kit) — v18 test build.
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
///     the plugin already listed on the stream, plus embedded tracks.
///   * ClearKey DRM (drmKid/drmKey) — media_kit exposes no ClearKey path; a
///     DRM stream will fail to play and the failover moves to the next source.
///   * Skip Intro/Outro, HLS quality picker (mpv's ABR picks the rendition),
///     auto-advance to the next episode. Ended shows Replay + Close.
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
import '../../../../l10n/generated/app_localizations.dart';
import '../../domain/playback_progress.dart';
import '../../domain/playback_tracker.dart';
import '../../domain/stream_resolver.dart';
import '../player_brightness.dart';

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

/// Subtitle bottom padding: low at the picture bottom, as in v14 — and
/// lifted above the controls bar while the bars are up.
const double _kSubtitlePaddingHidden = 40;
const double _kSubtitlePaddingControls = 116;

enum _Stage { resolving, playing, failed }

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
  String? _gestureIndicator;

  /// Speed (1.0 = normal).
  double _speed = 1.0;

  /// Centre flash after a double-tap seek / play-pause ("+10s", "❚❚").
  String? _flash;
  Timer? _flashTimer;

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
    // Landscape on a portrait handset, as the VLC screen does; restored on
    // the way out.
    _forceLandscapeIfPortrait();
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
    await _resolveAndOpen();
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
    try {
      final resolved = await resolvePlayback(
        read: ref.read,
        item: widget.item,
        videoUrl: widget.videoUrl,
        preloadedStreams: widget.preloadedStreams,
      );
      final resume = await resolveResumePoint(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
      );
      if (_disposed) return;
      _streams = resolved.streams;
      _streamIndex = resolved.index;
      _resumePosition = resume?.position ?? Duration.zero;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      setState(() => _stage = _Stage.playing);
      _tracker = PlaybackTracker(
        read: ref.read,
        item: widget.item,
        episode: widget.episode,
        videoUrl: widget.videoUrl,
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
    final stream = _streams[index];
    _sessionToken++;
    _tracker = PlaybackTracker(
      read: ref.read,
      item: widget.item,
      episode: widget.episode,
      videoUrl: widget.videoUrl,
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

  Future<void> _pickSubtitle() async {
    final embedded = _player.state.tracks.subtitle;
    final external = _selected?.subtitles ?? const [];
    if (!mounted) return;
    final choice = await showModalBottomSheet<SubtitleTrack?>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        final current = _player.state.track.subtitle;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text(
                  'Off',
                  style: TextStyle(color: Colors.white),
                ),
                trailing: current.id == 'no'
                    ? const Icon(Icons.check, color: Color(0xffd4af37))
                    : null,
                onTap: () => Navigator.pop(context, SubtitleTrack.no()),
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
                  onTap: () => Navigator.pop(
                    context,
                    SubtitleTrack.uri(sub.url, title: sub.label),
                  ),
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
                  onTap: () => Navigator.pop(context, sub),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null) {
      await _player.setSubtitleTrack(choice);
      if (mounted) setState(() {});
    }
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
                      ? const Icon(Icons.check, color: Color(0xffd4af37))
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
  }

  Future<void> _pickSource() async {
    if (!mounted || _streams.length < 2) return;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < _streams.length; i++)
                ListTile(
                  title: Text(
                    _streams[i].displaySource,
                    style: const TextStyle(color: Colors.white),
                  ),
                  trailing: i == _streamIndex
                      ? const Icon(Icons.check, color: Color(0xffd4af37))
                      : null,
                  onTap: () => Navigator.pop(context, i),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null && choice != _streamIndex) {
      await _openStream(choice, start: _position);
    }
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
                      ? const Icon(Icons.check, color: Color(0xffd4af37))
                      : null,
                  onTap: () => Navigator.pop(context, speed),
                ),
            ],
          ),
        );
      },
    );
    if (choice != null) await _setSpeed(choice);
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
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  void _flashSeek(Duration delta) {
    final seconds = delta.inSeconds;
    _flash = seconds > 0 ? '+${seconds}s' : '${seconds}s';
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 900), () {
      if (_disposed) return;
      setState(() => _flash = null);
    });
    setState(() {});
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

  void _onVerticalDragUpdate(DragUpdateDetails details, double width) {
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const gold = Color(0xffd4af37);
    final position = _position;
    final duration = _duration;
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
            onDoubleTapDown: _onDoubleTapDown,
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
                  subtitleViewConfiguration: SubtitleViewConfiguration(
                    style: const TextStyle(
                      height: 1.4,
                      fontSize: _kSubtitleFontSize,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                      backgroundColor: Color(0xaa000000),
                    ),
                    textAlign: TextAlign.center,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      _controlsVisible
                          ? _kSubtitlePaddingControls
                          : _kSubtitlePaddingHidden,
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Resolving / failed states.
          if (_stage == _Stage.resolving)
            Container(
              color: Colors.black,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xffd4af37)),
                    const SizedBox(height: 16),
                    Text(
                      l10n.loading,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
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

          // Centre flash (±10 s / play-pause).
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

          // Volume / brightness indicator.
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
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(l10n.close),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Controls overlay.
          if (_stage == _Stage.playing &&
              _controlsVisible &&
              !_completed)
            _ControlsOverlay(
              gold: gold,
              title: widget.item.title,
              isLive: _isLive,
              playing: _playing,
              buffering: _buffering,
              position: position,
              duration: duration,
              bufferedFraction: bufferedFrac,
              canSeek: _canSeek,
              speed: _speed,
              sourceLabel: _selected?.displaySource,
              subtitleLabel: _player.state.track.subtitle.title,
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
              onSubtitle: _pickSubtitle,
              onAudio: _pickAudio,
              onSource: _streams.length > 1 ? _pickSource : null,
              onSpeed: _pickSpeed,
              format: _format,
            ),
        ],
      ),
    );
  }
}

/// Top bar + bottom bar, Gold & Black like the rest of the app.
class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.gold,
    required this.title,
    required this.isLive,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedFraction,
    required this.canSeek,
    required this.speed,
    required this.sourceLabel,
    required this.subtitleLabel,
    required this.onBack,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onSubtitle,
    required this.onAudio,
    required this.onSource,
    required this.onSpeed,
    required this.format,
  });

  final Color gold;
  final String title;
  final bool isLive;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final double bufferedFraction;
  final bool canSeek;
  final double speed;
  final String? sourceLabel;
  final String? subtitleLabel;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<double> onSeekTo;
  final VoidCallback onSubtitle;
  final VoidCallback onAudio;
  final VoidCallback? onSource;
  final VoidCallback onSpeed;
  final String Function(Duration) format;

  @override
  Widget build(BuildContext context) {
    final positionFrac = canSeek && duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
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
                    if (sourceLabel != null)
                      Text(
                        sourceLabel!,
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
              IconButton(
                onPressed: onSubtitle,
                icon: Icon(
                  Icons.closed_caption,
                  color: subtitleLabel == null ? Colors.white54 : gold,
                ),
                tooltip: 'Subtitles',
              ),
              IconButton(
                onPressed: onAudio,
                icon: const Icon(Icons.audiotrack, color: Colors.white),
                tooltip: 'Audio',
              ),
              if (onSource != null)
                IconButton(
                  onPressed: onSource,
                  icon: const Icon(Icons.swap_horiz, color: Colors.white),
                  tooltip: 'Source',
                ),
              TextButton(
                onPressed: onSpeed,
                child: Text(
                  '${speed}x',
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        // Bottom bar.
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
              Row(
                children: [
                  Text(
                    format(position),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Expanded(
                    child: SliderTheme(
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
                  ),
                  Text(
                    isLive ? 'LIVE' : format(duration),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
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
            ],
          ),
        ),
      ],
    );
  }
}
