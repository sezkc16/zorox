/// Playback on the mpv engine (via media_kit) — v18 + Nuvio (2.9.17+2).
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
/// Nuvio player bar (white on dark, navigation left): the top bar holds
/// Lock + Back; the centre holds the persistent ±10 s + play/pause; the
/// bottom holds the title + year above a full-width thin progress bar,
/// with CC, Audio, Download, Speed, Next episode and More ">" on the
/// bottom-left and the time on the bottom-right. On top of v18-mpv it
/// adds: right-side hold = temporary 2x, episode resume (the recorder
/// writes the watch position, so reopening resumes), the pre-play
/// source list in portrait (landscape only once the video plays), no
/// centre "+10s" pop-up on double-tap seek, the Subtitle Style panel
/// (size, colour, background, outline, position), episode posters in
/// the episode picker, and a one-tap Next Episode button.
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
///         background mode). The v19 line built exactly that SW renderer
///         and it failed on the phone too ("fix nahi huwa", 2026-11-13),
///         so the v19 line was abandoned and this build keeps no PiP
///         button rather than one that black-screens.
///   * Side-car subtitle download (OpenSubtitles etc.) — only the subtitles
///     the plugin already listed on the stream, plus embedded tracks.
///   * ClearKey DRM (drmKid/drmKey) — media_kit exposes no ClearKey path; a
///     DRM stream will fail to play and the failover moves to the next source.
///   * Skip Intro/Outro, HLS quality picker (mpv's ABR picks the rendition),
///     auto-advance to the next episode (manual next IS here: the Next
///     Episode button and the Episodes sheet open the next episode in
///     place). Ended shows Replay + Close.
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
import '../../../details/presentation/download_launcher.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/episode_navigator.dart';
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

/// How long after a double-tap seek the 2x hold is suppressed. A
/// double-tap is two taps ~100-300 ms apart, and the hold timer is
/// 550 ms — so 800 ms covers the whole double-tap sequence plus the
/// timer that any of its tap-downs may already have started.
const Duration _kDoubleTapHoldSuppress = Duration(milliseconds: 800);

/// How long the pre-play source list waits for the viewer to pick a row
/// before it opens the best source on its own ("or wait for the best one").
const Duration _kSourceAutoPick = Duration(seconds: 6);

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

enum _Stage { resolving, sourceList, playing, failed }

/// The aspect-ratio mode. Fit is the default (the whole picture, bars
/// where the video and the screen disagree). Fill crops the picture to
/// the screen (no bars). 16:9 and 4:3 force that display aspect through
/// mpv (the picture is stretched to it, as in VLC's aspect control).
enum _AspectMode { fit, fill, ratio16x9, ratio4x3 }

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

  /// Aspect-ratio mode (Fit by default). Fill is a Flutter-side crop
  /// (BoxFit.cover); 16:9 / 4:3 are mpv-side via video-aspect-override.
  _AspectMode _aspectMode = _AspectMode.fit;

  /// Screen lock: when on, gestures and the bars are frozen except the
  /// unlock control.
  bool _locked = false;

  /// Whether the orientation is free (Rotate) or pinned to landscape.
  bool _orientationFree = false;

  /// Tap-and-hold 2x speed (right side): a press held ~550 ms plays at
  /// 2x until the finger lifts, then restores [_speed]. Uses the tap
  /// recognizer + a timer, not a long-press recognizer, so it cannot
  /// steal the arena from a double-tap seek or a vertical swipe.
  Timer? _holdSpeedTimer;
  bool _holdSpeedActive = false;
  double _speedBeforeHold = 1.0;
  // A hold that just ended must not also toggle the controls (the tap
  // up after a long hold still counts as a tap).
  bool _justEndedHoldSpeed = false;

  /// When the last double-tap seek fired. A double-tap is two quick taps
  /// on the same half, and each tap-down also starts the 2x hold timer —
  /// so a double-tap seek could engage 2x on its own when the second tap
  /// lingered. The hold timer is suppressed while a double-tap seek is
  /// fresh: a seek is a seek, never a hold.
  DateTime _lastDoubleTapSeekAt = DateTime.fromMicrosecondsSinceEpoch(0);

  /// Local watch-position writer. v18-mpv never had one (only the
  /// scrobble tracker), so reopening an episode always started at 0:00.
  /// The recorder writes the position under the same per-episode key the
  /// resume lookup reads, so reopening resumes at the saved position.
  PlaybackProgressRecorder? _recorder;

  /// Auto-pick timer for the pre-play source list: opens the best source
  /// if the viewer does not tap a row in time.
  Timer? _sourceAutoPickTimer;

  /// Landscape has been forced once the video itself started playing.
  bool _landscapeForced = false;

  /// The episode currently open. Starts as [widget]'s episode; the Next
  /// Episode button and the episode picker swap it in place, so the
  /// player, its cache and the orientation survive the switch.
  Episode? _currentEpisode;

  /// The current episode's stream URL (the resolve token). Starts as
  /// [widget]'s videoUrl; swapped with the episode.
  late String _videoUrl;

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
    _currentEpisode = widget.episode;
    _videoUrl = widget.videoUrl;
    WidgetsBinding.instance.addObserver(this);
    // Do NOT force landscape here: the resolving / source-selection
    // screen is a portrait page and must stay upright while the viewer
    // is choosing a link. Landscape is forced only once the video
    // itself starts playing (see the playing-stream listener).
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]),
    );
    _init();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _flashTimer?.cancel();
    _watchdogTimer?.cancel();
    _holdSpeedTimer?.cancel();
    _sourceAutoPickTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    // Last chance to write the position: leaving the player is what
    // Continue Watching and the episode resume read.
    _flushProgress();
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

  /// Force landscape once, the first time the video itself plays.
  /// The source-selection / loading screen stays portrait until then.
  void _forceLandscapeOnce() {
    if (_landscapeForced || _orientationFree) return;
    _landscapeForced = true;
    _forceLandscapeIfPortrait();
  }

  void _restoreOrientation() {
    // Back to portrait (upright), not "all orientations" — merely
    // lifting the pin leaves the app stuck in landscape.
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]),
    );
  }

  /// Last-chance write of the watch position through the recorder, so
  /// reopening this episode resumes where it was left.
  void _flushProgress() {
    final recorder = _recorder;
    if (recorder == null) return;
    if (_duration <= Duration.zero || _position <= Duration.zero) return;
    recorder.record(
      ProgressSample(
        position: _position,
        duration: _duration,
        token: _sessionToken,
      ),
      lastStreamUrl: _selected?.url,
      force: true,
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
          // First real playback: now — and only now — the screen may go
          // landscape. The resolving / source list stayed portrait.
          _forceLandscapeOnce();
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
        // Feed the tracker and the local position writer, as the VLC
        // screen does: only samples taken while playing count toward
        // history / watched.
        if (_playing && _duration > Duration.zero) {
          final sample = ProgressSample(
            position: position,
            duration: _duration,
            token: _sessionToken,
          );
          _tracker?.onPlaying(sample);
          _recorder?.record(sample, lastStreamUrl: _selected?.url);
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
        videoUrl: _videoUrl,
        preloadedStreams: widget.preloadedStreams,
      );
      final resume = await resolveResumePoint(
        read: ref.read,
        item: widget.item,
        episode: _currentEpisode,
        videoUrl: _videoUrl,
      );
      if (_disposed) return;
      _streams = resolved.streams;
      _streamIndex = resolved.index;
      _resumePosition = resume?.position ?? Duration.zero;
      // Only a real livestream is LIVE; an HLS VOD reports its duration once
      // mpv reads the playlist, and _canSeek stays off until then.
      _isLive = widget.item.contentType == MultimediaContentType.livestream;
      if (_streams.length <= 1) {
        // Nothing to choose: play the only source straight away.
        setState(() => _stage = _Stage.playing);
        await _openStream(_streamIndex, start: _resumePosition);
        return;
      }
      // More than one source: let the viewer pick, in portrait. The
      // list stays upright (no landscape force) until the video itself
      // starts playing. If nobody taps, the best source opens on its
      // own — "or wait for the best one".
      setState(() => _stage = _Stage.sourceList);
      _sourceAutoPickTimer?.cancel();
      _sourceAutoPickTimer = Timer(_kSourceAutoPick, () {
        if (_disposed || _stage != _Stage.sourceList) return;
        _pickSourceRow(_streamIndex);
      });
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

  /// The viewer picked a row of the pre-play source list: open it.
  void _pickSourceRow(int index) {
    if (_disposed || _streams.isEmpty) return;
    if (index < 0 || index >= _streams.length) return;
    _sourceAutoPickTimer?.cancel();
    setState(() => _stage = _Stage.playing);
    unawaited(_openStream(index, start: _resumePosition));
  }

  /// Backing out of the pre-play list abandons the resolve and leaves the
  /// player. Returning to portrait happens in [_restoreOrientation] via
  /// the pop path.
  void _abandonAndPop() {
    _sourceAutoPickTimer?.cancel();
    _goBack();
  }

  /// Leave the player, back to portrait. Used by every Back control so
  /// the app never stays stuck in landscape after the video ends.
  void _goBack() {
    _restoreOrientation();
    if (mounted) Navigator.of(context).pop();
  }

  /// The episode after the one playing, or null at the end of the
  /// series / when this is not a series.
  Episode? get _nextEpisode => nextEpisodeFor(
        item: widget.item,
        current: _currentEpisode,
        videoUrl: _videoUrl,
      ).next;

  /// Opens a different episode of the same series in place — the Next
  /// Episode button and the episode picker. The player, its cache and
  /// the orientation stay; only the episode, its sources and its resume
  /// point change. Reuses the same resolve -> source-list -> open path
  /// as the first open, so the portrait source list shows again for
  /// the new episode.
  Future<void> _startEpisode(Episode next) async {
    if (_disposed) return;
    _flushProgress();
    try {
      _tracker?.finish();
    } catch (_) {}
    _sourceAutoPickTimer?.cancel();
    _watchdogTimer?.cancel();
    setState(() {
      _currentEpisode = next;
      _videoUrl = next.url;
      _stage = _Stage.resolving;
      _error = null;
      _streams = [];
      _streamIndex = 0;
      _playing = false;
      _position = Duration.zero;
      _duration = Duration.zero;
      _buffered = Duration.zero;
      _completed = false;
      _buffering = false;
      _startedPlaying = false;
      _resumePosition = Duration.zero;
      _subtitleAppliedFor = -1;
    });
    unawaited(_resolveAndOpen());
  }

  /// The episode picker: every episode of the series, each row with
  /// its poster thumbnail (the plugins already set posterUrl on each
  /// episode). Tapping one opens it in place.
  Future<void> _showEpisodesSheet() async {
    if (!mounted) return;
    final episodes = effectiveEpisodes(widget.item, _currentEpisode);
    if (episodes.isEmpty) return;
    final choice = await showModalBottomSheet<Episode>(
      context: context,
      backgroundColor: const Color(0xff181818),
      isScrollControlled: true,
      builder: (context) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.7,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    'Episodes',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: episodes.length,
                    itemBuilder: (context, i) {
                      final ep = episodes[i];
                      final isCurrent = ep.url == _currentEpisode?.url;
                      final title = ep.name.isNotEmpty
                          ? ep.name
                          : 'Episode ${ep.episode}';
                      final sub = ep.season > 0
                          ? 'S${ep.season} · E${ep.episode}'
                          : 'Episode ${ep.episode}';
                      final poster = ep.posterUrl;
                      return ListTile(
                        leading: (poster == null || poster.isEmpty)
                            ? const SizedBox(
                                width: 40,
                                height: 60,
                                child: Icon(
                                  Icons.movie,
                                  color: Colors.white54,
                                ),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: Image.network(
                                  poster,
                                  width: 40,
                                  height: 60,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => const SizedBox(
                                    width: 40,
                                    height: 60,
                                    child: Icon(
                                      Icons.movie,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ),
                              ),
                        title: Text(
                          title,
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: isCurrent
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          sub,
                          style: const TextStyle(color: Colors.white54),
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.check, color: Colors.white)
                            : null,
                        onTap: () => Navigator.pop(context, ep),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null || _disposed) return;
    unawaited(_startEpisode(choice));
  }

  /// The outline stroke for mpv subtitles, from the persisted setting:
  /// a black shadow in four directions (TextStyle has no stroke, so
  /// the shadow is the outline). None returns null — no outline at all.
  List<Shadow>? _subtitleOutlineShadows(SubtitleOutline outline) {
    final w = switch (outline) {
      SubtitleOutline.none => 0.0,
      SubtitleOutline.thin => 1.0,
      SubtitleOutline.normal => 1.5,
      SubtitleOutline.thick => 2.5,
    };
    if (w == 0) return null;
    return [
      Shadow(color: Colors.black, offset: Offset(-w, -w), blurRadius: 1),
      Shadow(color: Colors.black, offset: Offset(w, -w), blurRadius: 1),
      Shadow(color: Colors.black, offset: Offset(-w, w), blurRadius: 1),
      Shadow(color: Colors.black, offset: Offset(w, w), blurRadius: 1),
    ];
  }

  /// Subtitle Style: size, colour, background, outline and position.
  /// Reads and writes the persisted PlayerSettings (the same settings
  /// the VLC player and the Settings page use), so a style chosen here
  /// sticks across videos and sessions. The mpv subtitle view rebuilds
  /// from those settings in build.
  Future<void> _showSubtitleStylePanel() async {
    if (!mounted) return;
    final repo = ref.read(playerSettingsProvider.notifier);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff181818),
      isScrollControlled: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final s = ref.read(playerSettingsProvider).asData?.value;
            final size = s?.subtitleSize ?? 22.0;
            final color = s?.subtitleColor ?? 0xFFFFFFFF;
            final bgOpacity = s?.subtitleBackgroundOpacity ?? 0.5;
            final outline = s?.subtitleOutline ?? SubtitleOutline.thin;
            final raise = s?.subtitleRaise ?? 0.0;

            void apply(Future<void> Function() fn) {
              unawaited(() async {
                await fn();
                setSheetState(() {});
              }());
            }

            Widget chip(String label, bool selected, VoidCallback onTap) {
              return GestureDetector(
                onTap: onTap,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: selected ? Colors.white : Colors.white12,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected ? Colors.black : Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              );
            }

            Widget swatch(int argb) {
              return GestureDetector(
                onTap: () => apply(() => repo.setSubtitleColor(argb)),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: Color(argb),
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: color == argb ? Colors.white : Colors.white24,
                      width: color == argb ? 3 : 1,
                    ),
                  ),
                ),
              );
            }

            const section = TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            );

            return SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Text(
                          'Subtitle style',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => apply(() async {
                            await repo.setSubtitleSettings(
                              22.0,
                              0xFFFFFFFF,
                              0x00000000,
                              0.5,
                            );
                            await repo.setSubtitleOutline(
                              SubtitleOutline.thin,
                            );
                            await repo.setSubtitleRaise(0.0);
                          }),
                          child: const Text(
                            'Reset',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Text('SIZE', style: section),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          'Small',
                          size <= 17,
                          () => apply(() => repo.setSubtitleSize(16)),
                        ),
                        chip(
                          'Medium',
                          size > 17 && size <= 25,
                          () => apply(() => repo.setSubtitleSize(22)),
                        ),
                        chip(
                          'Large',
                          size > 25 && size <= 30,
                          () => apply(() => repo.setSubtitleSize(28)),
                        ),
                        chip(
                          'Extra large',
                          size > 30,
                          () => apply(() => repo.setSubtitleSize(34)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('COLOUR', style: section),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final c in [
                          0xFFFFFFFF,
                          0xFFFFFF00,
                          0xFF00E5FF,
                          0xFF69F0AE,
                          0xFFFF80AB,
                          0xFFFFAB40,
                        ]) ...[
                          swatch(c),
                          const SizedBox(width: 12),
                        ],
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('BACKGROUND', style: section),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          'None',
                          bgOpacity <= 0.01,
                          () => apply(
                            () => repo.setSubtitleBackground(0x00000000, 0.0),
                          ),
                        ),
                        chip(
                          'Dark',
                          bgOpacity > 0.6,
                          () => apply(
                            () => repo.setSubtitleBackground(0xFF000000, 0.66),
                          ),
                        ),
                        chip(
                          'Semi',
                          bgOpacity > 0.01 && bgOpacity <= 0.6,
                          () => apply(
                            () => repo.setSubtitleBackground(0xFF000000, 0.35),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('OUTLINE', style: section),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          'None',
                          outline == SubtitleOutline.none,
                          () => apply(
                            () => repo.setSubtitleOutline(
                              SubtitleOutline.none,
                            ),
                          ),
                        ),
                        chip(
                          'Thin',
                          outline == SubtitleOutline.thin,
                          () => apply(
                            () => repo.setSubtitleOutline(
                              SubtitleOutline.thin,
                            ),
                          ),
                        ),
                        chip(
                          'Normal',
                          outline == SubtitleOutline.normal,
                          () => apply(
                            () => repo.setSubtitleOutline(
                              SubtitleOutline.normal,
                            ),
                          ),
                        ),
                        chip(
                          'Thick',
                          outline == SubtitleOutline.thick,
                          () => apply(
                            () => repo.setSubtitleOutline(
                              SubtitleOutline.thick,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('POSITION', style: section),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        chip(
                          'Low',
                          raise <= 0.01,
                          () => apply(() => repo.setSubtitleRaise(0.0)),
                        ),
                        chip(
                          'Raised',
                          raise > 0.01 && raise <= 0.2,
                          () => apply(() => repo.setSubtitleRaise(0.15)),
                        ),
                        chip(
                          'High',
                          raise > 0.2,
                          () => apply(() => repo.setSubtitleRaise(0.3)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
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
      episode: _currentEpisode,
      videoUrl: _videoUrl,
      token: _sessionToken,
    );
    // The local watch-position writer. Reopening an episode resumes at
    // the saved position because this writes under the same per-episode
    // key the resume lookup reads.
    _recorder = PlaybackProgressRecorder(
      read: ref.read,
      item: widget.item,
      episode: _currentEpisode,
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
    // No centre "+10s" pop-up: the viewer asked for it removed. The
    // seek still happens; the persistent centre ±10 s buttons are the
    // feedback.
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
    final choice = await showModalBottomSheet<Object>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        final current = _player.state.track.subtitle;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.style, color: Colors.white),
                title: const Text(
                  'Subtitle style',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: const Text(
                  'Size, colour, background, outline, position',
                  style: TextStyle(color: Colors.white54),
                ),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: Colors.white54,
                ),
                onTap: () => Navigator.pop(context, 'style'),
              ),
              ListTile(
                title: const Text(
                  'Off',
                  style: TextStyle(color: Colors.white),
                ),
                trailing: current.id == 'no'
                    ? const Icon(Icons.check, color: Colors.white)
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
                      ? const Icon(Icons.check, color: Colors.white)
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
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                  onTap: () => Navigator.pop(context, sub),
                ),
            ],
          ),
        );
      },
    );
    if (choice == 'style') {
      unawaited(_showSubtitleStylePanel());
      return;
    }
    if (choice is SubtitleTrack) {
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
                      ? const Icon(Icons.check, color: Colors.white)
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
                      ? const Icon(Icons.check, color: Colors.white)
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
                      ? const Icon(Icons.check, color: Colors.white)
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
      if (_disposed || _locked) return;
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
    // This is a seek, not a hold: stamp it so the 2x hold timer never
    // fires for this tap sequence, and kill any timer the tap-down that
    // just arrived may already have started.
    _lastDoubleTapSeekAt = DateTime.now();
    _holdSpeedTimer?.cancel();
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

  // -- tap-and-hold 2x (right side) -----------------------------------------

  /// Press-and-hold on the right half: 2x while held (YouTube-style).
  /// Uses the tap recognizer + a timer, not a long-press recognizer, so
  /// it cannot steal the arena from a double-tap seek or a vertical
  /// swipe. A quick tap or a drag never reaches the timer.
  void _onTapDownForHoldSpeed(TapDownDetails details) {
    if (_locked) return;
    final width = MediaQuery.sizeOf(context).width;
    if (details.globalPosition.dx <= width / 2) return;
    // A double-tap seek just fired: this tap-down is part of it, not a
    // hold — never start the 2x timer for it.
    if (DateTime.now().difference(_lastDoubleTapSeekAt) <
        _kDoubleTapHoldSuppress) {
      return;
    }
    _holdSpeedTimer?.cancel();
    _holdSpeedTimer = Timer(const Duration(milliseconds: 550), () {
      if (_disposed || _locked) return;
      // Re-check: a double-tap that landed after the timer started
      // (tap-down then double-tap-win) still suppresses the hold.
      if (DateTime.now().difference(_lastDoubleTapSeekAt) <
          _kDoubleTapHoldSuppress) {
        return;
      }
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

  // -- aspect ratio / rotate / fullscreen -----------------------------------

  /// Applies [_aspectMode] to the video. Fit and Fill are Flutter-side
  /// (the Video widget's fit, rebuilt in `build`); 16:9 / 4:3 are
  /// mpv-side: `video-aspect-override` forces the display aspect, and
  /// Fill returns it to `-1` (auto) so a later 16:9 pick is not fighting
  /// a leftover override.
  Future<void> _applyAspectMode() async {
    final override = switch (_aspectMode) {
      _AspectMode.ratio16x9 => '16:9',
      _AspectMode.ratio4x3 => '4:3',
      _AspectMode.fit || _AspectMode.fill => '-1',
    };
    try {
      await (_player.platform as NativePlayer).setProperty(
        'video-aspect-override',
        override,
      );
    } catch (_) {
      // The Flutter-side fit (BoxFit.cover for Fill) still applies; a
      // failed mpv property only loses the 16:9 / 4:3 stretch.
    }
  }

  /// The aspect-ratio sheet: Fit (default), Fill / Zoom (crop to the
  /// screen, no bars), 16:9, 4:3.
  Future<void> _pickAspectRatio() async {
    if (!mounted) return;
    const modes = [
      (
        _AspectMode.fit,
        'Fit',
        'Whole picture, letterbox bars where it disagrees',
      ),
      (
        _AspectMode.fill,
        'Fill / Zoom',
        'Crop to fill the screen, no bars',
      ),
      (_AspectMode.ratio16x9, '16:9', 'Force widescreen'),
      (_AspectMode.ratio4x3, '4:3', 'Force classic'),
    ];
    final choice = await showModalBottomSheet<_AspectMode>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final (mode, label, hint) in modes)
                ListTile(
                  title: Text(
                    label,
                    style: const TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    hint,
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: _aspectMode == mode
                      ? const Icon(Icons.check, color: Colors.white)
                      : null,
                  onTap: () => Navigator.pop(context, mode),
                ),
            ],
          ),
        );
      },
    );
    if (choice == null || _disposed) return;
    setState(() => _aspectMode = choice);
    await _applyAspectMode();
  }

  /// Rotate: frees the orientation so the viewer can turn the phone to
  /// portrait; tapping again pins it back to landscape.
  void _toggleRotate() {
    _orientationFree = !_orientationFree;
    if (_orientationFree) {
      unawaited(
        SystemChrome.setPreferredOrientations(DeviceOrientation.values),
      );
    } else {
      _landscapeForced = false;
      _forceLandscapeOnce();
    }
    if (mounted) setState(() {});
  }

  /// Fullscreen: a quick toggle between Fit (whole picture) and Fill
  /// (crop to the screen, no bars).
  Future<void> _toggleFullscreen() async {
    setState(() {
      _aspectMode =
          _aspectMode == _AspectMode.fill ? _AspectMode.fit : _AspectMode.fill;
    });
    await _applyAspectMode();
  }

  // -- download --------------------------------------------------------------

  /// Download the current title/episode through the details screen's
  /// download flow (it resolves the episode and starts the download).
  Future<void> _downloadCurrent() async {
    if (!mounted) return;
    try {
      await ref.read(downloadLauncherProvider).launch(
            context,
            widget.item,
            episodeUrl: _currentEpisode?.url ?? _videoUrl,
          );
    } catch (_) {
      // A download failure must never break playback.
    }
  }

  // -- "More" sheet (the ">" in the Nuvio left row) --------------------------

  /// Sources / Quality, Aspect ratio, Rotate, Fullscreen — the functions
  /// that do not have their own icon in the Nuvio left row.
  Future<void> _showMoreSheet() async {
    if (!mounted) return;
    final episodes = effectiveEpisodes(widget.item, _currentEpisode);
    final nextEp = _nextEpisode;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xff181818),
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.swap_horiz, color: Colors.white),
                title: const Text(
                  'Source / Quality',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  _selected?.displaySource ?? '',
                  style: const TextStyle(color: Colors.white54),
                ),
                trailing: _streams.length > 1
                    ? const Icon(Icons.chevron_right, color: Colors.white54)
                    : null,
                onTap: _streams.length > 1
                    ? () => Navigator.pop(context, 'source')
                    : null,
              ),
              if (episodes.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.list, color: Colors.white),
                  title: const Text(
                    'Episodes',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    '${episodes.length} episodes',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.white54,
                  ),
                  onTap: () => Navigator.pop(context, 'episodes'),
                ),
              if (nextEp != null)
                ListTile(
                  leading:
                      const Icon(Icons.skip_next, color: Colors.white),
                  title: const Text(
                    'Next episode',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: Text(
                    nextEp.name.isNotEmpty
                        ? nextEp.name
                        : 'Episode ${nextEp.episode}',
                    style: const TextStyle(color: Colors.white54),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: Colors.white54,
                  ),
                  onTap: () => Navigator.pop(context, 'next'),
                ),
              ListTile(
                leading:
                    const Icon(Icons.aspect_ratio, color: Colors.white),
                title: const Text(
                  'Aspect ratio',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  switch (_aspectMode) {
                    _AspectMode.fit => 'Fit',
                    _AspectMode.fill => 'Fill / Zoom',
                    _AspectMode.ratio16x9 => '16:9',
                    _AspectMode.ratio4x3 => '4:3',
                  },
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () => Navigator.pop(context, 'aspect'),
              ),
              ListTile(
                leading: const Icon(Icons.screen_rotation, color: Colors.white),
                title: const Text(
                  'Rotate',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  _orientationFree
                      ? 'Orientation free — turn the phone'
                      : 'Pinned to landscape',
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () => Navigator.pop(context, 'rotate'),
              ),
              ListTile(
                leading: const Icon(Icons.fullscreen, color: Colors.white),
                title: const Text(
                  'Fullscreen',
                  style: TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  _aspectMode == _AspectMode.fill
                      ? 'Fill — cropped to the screen'
                      : 'Fit — whole picture',
                  style: const TextStyle(color: Colors.white54),
                ),
                onTap: () => Navigator.pop(context, 'fullscreen'),
              ),
            ],
          ),
        );
      },
    );
    if (action == null || _disposed) return;
    switch (action) {
      case 'source':
        await _pickSource();
      case 'episodes':
        await _showEpisodesSheet();
      case 'next':
        if (nextEp != null) unawaited(_startEpisode(nextEp));
      case 'aspect':
        await _pickAspectRatio();
      case 'rotate':
        _toggleRotate();
      case 'fullscreen':
        await _toggleFullscreen();
    }
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
    final position = _position;
    final duration = _duration;
    final bufferedFrac = _canSeek
        ? (_buffered.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    // Subtitle style (persisted PlayerSettings; the Subtitle Style
    // panel writes them). The mpv subtitle view reads them live.
    final subSettings = ref.watch(playerSettingsProvider).asData?.value;
    final subSize = subSettings?.subtitleSize ?? _kSubtitleFontSize;
    final subColor = Color(subSettings?.subtitleColor ?? 0xFFFFFFFF);
    final subBg = Color(
      subSettings?.subtitleBackgroundColor ?? 0x00000000,
    ).withValues(
      alpha: (subSettings?.subtitleBackgroundOpacity ?? 0.5).clamp(0.0, 1.0),
    );
    final subOutline = subSettings?.subtitleOutline ?? SubtitleOutline.thin;
    final subLift =
        (subSettings?.subtitleRaise ?? 0.0).clamp(0.0, 0.5) *
        MediaQuery.sizeOf(context).height;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Video + gestures.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
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
                  fit: _aspectMode == _AspectMode.fill
                      ? BoxFit.cover
                      : BoxFit.contain,
                  fill: Colors.black,
                  // Custom controls below; media_kit's own are hidden.
                  controls: (_) => const SizedBox.shrink(),
                  wakelock: true,
                  pauseUponEnteringBackgroundMode: true,
                  subtitleViewConfiguration: SubtitleViewConfiguration(
                    style: TextStyle(
                      height: 1.4,
                      fontSize: subSize,
                      color: subColor,
                      fontWeight: FontWeight.w500,
                      backgroundColor: subBg.a == 0 ? null : subBg,
                      shadows: _subtitleOutlineShadows(subOutline),
                    ),
                    textAlign: TextAlign.center,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      (_controlsVisible
                              ? _kSubtitlePaddingControls
                              : _kSubtitlePaddingHidden) +
                          subLift,
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
                    const CircularProgressIndicator(color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      l10n.loading,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          // Pre-play source list (portrait): pick a source, or wait
          // for the best one (auto-pick). Back abandons and leaves.
          if (_stage == _Stage.sourceList)
            Container(
              color: Colors.black,
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        IconButton(
                          onPressed: _abandonAndPop,
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            widget.item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 17,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_currentEpisode != null)
                      Padding(
                        padding: const EdgeInsets.only(
                          left: 16,
                          top: 2,
                          bottom: 8,
                        ),
                        child: Text(
                          _currentEpisode!.name.isNotEmpty
                              ? _currentEpisode!.name
                              : 'Episode',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          'Source ${_streamIndex + 1} of ${_streams.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: _streams.length,
                        itemBuilder: (context, i) {
                          final s = _streams[i];
                          final isBest = i == _streamIndex;
                          final quality = s.quality;
                          final qualityLabel = quality == null
                              ? null
                              : quality == 0
                                  ? 'Adaptive'
                                  : '${quality}p';
                          return ListTile(
                            leading: const Icon(
                              Icons.play_circle_outline,
                              color: Colors.white,
                            ),
                            title: Text(
                              s.displaySource,
                              style: const TextStyle(color: Colors.white),
                            ),
                            subtitle: qualityLabel == null
                                ? null
                                : Text(
                                    qualityLabel,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                    ),
                                  ),
                            trailing: isBest
                                ? const Icon(
                                    Icons.check,
                                    color: Colors.white,
                                  )
                                : null,
                            onTap: () => _pickSourceRow(i),
                          );
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Best source opens automatically in a few seconds.',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
                      ),
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
              child: CircularProgressIndicator(color: Colors.white),
            ),

          // Hold-2x indicator (white pill, Nuvio): shown while the
          // right-side press is held. The video keeps playing at 2x
          // until the finger lifts.
          if (_holdSpeedActive)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 56,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xcc1a1a1a),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fast_forward,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 6),
                      Text(
                        '2x speed',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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
                          onPressed: _goBack,
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
              title: widget.item.title,
              year: widget.item.year,
              isLive: _isLive,
              playing: _playing,
              buffering: _buffering,
              position: position,
              duration: duration,
              bufferedFraction: bufferedFrac,
              canSeek: _canSeek,
              speed: _speed,
              locked: _locked,
              subtitleLabel: _player.state.track.subtitle.title,
              hasNextEpisode: _nextEpisode != null,
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
              onSubtitle: _pickSubtitle,
              onAudio: _pickAudio,
              onDownload: _downloadCurrent,
              onNextEpisode: () {
                final next = _nextEpisode;
                if (next != null) unawaited(_startEpisode(next));
              },
              onMore: _showMoreSheet,
              onLock: () {
                setState(() => _locked = !_locked);
                if (_locked) _showControls();
              },
              onSpeed: _pickSpeed,
              format: _format,
            ),
        ],
      ),
    );
  }
}

/// Nuvio-style controls: white on dark, navigation on the LEFT.
///
/// * Top bar: only Lock + Back, right-aligned (no cast — the app has
///   no cast support).
/// * Centre: the persistent ±10 s + play/pause row, vertically centred.
/// * Bottom: title + year above a full-width thin progress bar, then a
///   row with the navigation icons on the left (CC, Audio, Download,
///   Speed, Next episode, More ">") and the time on the right.
///
/// No gold anywhere: white icons/text/progress on dark.
class _ControlsOverlay extends StatelessWidget {
  const _ControlsOverlay({
    required this.title,
    required this.year,
    required this.isLive,
    required this.playing,
    required this.buffering,
    required this.position,
    required this.duration,
    required this.bufferedFraction,
    required this.canSeek,
    required this.speed,
    required this.locked,
    required this.subtitleLabel,
    required this.hasNextEpisode,
    required this.onBack,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekTo,
    required this.onSubtitle,
    required this.onAudio,
    required this.onDownload,
    required this.onNextEpisode,
    required this.onMore,
    required this.onLock,
    required this.onSpeed,
    required this.format,
  });

  final String title;
  final int? year;
  final bool isLive;
  final bool playing;
  final bool buffering;
  final Duration position;
  final Duration duration;
  final double bufferedFraction;
  final bool canSeek;
  final double speed;
  final bool locked;
  final String? subtitleLabel;
  final bool hasNextEpisode;
  final VoidCallback onBack;
  final VoidCallback onPlayPause;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekForward;
  final ValueChanged<double> onSeekTo;
  final VoidCallback onSubtitle;
  final VoidCallback onAudio;
  final VoidCallback onDownload;
  final VoidCallback onNextEpisode;
  final VoidCallback onMore;
  final VoidCallback onLock;
  final VoidCallback onSpeed;
  final String Function(Duration) format;

  @override
  Widget build(BuildContext context) {
    final positionFrac = canSeek && duration > Duration.zero
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    return Column(
      children: [
        // Top bar: Lock + Back, right-aligned.
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
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
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
                onPressed: onLock,
                icon: Icon(
                  locked ? Icons.lock : Icons.lock_open,
                  color: Colors.white,
                ),
                tooltip: locked ? 'Unlock' : 'Lock',
              ),
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: 'Back',
              ),
            ],
          ),
        ),
        const Spacer(),
        // Centre: ±10 s + play/pause, persistent (the Nuvio layout).
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              onPressed: canSeek ? onSeekBack : null,
              icon: const Icon(Icons.replay_10, color: Colors.white),
              iconSize: 34,
            ),
            const SizedBox(width: 24),
            IconButton(
              onPressed: onPlayPause,
              icon: Icon(
                buffering
                    ? Icons.hourglass_top
                    : playing
                        ? Icons.pause
                        : Icons.play_arrow,
                color: Colors.white,
              ),
              iconSize: 56,
            ),
            const SizedBox(width: 24),
            IconButton(
              onPressed: canSeek ? onSeekForward : null,
              icon: const Icon(Icons.forward_10, color: Colors.white),
              iconSize: 34,
            ),
          ],
        ),
        const Spacer(),
        // Bottom: title + year, progress bar, navigation row + time.
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            bottom: MediaQuery.paddingOf(context).bottom + 8,
            top: 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 17,
                ),
              ),
              if (year != null)
                Text(
                  year.toString(),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 13,
                  ),
                ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 6,
                  ),
                  overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 12,
                  ),
                  activeTrackColor: Colors.white,
                  inactiveTrackColor: Colors.white24,
                  secondaryActiveTrackColor: Colors.white38,
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: positionFrac,
                  secondaryTrackValue: bufferedFraction,
                  onChanged: canSeek ? onSeekTo : null,
                ),
              ),
              Row(
                children: [
                  IconButton(
                    onPressed: onSubtitle,
                    icon: Icon(
                      Icons.closed_caption,
                      color: subtitleLabel == null
                          ? Colors.white54
                          : Colors.white,
                    ),
                    tooltip: 'Subtitles',
                  ),
                  IconButton(
                    onPressed: onAudio,
                    icon: const Icon(Icons.audiotrack, color: Colors.white),
                    tooltip: 'Audio',
                  ),
                  IconButton(
                    onPressed: onDownload,
                    icon: const Icon(Icons.download, color: Colors.white),
                    tooltip: 'Download',
                  ),
                  TextButton(
                    onPressed: onSpeed,
                    child: Text(
                      '${speed}x',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (hasNextEpisode)
                    IconButton(
                      onPressed: onNextEpisode,
                      icon: const Icon(Icons.skip_next, color: Colors.white),
                      tooltip: 'Next episode',
                    ),
                  IconButton(
                    onPressed: onMore,
                    icon: const Icon(Icons.chevron_right, color: Colors.white),
                    tooltip: 'More',
                  ),
                  const Spacer(),
                  Text(
                    isLive
                        ? 'LIVE'
                        : '${format(position)} / ${format(duration)}',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
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
