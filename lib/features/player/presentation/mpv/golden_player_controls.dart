/// The Premium Golden player overlay for the mpv engine.
///
/// The stock chrome ([VlcPlayerControls]) replaced by the gold design the
/// user asked for (ChatGPT spec + mockup): black #080808 with champagne
/// gold #D4AF37, dark top/bottom gradients, a thin golden seekbar, rounded
/// floating buttons, 200–300 ms fades.
///
/// Layout (mockup + spec):
///   * top bar — Back, title + season/episode line, audio/subtitle,
///     Episodes (series only), More;
///   * centre — Rewind 10 s, Play/Pause (gold circle), Forward 10 s
///     (hidden while a right-side hold is down — the hold shows no label
///     at all: the viewer asked for the "2x" pill to go too);
///   * bottom — golden seekbar with current/total time, then Previous,
///     Next (series), subtitle, volume, speed chip, lock, aspect, rotate.
///
/// Gestures (same as the stock chrome, restyled):
///   * single tap shows/hides the chrome (3 s auto-hide, owned by
///     [ChromeVisibilityController]);
///   * double-tap left/right seeks ∓10 s;
///   * long-press on the RIGHT half holds 2x until release (the saved
///     speed is restored exactly — 1.5x comes back as 1.5x);
///   * pinch zooms the picture (the screen's [videoScale]);
///   * vertical swipe on the RIGHT half changes the volume, on the LEFT
///     half the screen brightness — a full screen height is the whole
///     range. A small gold rail shows the level and fades after the swipe
///     ends. A swipe that is clearly horizontal does nothing (the Golden
///     player has no swipe-seek), and a pinch still zooms.
///
/// Everything is wired to the real engine through the adapter: no
/// placeholder buttons. No Cast button — mpv/media_kit has no cast in
/// this app, and a dead one is worse than none. PiP is Android-only: the
/// screen passes `onEnterPip` where PiP exists (button in the top bar),
/// nothing on iOS — mpv renders through a Metal texture there. The
/// drawers (Episodes, Subtitle Style, Audio, Sources) slide in from the
/// right over the video.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import '../../../skip/data/skip_service.dart';
import '../../domain/skip_segments.dart';
import '../player_brightness.dart';
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/panel/player_panel_data.dart';
import '../vlc/transient_overlay.dart';
import 'golden_drawer.dart';
import 'golden_episodes_drawer.dart';
import 'golden_options_drawer.dart';
import 'golden_player_theme.dart';
import 'golden_subtitle_style_drawer.dart';

/// The seek step for the ±10 s buttons and the double-tap, per the spec.
const Duration _kGoldenSeekStep = Duration(seconds: 10);

/// Which right-side drawer is open, if any.
enum _GoldenDrawerKind { none, episodes, subtitleStyle, audio, sources }

/// The axis a single-finger pan has committed to, if any.
///
/// Decided once, from the down point, so a diagonal swipe is one gesture
/// or the other — never both, and never a rail that becomes a seek.
enum _GoldenPanAxis { none, horizontal, vertical }

class GoldenPlayerControls extends ConsumerStatefulWidget {
  const GoldenPlayerControls({
    required this.controller,
    required this.chrome,
    required this.title,
    required this.onBack,
    required this.panelData,
    required this.settings,
    required this.settingsNotifier,
    required this.onPickEpisode,
    required this.onPickSource,
    this.bufferedFraction,
    this.episodeLine,
    this.subtitle,
    this.onNextEpisode,
    this.onPreviousEpisode,
    this.onAudioPicked,
    this.onSubtitlePicked,
    this.episodeProgress,
    this.episodeDuration,
    this.hasSubtitles,
    this.fit = VlcVideoFit.contain,
    this.onFitChanged,
    this.videoScale,
    this.onRotate,
    this.isLive = false,
    this.skipSegments = const <SkipSegment>[],
    this.onSkipOutro,
    this.locked,
    this.lockAvailable = true,
    this.onEnterPip,
    super.key,
  });

  /// The mpv-backed controller (the adapter).
  final VlcPlayerController controller;

  /// Fraction of the media fetched ahead of the playhead.
  final ValueListenable<double>? bufferedFraction;

  /// Owns the auto-hide clock; the screen lends it here.
  final ChromeVisibilityController chrome;

  /// The title line, and the season/episode + source lines under it.
  final String title;
  final String? episodeLine;
  final String? subtitle;

  final VoidCallback? onBack;

  /// Non-null only when a next / previous episode exists.
  final VoidCallback? onNextEpisode;
  final VoidCallback? onPreviousEpisode;

  /// The screen's published data (episodes, sources, current indexes).
  final ValueListenable<PanelData> panelData;

  /// The saved subtitle settings, live, and their writer.
  final ValueListenable<PlayerSettings> settings;
  final PlayerSettingsNotifier settingsNotifier;

  /// Episode / source picks, wired to the screen's real loaders.
  final ValueChanged<Episode> onPickEpisode;
  final ValueChanged<int> onPickSource;

  /// Remembered across failover by the screen.
  final ValueChanged<VlcTrackDescription>? onAudioPicked;
  final ValueChanged<int?>? onSubtitlePicked;

  /// Per-episode progress and length, for the Episodes drawer.
  final EpisodeProgressLookup? episodeProgress;
  final GoldenEpisodeDuration? episodeDuration;

  /// Whether this media has a subtitle to pick; the CC button hides
  /// without one.
  final ValueListenable<bool>? hasSubtitles;

  /// The video fit, owned by the screen.
  final VlcVideoFit fit;
  final ValueChanged<VlcVideoFit>? onFitChanged;

  /// The pinch zoom's value, owned by the screen.
  final ValueNotifier<double>? videoScale;

  /// Flips the handset the other way. Non-null on a phone/tablet.
  final VoidCallback? onRotate;

  final bool isLive;

  /// Intro/outro bands, usually empty.
  final List<SkipSegment> skipSegments;
  final VoidCallback? onSkipOutro;

  /// Whether the screen is locked; the lock button only shows where
  /// [lockAvailable] is true (a touch form factor).
  final ValueNotifier<bool>? locked;
  final bool lockAvailable;

  /// Enters picture-in-picture. Non-null on Android where PiP exists; the
  /// button renders only when this is non-null and the `showPip` setting
  /// is on — the same gate as the stock chrome. Null on iOS (mpv has no
  /// PiP window there) and on TV.
  final VoidCallback? onEnterPip;

  @override
  ConsumerState<GoldenPlayerControls> createState() =>
      _GoldenPlayerControlsState();
}

class _GoldenPlayerControlsState
    extends ConsumerState<GoldenPlayerControls> {
  _GoldenDrawerKind _drawer = _GoldenDrawerKind.none;

  /// The speed a 2x hold restores, or null when no hold is down.
  double? _speedBeforeBoost;

  /// Whether the 2x pill is up.
  bool _boosting = false;

  /// The centre play/pause flash, shown briefly after a centre
  /// double-tap (see [_showCenterFlash]): the icon of the state the
  /// player is moving into, or null when no flash is up.
  IconData? _centerFlashIcon;
  Timer? _centerFlashTimer;

  /// A seekbar drag in flight, and its preview target.
  bool _seeking = false;
  Duration _seekPreview = Duration.zero;

  /// Pinch state, for the zoom.
  bool _pinching = false;
  double _pinchStartScale = 1.0;

  // -- vertical swipe rails (volume right / brightness left) --------------
  //
  // One scale recognizer owns the single-finger pan and the pinch together
  // (the stock chrome's shape): the axis is decided once, from the down
  // point, and a clearly vertical pan becomes a rail. Right half = the
  // mpv volume, left half = the screen brightness, through the same seam
  // the stock chrome uses ([PlatformPlayerBrightness]).
  _GoldenPanAxis _panAxis = _GoldenPanAxis.none;

  /// The down point the pan's travel is measured from, landed by a
  /// Listener before any arena resolution (the scale recognizer spends
  /// its slop first, so its own start would drop the first travel).
  Offset? _panAnchor;
  double? _panAnchorLocalX;

  /// Whether the rail in flight is volume (true) or brightness (false);
  /// null when no rail is down.
  bool? _dragIsVolume;

  /// The level the swipe counts from, and the running level as the travel
  /// lands: volume 0..100, brightness 0..1.
  double _dragStart = 0;

  /// Whether the start level has been read. The brightness read is async,
  /// so a flick's travel waits here ([_dragPending]) and lands once the
  /// read does, rather than being dropped.
  bool _dragReady = false;
  double _dragPending = 0;
  int _dragId = 0;

  /// The screen's brightness, mirrored from the last read. The app's
  /// brightness is a process-wide override, so leaving the player gives
  /// the screen back to the system's level (see [dispose]).
  double _brightness = 0.5;
  bool _brightnessOverridden = false;
  late final PlayerBrightness _brightnessControl =
      PlatformPlayerBrightness();

  /// The volume / brightness rail. Written on every drag update, same rule
  /// as the stock chrome: the rail owns its own hide timer, so the drag
  /// writes never rebuild the overlay.
  final TransientValue<_GoldenRailData> _rail =
      TransientValue<_GoldenRailData>();

  /// Rails are a touch gesture: the stock chrome has none on desktop, and
  /// neither does this one.
  static bool get _isTouch => switch (defaultTargetPlatform) {
    TargetPlatform.iOS || TargetPlatform.android => true,
    _ => false,
  };

  bool get _locked => widget.locked?.value ?? false;

  bool get _isSeries => widget.panelData.value.episodes.isNotEmpty;

  // -- transport ------------------------------------------------------------

  void _togglePlay() {
    final value = widget.controller.value;
    if (value.isPlaying) {
      unawaited(widget.controller.pause());
    } else {
      unawaited(widget.controller.play());
    }
    widget.chrome.poke();
  }

  void _seekBy(Duration delta) {
    final value = widget.controller.value;
    if (!value.isSeekable || value.duration <= Duration.zero) return;
    var target = value.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > value.duration) target = value.duration;
    unawaited(widget.controller.seekTo(target));
    widget.chrome.keepAlive();
  }

  void _doubleTap(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    // Zones are thirds, not halves: the centre third toggles play/pause
    // and the outer thirds seek ±10s, so a double-tap near the middle
    // never seeks when the viewer meant to pause (and a seek near the
    // edge never pauses when the viewer meant to skip).
    if (dx >= width / 3 && dx <= 2 * width / 3) {
      _togglePlayWithFlash();
      return;
    }
    _seekBy(dx >= width / 2 ? _kGoldenSeekStep : -_kGoldenSeekStep);
  }

  /// Locked double-tap: only the outer thirds seek (±10s) — the same
  /// zones as unlocked, so a pocket that double-taps the right side
  /// still skips ahead. The centre third does nothing (play/pause stays
  /// locked), and there is no centre flash: a locked tap must not look
  /// like a control, and the +10s/−10s pop-up is gone by the +14 rule.
  void _doubleTapLocked(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    if (dx >= width / 3 && dx <= 2 * width / 3) return;
    _seekBy(dx > 2 * width / 3 ? _kGoldenSeekStep : -_kGoldenSeekStep);
  }

  /// Centre double-tap: pause if playing, resume if paused, and flash
  /// the state the player is moving into, so the tap is seen as well
  /// as felt. The flash is the centre button's own look — a dark
  /// translucent circle with a white icon — so it reads as one control.
  void _togglePlayWithFlash() {
    final wasPlaying = widget.controller.value.isPlaying;
    _togglePlay();
    _showCenterFlash(
      wasPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
    );
  }

  void _showCenterFlash(IconData icon) {
    _centerFlashTimer?.cancel();
    setState(() => _centerFlashIcon = icon);
    _centerFlashTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _centerFlashIcon = null);
    });
  }

  // -- 2x hold ---------------------------------------------------------------

  /// Holds playback at double speed while the finger is down on the RIGHT
  /// half. Live streams are excluded (nothing ahead to race towards).
  /// The saved speed is restored exactly on release.
  void _startSpeedBoost(double dx) {
    if (widget.isLive || _speedBeforeBoost != null) return;
    final width = context.size?.width ?? 0;
    if (width <= 0 || dx < width / 2) return;
    final value = widget.controller.value;
    if (!value.isPlaying) return;
    _speedBeforeBoost = value.playbackSpeed;
    unawaited(widget.controller.setPlaybackSpeed(2.0));
    setState(() => _boosting = true);
  }

  void _endSpeedBoost() {
    final previous = _speedBeforeBoost;
    if (previous == null) return;
    _speedBeforeBoost = null;
    unawaited(widget.controller.setPlaybackSpeed(previous));
    if (mounted) setState(() => _boosting = false);
  }

  // -- pinch zoom + vertical swipe rails -----------------------------------

  /// Lands the pan's anchor: a [Listener] reports the pointer's down
  /// immediately, before any arena resolution. The tap recognizer's
  /// `onTapDown` cannot do this — it only fires once the tap has won the
  /// arena, and a pan's tap never does. The anchor is only taken while no
  /// pan or pinch is in flight, so a second finger landing mid-gesture
  /// cannot move it.
  void _onPointerDown(PointerDownEvent event) {
    if (_panAxis != _GoldenPanAxis.none || _pinching) return;
    _panAnchor = event.position;
    _panAnchorLocalX = event.localPosition.dx;
  }

  /// The one scale gesture: pan with one finger, pinch with two.
  ///
  /// Why one recognizer, and not a separate drag pair: the scale
  /// recognizer used to live under the video, below this detector's drag
  /// recognizers, and the two raced in the gesture arena for the same
  /// first finger. One recognizer cannot race itself: while it tracks one
  /// finger its focal movement is the pan, and the moment a second finger
  /// lands its span is the pinch. The tap, the double-tap seek and the
  /// long-press boost stay on separate recognizers in the same detector —
  /// a tap moves nowhere and a hold moves nowhere, so neither can steal a
  /// pinch that moves, and a swipe that moves wins the arena before the
  /// long-press timer fires.
  void _onScaleStart(ScaleStartDetails d) {
    // A stale pan from an end the framework never delivered — an
    // interrupted pointer — is cleared here, so the next gesture does not
    // inherit a rail.
    _railDragEnd();
    _panAxis = _GoldenPanAxis.none;
    if (d.pointerCount >= 2) {
      _pinching = true;
      _pinchStartScale = widget.videoScale?.value ?? 1.0;
      // A pinch is deliberate, not a hold: a 2x boost goes away with it.
      _endSpeedBoost();
      return;
    }
    // One finger. A pinch that wound down to one finger restarts here as a
    // pan, from where the finger is now — not from where it went down,
    // which the pinch already spent.
    final bool wasPinching = _pinching;
    _pinching = false;
    if (wasPinching || _panAnchor == null) {
      _panAnchor = d.focalPoint;
      _panAnchorLocalX = d.localFocalPoint.dx;
    }
    // Otherwise the anchor is the down point the Listener recorded, which
    // is what the first update measures the pan's travel from.
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      // A second finger landed mid-pan: the pan is cancelled, not
      // committed. A rail already applies live, so ending it is only
      // hiding it on its clock.
      if (!_pinching) {
        _pinching = true;
        _pinchStartScale = widget.videoScale?.value ?? 1.0;
        _railDragEnd();
        _endSpeedBoost();
      }
      final notifier = widget.videoScale;
      if (notifier == null) return;
      // details.scale is the fingers' distance relative to the gesture's
      // start — under 1.0 while pinching in — so this falls as well as
      // rises. clamp() returns num; toDouble() keeps the value a double.
      final double scale =
          (_pinchStartScale * d.scale).clamp(0.5, 3.0).toDouble();
      if (scale != notifier.value) notifier.value = scale;
      return;
    }
    if (_pinching || d.pointerCount != 1) return;
    if (_panAxis == _GoldenPanAxis.none) {
      // The pan's travel is measured from the anchor — the down point —
      // not from the scale recognizer's start: the recognizer spends the
      // first pixels crossing its own slop before it starts. Measuring
      // from the anchor keeps the rail's first travel the same, so a
      // short drag still moves the level. The travel is derived from two
      // points, never accumulated, so it can never be counted twice.
      final Offset anchor = _panAnchor ?? d.focalPoint;
      final Offset travel = d.focalPoint - anchor;
      if (travel.distance < 10) return;
      _panAxis = travel.dx.abs() >= travel.dy.abs()
          ? _GoldenPanAxis.horizontal
          : _GoldenPanAxis.vertical;
      if (_panAxis == _GoldenPanAxis.vertical) {
        unawaited(_beginRail(_panAnchorLocalX ?? d.localFocalPoint.dx));
        // The rail is incremental: this update applies the whole travel
        // since the down point in one go, and the updates that follow it
        // each apply only their own.
        _updateRail(travel.dy);
      }
      // A horizontal pan does nothing: the Golden player has no
      // swipe-seek, and the axis stays horizontal so a later update
      // cannot turn it into a rail.
      return;
    }
    if (_panAxis == _GoldenPanAxis.vertical) {
      _updateRail(d.focalPointDelta.dy);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (d.pointerCount >= 2) {
      // More than one pointer is still down: the pan just ended because a
      // second finger landed, and the gesture carries on as a pinch.
      _pinching = true;
      _pinchStartScale = widget.videoScale?.value ?? 1.0;
      _railDragEnd();
      _endSpeedBoost();
      _panAxis = _GoldenPanAxis.none;
      return;
    }
    if (_pinching) {
      // The pinch wound down to one finger (or none): the scale sticks
      // where it left it, re-clamped here so the settled value is always
      // inside the range. One finger remaining carries on as a pan from
      // here, so the axis is undecided again rather than committed.
      _pinching = false;
      final notifier = widget.videoScale;
      if (notifier != null) {
        final double settled = notifier.value.clamp(0.5, 3.0).toDouble();
        if (settled != notifier.value) notifier.value = settled;
      }
      _panAxis = _GoldenPanAxis.none;
      // The gesture is over (or winding down to a pan the restart
      // re-anchors): the anchor must not outlive it.
      _panAnchor = null;
      _panAnchorLocalX = null;
      return;
    }
    // The last pointer lifted: the pan commits.
    if (_panAxis == _GoldenPanAxis.vertical) {
      _railDragEnd();
    }
    _panAxis = _GoldenPanAxis.none;
    _panAnchor = null;
    _panAnchorLocalX = null;
  }

  /// Starts a brightness or volume rail: brightness on the left half,
  /// volume on the right. [localX] is the finger's x in this detector's
  /// coordinates, which is what decides the half.
  Future<void> _beginRail(double localX) async {
    if (!_isTouch) {
      _dragIsVolume = null;
      return;
    }
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    final isVolume = localX >= width / 2;
    final id = ++_dragId;
    _dragIsVolume = isVolume;
    _dragReady = false;
    _dragPending = 0;
    // Read as each swipe starts, as the stock chrome does: the level can
    // have moved with no word to the player — Control Center or the
    // notification shade move the brightness. A platform with no answer
    // carries on from the mirrored one. The volume is the controller's
    // own value, read synchronously.
    if (isVolume) {
      _dragStart = widget.controller.value.volume.toDouble();
    } else {
      final level = await _brightnessControl.read();
      if (!mounted || id != _dragId) return;
      if (level != null) _brightness = level;
      _dragStart = _brightness;
    }
    _dragReady = true;
    final pending = _dragPending;
    _dragPending = 0;
    // A flick can end before the read lands: its travel still counts, and
    // the rail then keeps its own clock.
    if (pending != 0) {
      _railTravel(isVolume, pending, live: _dragIsVolume == isVolume);
    }
  }

  /// A full screen height of travel covers the whole range.
  ///
  /// [primaryDelta] is the finger's vertical travel since the last update.
  void _updateRail(double primaryDelta) {
    final isVolume = _dragIsVolume;
    if (isVolume == null) return;
    final height = context.size?.height ?? 0;
    if (height <= 0) return;

    final travel = -primaryDelta / height;
    if (!_dragReady) {
      _dragPending += travel;
      return;
    }
    _railTravel(isVolume, travel);
  }

  /// Moves the swipe's level by [travel], a share of the screen's height,
  /// and applies it. Not [live]: the finger has already lifted, so the
  /// rail hides on its own clock.
  void _railTravel(bool isVolume, double travel, {bool live = true}) {
    if (isVolume) {
      // The Golden player's volume is 0..100, matching its volume sheet;
      // no boost past 100% on a swipe.
      final level = (_dragStart + travel * 100).clamp(0.0, 100.0);
      _dragStart = level;
      unawaited(widget.controller.setVolume(level.round()));
      _rail.show(
        _GoldenRailData(
          icon: _volumeIcon(level),
          value: level / 100,
          label: '${level.round()}%',
          onLeft: false,
        ),
        hideAfter: live ? null : const Duration(milliseconds: 900),
      );
    } else {
      _dragStart = (_dragStart + travel).clamp(0.0, 1.0);
      _brightness = _dragStart;
      _brightnessOverridden = true;
      _brightnessControl.set(_brightness);
      _rail.show(
        _GoldenRailData(
          icon: _brightnessIcon(_brightness),
          value: _brightness,
          label: '${(_brightness * 100).round()}%',
          onLeft: true,
        ),
        hideAfter: live ? null : const Duration(milliseconds: 500),
      );
    }
  }

  static IconData _volumeIcon(double level) {
    if (level <= 0) return Icons.volume_off_rounded;
    if (level < 50) return Icons.volume_down_rounded;
    return Icons.volume_up_rounded;
  }

  static IconData _brightnessIcon(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if (clamped < 0.33) return Icons.brightness_5_rounded;
    if (clamped < 0.67) return Icons.brightness_6_rounded;
    return Icons.brightness_7_rounded;
  }

  void _railDragEnd() {
    _dragIsVolume = null;
    _rail.clearAfter(const Duration(milliseconds: 1500));
  }

  // -- drawers ----------------------------------------------------------------

  void _openDrawer(_GoldenDrawerKind kind) {
    if (_drawer == kind) return;
    final wasOpen = _drawer != _GoldenDrawerKind.none;
    setState(() => _drawer = kind);
    if (!wasOpen) widget.chrome.poke(hold: true);
  }

  void _closeDrawer() {
    if (_drawer == _GoldenDrawerKind.none) return;
    setState(() => _drawer = _GoldenDrawerKind.none);
    widget.chrome.release();
  }

  // -- fit / speed / volume ----------------------------------------------------

  void _cycleFit() {
    final next = switch (widget.fit) {
      VlcVideoFit.contain => VlcVideoFit.cover,
      VlcVideoFit.cover => VlcVideoFit.fill,
      _ => VlcVideoFit.contain,
    };
    widget.onFitChanged?.call(next);
    widget.chrome.poke();
  }

  Future<void> _pickSpeed() async {
    final current = widget.controller.value.playbackSpeed;
    final picked = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => _SpeedSheet(current: current),
    );
    if (picked == null) return;
    await widget.controller.setPlaybackSpeed(picked);
    widget.chrome.poke();
  }

  Future<void> _pickVolume() async {
    final current = widget.controller.value.volume;
    final picked = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => _VolumeSheet(current: current),
    );
    if (picked == null) return;
    await widget.controller.setVolume(picked);
    widget.chrome.poke();
  }

  // -- skip --------------------------------------------------------------------

  void _onSkipSegment(SkipSegment segment) {
    if (segment.type == SkipType.outro && widget.onSkipOutro != null) {
      widget.onSkipOutro!.call();
      return;
    }
    unawaited(
      widget.controller.seekTo(
        Duration(milliseconds: (segment.endTime * 1000).round()),
      ),
    );
    widget.chrome.poke();
  }

  // -- build -------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    final doubleTapEnabled = settings.doubleTapEnabled;

    return ValueListenableBuilder<bool>(
      valueListenable: widget.chrome,
      builder: (context, chromeVisible, _) {
        final lockedNotifier = widget.locked;
        if (lockedNotifier == null) {
          return _buildStack(
            context,
            chromeVisible: chromeVisible,
            isLocked: false,
            doubleTapEnabled: doubleTapEnabled,
          );
        }
        return ValueListenableBuilder<bool>(
          valueListenable: lockedNotifier,
          builder: (context, isLocked, _) => _buildStack(
            context,
            chromeVisible: chromeVisible,
            isLocked: isLocked,
            doubleTapEnabled: doubleTapEnabled,
          ),
        );
      },
    );
  }

  Widget _buildStack(
    BuildContext context, {
    required bool chromeVisible,
    required bool isLocked,
    required bool doubleTapEnabled,
  }) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // The gesture layer: tap toggles the chrome, double-tap seeks
        // on the outer thirds and toggles play/pause in the centre
        // third, long-press (right half) holds 2x, pinch zooms,
        // vertical swipe rails volume (right) / brightness (left).
        // Locked, only a bare tap and the outer-third double-tap seek
        // survive — the tap asks to see the unlock chip, the double-tap
        // skips ±10s; nothing else answers a finger.
        if (isLocked)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.chrome.poke,
            onDoubleTapDown: doubleTapEnabled
                ? (d) => _doubleTapLocked(d.localPosition.dx)
                : null,
          )
        else
          // The Listener lands the pan's anchor (see [_onPointerDown]):
          // it reports the pointer's down immediately, before any arena
          // resolution, which no recognizer on this detector can do.
          Listener(
            onPointerDown: _onPointerDown,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: widget.chrome.toggle,
              onDoubleTapDown: doubleTapEnabled
                  ? (d) => _doubleTap(d.localPosition.dx)
                  : null,
              onScaleStart: _onScaleStart,
              onScaleUpdate: _onScaleUpdate,
              onScaleEnd: _onScaleEnd,
              onLongPressStart: (d) => _startSpeedBoost(d.localPosition.dx),
              onLongPressEnd: (_) => _endSpeedBoost(),
              onLongPressCancel: _endSpeedBoost,
            ),
          ),

        // The volume / brightness rail, while a vertical swipe is down,
        // then fading on its own clock. Over the video, chrome or not.
        TransientOverlay<_GoldenRailData>(
          value: _rail,
          builder: (context, data) => _GoldenRail(data: data),
        ),

        // Buffering spinner, over the video, chrome or not.
        ValueListenableBuilder<VlcPlayerValue>(
          valueListenable: widget.controller,
          builder: (context, value, _) {
            if (!value.isStalled) return const SizedBox.shrink();
            return const Center(
              child: SizedBox(
                width: 44,
                height: 44,
                child: CircularProgressIndicator(
                  color: GoldenPlayerColors.gold,
                  strokeWidth: 3,
                ),
              ),
            );
          },
        ),

        // The centre play/pause flash, briefly after a centre
        // double-tap. Same dark translucent circle as the centre button.
        AnimatedOpacity(
          opacity: _centerFlashIcon == null ? 0.0 : 1.0,
          duration: GoldenPlayerMotion.fast,
          child: _centerFlashIcon == null
              ? const SizedBox.shrink()
              : Center(
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _centerFlashIcon,
                      size: 36,
                      color: GoldenPlayerColors.textPrimary,
                    ),
                  ),
                ),
        ),

        // Top + bottom chrome, fading together in 250 ms.
        AnimatedOpacity(
          opacity: chromeVisible && !isLocked ? 1.0 : 0.0,
          duration: GoldenPlayerMotion.normal,
          child: IgnorePointer(
            ignoring: !chromeVisible || isLocked,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // Top gradient + bar.
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    decoration: const BoxDecoration(
                      gradient: GoldenPlayerColors.topScrim,
                    ),
                    child: SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
                        child: _TopBar(
                          title: widget.title,
                          episodeLine: widget.episodeLine,
                          subtitle: widget.subtitle,
                          onBack: widget.onBack,
                          hasSubtitles: widget.hasSubtitles,
                          isSeries: _isSeries,
                          onOpenSubtitleStyle: () => _openDrawer(
                            _GoldenDrawerKind.subtitleStyle,
                          ),
                          onOpenEpisodes: () =>
                              _openDrawer(_GoldenDrawerKind.episodes),
                          onOpenAudioSources: () => _openDrawer(
                            _GoldenDrawerKind.audio,
                          ),
                          onOpenSources: () =>
                              _openDrawer(_GoldenDrawerKind.sources),
                          onPickSpeed: _pickSpeed,
                          onCycleFit: _cycleFit,
                          onRotate: widget.onRotate,
                          // Same gate as the stock chrome: the button
                          // renders only when the screen offers PiP and
                          // the `showPip` setting is on.
                          onEnterPip:
                              widget.onEnterPip != null &&
                                  widget.settings.value.showPip
                              ? widget.onEnterPip
                              : null,
                        ),
                      ),
                    ),
                  ),
                ),
                // Centre transport + bottom bar (live values).
                ValueListenableBuilder<VlcPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    return Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        // Centre: −10 s, play/pause, +10 s.
                        if (!_boosting)
                          Center(
                            child: _CentreTransport(
                              isPlaying: value.isPlaying,
                              onTogglePlay: _togglePlay,
                              onRewind: () => _seekBy(-_kGoldenSeekStep),
                              onForward: () => _seekBy(_kGoldenSeekStep),
                            ),
                          ),
                        // Bottom gradient + bar.
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            decoration: const BoxDecoration(
                              gradient: GoldenPlayerColors.bottomScrim,
                            ),
                            child: SafeArea(
                              top: false,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  28,
                                  12,
                                  10,
                                ),
                                child: _BottomBar(
                                  controller: widget.controller,
                                  bufferedFraction:
                                      widget.bufferedFraction,
                                  isLive: widget.isLive,
                                  seeking: _seeking,
                                  seekPreview: _seekPreview,
                                  onSeekStart: (_) {
                                    setState(() => _seeking = true);
                                    widget.chrome.poke(hold: true);
                                  },
                                  onSeekUpdate: (target) {
                                    setState(() => _seekPreview = target);
                                  },
                                  onSeekEnd: (target) async {
                                    await widget.controller.seekTo(target);
                                    if (mounted) {
                                      setState(() => _seeking = false);
                                    }
                                    widget.chrome.release();
                                  },
                                  onPreviousEpisode:
                                      widget.onPreviousEpisode,
                                  onNextEpisode: widget.onNextEpisode,
                                  hasSubtitles: widget.hasSubtitles,
                                  onOpenSubtitleStyle: () => _openDrawer(
                                    _GoldenDrawerKind.subtitleStyle,
                                  ),
                                  onOpenAudioSources: () => _openDrawer(
                                    _GoldenDrawerKind.audio,
                                  ),
                                  onOpenSources: () =>
                                      _openDrawer(_GoldenDrawerKind.sources),
                                  onPickVolume: _pickVolume,
                                  // While a 2x hold is down, the chip shows
                                  // the speed the hold will restore (1x) —
                                  // never "2x": the viewer asked for no
                                  // "2x" written anywhere during a hold.
                                  speed: _speedBeforeBoost ??
                                      value.playbackSpeed,
                                  onPickSpeed: _pickSpeed,
                                  locked: _locked,
                                  lockAvailable: widget.lockAvailable,
                                  onToggleLock: () {
                                    widget.locked?.value = !(_locked);
                                    widget.chrome.poke();
                                  },
                                  fit: widget.fit,
                                  onCycleFit: _cycleFit,
                                  onRotate: widget.onRotate,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                // Skip intro/outro chip, above the bottom bar.
                ValueListenableBuilder<VlcPlayerValue>(
                  valueListenable: widget.controller,
                  builder: (context, value, _) {
                    final segment = segmentAt(
                      widget.skipSegments,
                      value.position,
                    );
                    if (segment == null) return const SizedBox.shrink();
                    final isOutro = segment.type == SkipType.outro;
                    final label = isOutro
                        ? 'Next Episode'
                        : 'Skip Intro';
                    return Positioned(
                      right: 16,
                      bottom: 108,
                      child: GoldenPill(
                        filled: true,
                        onTap: () => _onSkipSegment(segment),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text(label),
                            const SizedBox(width: 4),
                            const Icon(
                              Icons.skip_next_rounded,
                              size: 16,
                              color: Colors.black,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),

        // Locked: the unlock chip, the only control on screen.
        if (isLocked)
          Center(
            child: AnimatedOpacity(
              opacity: chromeVisible ? 1.0 : 0.0,
              duration: GoldenPlayerMotion.normal,
              child: GoldenPill(
                filled: true,
                onTap: () {
                  widget.locked?.value = false;
                  widget.chrome.poke();
                },
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.lock_open_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Tap to unlock'),
                  ],
                ),
              ),
            ),
          ),

        // A drawer over the video (280 ms both ways), in two parts so
        // they never move together: the scrim FADES in place — a scrim
        // that slid with the panel read as a dark curtain sweeping
        // right-to-left across the video — and only the panel SLIDES in
        // from the right. The scrim is keyed by open/closed, so switching
        // drawers keeps it steady instead of fading it out and back in.
        AnimatedSwitcher(
          duration: GoldenPlayerMotion.drawer,
          switchInCurve: GoldenPlayerMotion.curve,
          switchOutCurve: GoldenPlayerMotion.curve,
          transitionBuilder: (child, animation) =>
              FadeTransition(opacity: animation, child: child),
          child: _drawer == _GoldenDrawerKind.none
              ? const SizedBox.shrink(key: ValueKey<String>('scrim-none'))
              : GoldenDrawerScrim(
                  key: const ValueKey<String>('scrim-open'),
                  onClose: _closeDrawer,
                ),
        ),
        AnimatedSwitcher(
          duration: GoldenPlayerMotion.drawer,
          switchInCurve: GoldenPlayerMotion.curve,
          switchOutCurve: GoldenPlayerMotion.curve,
          transitionBuilder: (child, animation) {
            final offset =
                Tween<Offset>(
                  begin: const Offset(1, 0),
                  end: Offset.zero,
                ).animate(animation);
            return SlideTransition(position: offset, child: child);
          },
          child: _drawer == _GoldenDrawerKind.none
              ? const SizedBox.shrink(key: ValueKey<String>('none'))
              : _buildDrawer(context),
        ),
      ],
    );
  }

  Widget _buildDrawer(BuildContext context) {
    final kind = _drawer;
    final data = widget.panelData.value;
    switch (kind) {
      case _GoldenDrawerKind.episodes:
        return GoldenEpisodesDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          episodes: data.episodes,
          currentEpisode: data.currentEpisode,
          onPick: (episode) {
            _closeDrawer();
            widget.onPickEpisode(episode);
          },
          onClose: _closeDrawer,
          episodeProgress: widget.episodeProgress,
          episodeDuration: widget.episodeDuration,
        );
      case _GoldenDrawerKind.subtitleStyle:
        return GoldenSubtitleStyleDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          settings: widget.settings,
          notifier: widget.settingsNotifier,
          controller: widget.controller,
          onClose: _closeDrawer,
          onSubtitlePicked: widget.onSubtitlePicked,
          subtitleTarget: widget.panelData.value.subtitleTarget,
        );
      case _GoldenDrawerKind.audio:
        return GoldenAudioDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          controller: widget.controller,
          onClose: _closeDrawer,
          onAudioPicked: widget.onAudioPicked,
        );
      case _GoldenDrawerKind.sources:
        return GoldenSourcesDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          panelData: widget.panelData,
          onClose: _closeDrawer,
          onPickSource: (index) {
            _closeDrawer();
            widget.onPickSource(index);
          },
        );
      case _GoldenDrawerKind.none:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    // A drawer left open holds the chrome; a dispose must not leave the
    // hold standing on the screen's controller.
    if (_drawer != _GoldenDrawerKind.none) {
      widget.chrome.release();
    }
    // A 2x hold left down restores its speed without a setState — the
    // widget is going away, so there is nothing to repaint.
    final previous = _speedBeforeBoost;
    if (previous != null) {
      _speedBeforeBoost = null;
      unawaited(widget.controller.setPlaybackSpeed(previous));
    }
    _centerFlashTimer?.cancel();
    // Application brightness is a process-wide override, so leaving the
    // player gives the screen back to the system's level.
    if (_brightnessOverridden) _brightnessControl.reset();
    _rail.dispose();
    super.dispose();
  }
}

/// What a vertical swipe's rail shows: the icon, the level 0..1 of the
/// track, the text above it (e.g. `70%`), and which edge it sits on.
class _GoldenRailData {
  const _GoldenRailData({
    required this.icon,
    required this.value,
    required this.label,
    required this.onLeft,
  });

  final IconData icon;
  final double value;
  final String label;
  final bool onLeft;
}

/// The vertical volume / brightness rail, shown while a swipe is down.
///
/// Kept deliberately dumb: it renders a value someone else owns. The
/// gesture that changes it, the engine call and the timer that hides it
/// all live in the controls, so this cannot become a second owner of
/// player state. No pill, no border: just the gold bar floating straight
/// over the video, the number on top and the icon at the bottom — the
/// viewer asked for the dark background to go. Both rails share this
/// widget, so volume (right) and brightness (left) match.
class _GoldenRail extends StatelessWidget {
  const _GoldenRail({required this.data});

  final _GoldenRailData data;

  static const double _trackHeight = 132;

  @override
  Widget build(BuildContext context) {
    final filled = data.value.clamp(0.0, 1.0);
    // The device's safe-area inset on this side: 59pt on the Dynamic
    // Island side of an iPhone 15 Pro Max in landscape, 0 where there is
    // no cutout. The fixed 24 alone put the rail under the island.
    final safe = MediaQuery.paddingOf(context);
    return Align(
      alignment: data.onLeft ? Alignment.centerLeft : Alignment.centerRight,
      child: Padding(
        // 24 inside the chrome's side inset, plus the safe area — so the
        // rail sits clear of a notch or camera cutout on either side, on
        // every device, with no hardcoded phone value. Which side the
        // island is on flips with rotation, and the padding follows it.
        padding: EdgeInsets.only(
          left: data.onLeft ? 24 + safe.left : 0,
          right: data.onLeft ? 0 : 24 + safe.right,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data.label,
              style: const TextStyle(
                color: GoldenPlayerColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 6,
              height: _trackHeight,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: Stack(
                  children: [
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xFF3A352E)),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: _trackHeight * filled,
                      child: const ColoredBox(
                        color: GoldenPlayerColors.gold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Icon(
              data.icon,
              color: GoldenPlayerColors.goldHighlight,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// The top bar: Back, title + lines, subtitle style, Episodes, More.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    required this.episodeLine,
    required this.subtitle,
    required this.onBack,
    required this.hasSubtitles,
    required this.isSeries,
    required this.onOpenSubtitleStyle,
    required this.onOpenEpisodes,
    required this.onOpenAudioSources,
    required this.onOpenSources,
    required this.onPickSpeed,
    required this.onCycleFit,
    required this.onRotate,
    required this.onEnterPip,
  });

  final String title;
  final String? episodeLine;
  final String? subtitle;
  final VoidCallback? onBack;
  final ValueListenable<bool>? hasSubtitles;
  final bool isSeries;
  final VoidCallback onOpenSubtitleStyle;
  final VoidCallback onOpenEpisodes;
  final VoidCallback onOpenAudioSources;
  final VoidCallback onOpenSources;
  final VoidCallback onPickSpeed;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  /// Non-null when the screen offers PiP (Android) and the `showPip`
  /// setting is on; the button is absent otherwise.
  final VoidCallback? onEnterPip;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GoldenIconButton(
          icon: Icons.arrow_back_rounded,
          onPressed: onBack,
          tooltip: 'Back',
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              if (episodeLine != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  episodeLine!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ] else if (subtitle != null) ...<Widget>[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: GoldenPlayerColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        if (isSeries)
          GoldenIconButton(
            icon: Icons.list_rounded,
            onPressed: onOpenEpisodes,
            tooltip: 'Episodes',
          ),
        if (isSeries) const SizedBox(width: 8),
        // Picture-in-picture (Android only, `showPip` on): the same
        // icon and gate as the stock chrome.
        if (onEnterPip != null)
          GoldenIconButton(
            icon: Icons.picture_in_picture_alt_rounded,
            onPressed: onEnterPip,
            tooltip: 'Picture-in-picture',
          ),
        if (onEnterPip != null) const SizedBox(width: 8),
      ],
    );
  }
}

/// The centre transport: −10 s, play/pause (gold circle), +10 s.
class _CentreTransport extends StatelessWidget {
  const _CentreTransport({
    required this.isPlaying,
    required this.onTogglePlay,
    required this.onRewind,
    required this.onForward,
  });

  final bool isPlaying;
  final VoidCallback onTogglePlay;
  final VoidCallback onRewind;
  final VoidCallback onForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _CentreSeekButton(
          icon: Icons.replay_10_rounded,
          onPressed: onRewind,
        ),
        const SizedBox(width: 28),
        // The play/pause button, the same dark translucent circle as the
        // ±10 s seek buttons — no gold fill, so it reads as one row.
        SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: Colors.black.withValues(alpha: 0.45),
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTogglePlay,
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                size: 36,
                color: GoldenPlayerColors.textPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 28),
        _CentreSeekButton(
          icon: Icons.forward_10_rounded,
          onPressed: onForward,
        ),
      ],
    );
  }
}

class _CentreSeekButton extends StatelessWidget {
  const _CentreSeekButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 52,
      height: 52,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Icon(
            icon,
            size: 28,
            color: GoldenPlayerColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// The bottom bar: golden seekbar + times, then the utility row.
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.controller,
    required this.bufferedFraction,
    required this.isLive,
    required this.seeking,
    required this.seekPreview,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onPreviousEpisode,
    required this.onNextEpisode,
    required this.hasSubtitles,
    required this.onOpenSubtitleStyle,
    required this.onOpenAudioSources,
    required this.onOpenSources,
    required this.onPickVolume,
    required this.speed,
    required this.onPickSpeed,
    required this.locked,
    required this.lockAvailable,
    required this.onToggleLock,
    required this.fit,
    required this.onCycleFit,
    required this.onRotate,
  });

  final VlcPlayerController controller;
  final ValueListenable<double>? bufferedFraction;
  final bool isLive;
  final bool seeking;
  final Duration seekPreview;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;
  final VoidCallback? onPreviousEpisode;
  final VoidCallback? onNextEpisode;
  final ValueListenable<bool>? hasSubtitles;
  final VoidCallback onOpenSubtitleStyle;
  final VoidCallback onOpenAudioSources;
  final VoidCallback onOpenSources;
  final VoidCallback onPickVolume;
  final double speed;
  final VoidCallback onPickSpeed;
  final bool locked;
  final bool lockAvailable;
  final VoidCallback onToggleLock;
  final VlcVideoFit fit;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    final duration = value.duration;
    final canSeek =
        !isLive && value.isSeekable && duration > Duration.zero;
    final position = seeking ? seekPreview : value.position;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // Seekbar + times.
        Row(
          children: <Widget>[
            SizedBox(
              width: 52,
              child: Text(
                goldenFormatTime(position),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: canSeek
                  ? _GoldenSeekBar(
                      controller: controller,
                      bufferedFraction: bufferedFraction,
                      position: position,
                      duration: duration,
                      onSeekStart: onSeekStart,
                      onSeekUpdate: onSeekUpdate,
                      onSeekEnd: onSeekEnd,
                    )
                  : const _LiveBadge(),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: Text(
                goldenFormatTime(duration),
                style: const TextStyle(
                  color: GoldenPlayerColors.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Utility row.
        Row(
          children: <Widget>[
            if (onPreviousEpisode != null)
              GoldenIconButton(
                icon: Icons.skip_previous_rounded,
                onPressed: onPreviousEpisode,
                tooltip: 'Previous episode',
                size: 38,
              ),
            if (onNextEpisode != null) ...<Widget>[
              const SizedBox(width: 6),
              GoldenIconButton(
                icon: Icons.skip_next_rounded,
                onPressed: onNextEpisode,
                tooltip: 'Next episode',
                size: 38,
              ),
            ],
            const Spacer(),
            _SubtitleButton(
              hasSubtitles: hasSubtitles,
              onPressed: onOpenSubtitleStyle,
            ),
            const SizedBox(width: 6),
            // Audio, straight from the bottom bar — the same drawer the
            // top-right More menu opens. Sources sits beside it, as its
            // own button and its own drawer.
            GoldenIconButton(
              icon: Icons.audiotrack_rounded,
              onPressed: onOpenAudioSources,
              tooltip: 'Audio',
              size: 38,
            ),
            const SizedBox(width: 6),
            GoldenIconButton(
              icon: Icons.dns_rounded,
              onPressed: onOpenSources,
              tooltip: 'Sources',
              size: 38,
            ),
            const SizedBox(width: 6),
            GoldenIconButton(
              icon: Icons.volume_up_rounded,
              onPressed: onPickVolume,
              tooltip: 'Volume',
              size: 38,
            ),
            const SizedBox(width: 6),
            GoldenPill(
              onTap: onPickSpeed,
              child: Text('${_formatSpeed(speed)}x'),
            ),
            const SizedBox(width: 6),
            if (lockAvailable)
              GoldenIconButton(
                icon: locked
                    ? Icons.lock_rounded
                    : Icons.lock_open_rounded,
                onPressed: onToggleLock,
                active: locked,
                tooltip: locked ? 'Unlock' : 'Lock',
                size: 38,
              ),
            if (lockAvailable) const SizedBox(width: 6),
            GoldenIconButton(
              icon: _fitIcon(fit),
              onPressed: onCycleFit,
              tooltip: 'Aspect ratio',
              size: 38,
            ),
          ],
        ),
      ],
    );
  }

  static String _formatSpeed(double speed) {
    final text = speed.toStringAsFixed(2);
    return text.endsWith('00')
        ? text.substring(0, text.length - 3)
        : (text.endsWith('0') ? text.substring(0, text.length - 1) : text);
  }

  static IconData _fitIcon(VlcVideoFit fit) => switch (fit) {
    VlcVideoFit.cover => Icons.crop_rounded,
    VlcVideoFit.fill => Icons.fit_screen_rounded,
    _ => Icons.aspect_ratio_rounded,
  };
}

class _SubtitleButton extends StatelessWidget {
  const _SubtitleButton({required this.hasSubtitles, required this.onPressed});

  final ValueListenable<bool>? hasSubtitles;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final hasSubs = hasSubtitles;
    if (hasSubs == null) {
      return GoldenIconButton(
        icon: Icons.closed_caption_outlined,
        onPressed: onPressed,
        tooltip: 'Subtitles',
        size: 38,
      );
    }
    return ValueListenableBuilder<bool>(
      valueListenable: hasSubs,
      builder: (context, has, _) => has
          ? GoldenIconButton(
              icon: Icons.closed_caption_outlined,
              onPressed: onPressed,
              tooltip: 'Subtitles',
              size: 38,
            )
          : const SizedBox.shrink(),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: <Widget>[
        Icon(Icons.circle, size: 8, color: Color(0xFFEF5350)),
        SizedBox(width: 6),
        Text(
          'LIVE',
          style: TextStyle(
            color: GoldenPlayerColors.textPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

/// The thin golden seekbar: buffered band behind a gold Slider.
class _GoldenSeekBar extends StatelessWidget {
  const _GoldenSeekBar({
    required this.controller,
    required this.bufferedFraction,
    required this.position,
    required this.duration,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
  });

  final VlcPlayerController controller;
  final ValueListenable<double>? bufferedFraction;
  final Duration position;
  final Duration duration;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds.toDouble();
    final valueMs = position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    final buffered = bufferedFraction;
    return SizedBox(
      height: 28,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // Buffered band, under the slider's track. White at 0.5, a
          // touch taller than the 4 px track, so how far ahead the video
          // has buffered reads at a glance against the 0.18 track — the
          // old 0.25 was nearly the same grey as the track itself.
          if (buffered != null)
            ValueListenableBuilder<double>(
              valueListenable: buffered,
              builder: (context, fraction, _) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction.clamp(0.0, 1.0),
                    child: Container(
                      height: 5,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(2.5),
                      ),
                    ),
                  ),
                );
              },
            ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              activeTrackColor: GoldenPlayerColors.gold,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
              thumbColor: GoldenPlayerColors.goldHighlight,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 7,
              ),
              overlayColor: GoldenPlayerColors.gold.withValues(
                alpha: 0.2,
              ),
              overlayShape: const RoundSliderOverlayShape(
                overlayRadius: 14,
              ),
            ),
            child: Slider(
              value: totalMs > 0 ? valueMs : 0,
              min: 0,
              max: totalMs > 0 ? totalMs : 1,
              onChangeStart: onSeekStart,
              onChanged: (v) => onSeekUpdate(
                Duration(milliseconds: v.round()),
              ),
              onChangeEnd: (v) =>
                  onSeekEnd(Duration(milliseconds: v.round())),
            ),
          ),
        ],
      ),
    );
  }
}

/// The speed picker: a gold bottom sheet with speed chips.
class _SpeedSheet extends StatelessWidget {
  const _SpeedSheet({required this.current});

  final double current;

  static const List<double> _speeds = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GoldenPlayerColors.backgroundSecondary,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(GoldenPlayerRadii.drawer),
          topRight: Radius.circular(GoldenPlayerRadii.drawer),
        ),
        border: Border(top: GoldenPlayerColors.drawerBorder),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'Playback speed',
                style: TextStyle(
                  color: GoldenPlayerColors.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final speed in _speeds)
                    GoldenPill(
                      filled: (speed - current).abs() < 0.01,
                      onTap: () => Navigator.of(context).pop(speed),
                      child: Text('${_BottomBar._formatSpeed(speed)}x'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The volume picker: a gold bottom sheet with a slider.
class _VolumeSheet extends StatefulWidget {
  const _VolumeSheet({required this.current});

  final int current;

  @override
  State<_VolumeSheet> createState() => _VolumeSheetState();
}

class _VolumeSheetState extends State<_VolumeSheet> {
  late double _volume;

  @override
  void initState() {
    super.initState();
    _volume = widget.current.clamp(0, 100).toDouble();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: GoldenPlayerColors.backgroundSecondary,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(GoldenPlayerRadii.drawer),
          topRight: Radius.circular(GoldenPlayerRadii.drawer),
        ),
        border: Border(top: GoldenPlayerColors.drawerBorder),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Text(
                    'Volume',
                    style: TextStyle(
                      color: GoldenPlayerColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${_volume.round()}%',
                    style: const TextStyle(
                      color: GoldenPlayerColors.goldHighlight,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: GoldenPlayerColors.gold,
                  inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                  thumbColor: GoldenPlayerColors.goldHighlight,
                  overlayColor: GoldenPlayerColors.gold.withValues(
                    alpha: 0.2,
                  ),
                ),
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  onChanged: (v) => setState(() => _volume = v),
                  onChangeEnd: (v) =>
                      Navigator.of(context).pop(v.round()),
                ),
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => Navigator.of(context).pop(0),
                child: const Text(
                  'Mute',
                  style: TextStyle(
                    color: GoldenPlayerColors.goldHighlight,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
