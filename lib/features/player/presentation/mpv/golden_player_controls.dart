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
///   * centre — Rewind 10 s, Play/Pause (gold circle), Forward 10 s;
///     while a right-side hold is down, the gold "▶▶ 2x" pill instead;
///   * bottom — golden seekbar with current/total time, then Previous,
///     Next (series), subtitle, volume, speed chip, lock, aspect, rotate.
///
/// Gestures (same as the stock chrome, restyled):
///   * single tap shows/hides the chrome (3 s auto-hide, owned by
///     [ChromeVisibilityController]);
///   * double-tap left/right seeks ∓10 s;
///   * long-press on the RIGHT half holds 2x until release (the saved
///     speed is restored exactly — 1.5x comes back as 1.5x);
///   * pinch zooms the picture (the screen's [videoScale]).
///
/// Everything is wired to the real engine through the adapter: no
/// placeholder buttons. No Cast button — mpv/media_kit has no cast in
/// this app, and a dead one is worse than none. No PiP — mpv renders
/// through a Metal texture. The drawers (Episodes, Subtitle Style,
/// Audio & Sources) slide in from the right over the video.
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
import '../vlc/chrome_visibility_controller.dart';
import '../vlc/panel/player_panel_data.dart';
import 'golden_episodes_drawer.dart';
import 'golden_options_drawer.dart';
import 'golden_player_theme.dart';
import 'golden_subtitle_style_drawer.dart';

/// The seek step for the ±10 s buttons and the double-tap, per the spec.
const Duration _kGoldenSeekStep = Duration(seconds: 10);

/// Which right-side drawer is open, if any.
enum _GoldenDrawerKind { none, episodes, subtitleStyle, audioSources }

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

  /// A seekbar drag in flight, and its preview target.
  bool _seeking = false;
  Duration _seekPreview = Duration.zero;

  /// Pinch state, for the zoom.
  bool _pinching = false;
  double _pinchStartScale = 1.0;

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

  void _doubleTapSeek(double dx) {
    final width = context.size?.width ?? 0;
    if (width <= 0) return;
    _seekBy(dx >= width / 2 ? _kGoldenSeekStep : -_kGoldenSeekStep);
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

  // -- pinch zoom -------------------------------------------------------------

  void _onScaleStart(ScaleStartDetails d) {
    if (d.pointerCount >= 2) {
      _pinching = true;
      _pinchStartScale = widget.videoScale?.value ?? 1.0;
      // A pinch is deliberate, not a hold: a 2x boost goes away with it.
      _endSpeedBoost();
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (!_pinching || d.pointerCount < 2) return;
    final notifier = widget.videoScale;
    if (notifier == null) return;
    final scale = (_pinchStartScale * d.scale).clamp(0.5, 3.0).toDouble();
    if (scale != notifier.value) notifier.value = scale;
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (!_pinching) return;
    _pinching = false;
    final notifier = widget.videoScale;
    if (notifier != null) {
      final settled = notifier.value.clamp(0.5, 3.0).toDouble();
      if (settled != notifier.value) notifier.value = settled;
    }
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
        // The gesture layer: tap toggles the chrome, double-tap seeks,
        // long-press (right half) holds 2x, pinch zooms. Locked, only a
        // bare tap survives — a request to see the unlock chip, never a
        // request to hide it.
        if (isLocked)
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.chrome.poke,
          )
        else
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.chrome.toggle,
            onDoubleTapDown: doubleTapEnabled
                ? (d) => _doubleTapSeek(d.localPosition.dx)
                : null,
            onScaleStart: _onScaleStart,
            onScaleUpdate: _onScaleUpdate,
            onScaleEnd: _onScaleEnd,
            onLongPressStart: (d) => _startSpeedBoost(d.localPosition.dx),
            onLongPressEnd: (_) => _endSpeedBoost(),
            onLongPressCancel: _endSpeedBoost,
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

        // The 2x pill + hint, while a hold is down (mockup: centre-right).
        AnimatedOpacity(
          opacity: _boosting ? 1.0 : 0.0,
          duration: GoldenPlayerMotion.fast,
          child: _boosting
              ? const Align(
                  alignment: Alignment(0.5, -0.15),
                  child: _TwoXIndicator(),
                )
              : const SizedBox.shrink(),
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
                            _GoldenDrawerKind.audioSources,
                          ),
                          onPickSpeed: _pickSpeed,
                          onCycleFit: _cycleFit,
                          onRotate: widget.onRotate,
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
                                  onPickVolume: _pickVolume,
                                  speed: value.playbackSpeed,
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

        // A drawer, sliding in from the right over the video (280 ms,
        // slide + fade both ways).
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
            return SlideTransition(
              position: offset,
              child: FadeTransition(
                opacity: animation,
                child: child,
              ),
            );
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
        );
      case _GoldenDrawerKind.audioSources:
        return GoldenAudioSourcesDrawer(
          key: ValueKey<_GoldenDrawerKind>(kind),
          controller: widget.controller,
          panelData: widget.panelData,
          onClose: _closeDrawer,
          onAudioPicked: widget.onAudioPicked,
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
    super.dispose();
  }
}

/// The gold "▶▶ 2x" pill + hint, shown while a right-side hold is down.
class _TwoXIndicator extends StatelessWidget {
  const _TwoXIndicator();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(GoldenPlayerRadii.pill),
            border: Border.all(
              color: GoldenPlayerColors.gold.withValues(alpha: 0.7),
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.fast_forward_rounded,
                color: GoldenPlayerColors.goldHighlight,
                size: 20,
              ),
              SizedBox(width: 4),
              Text(
                '2x',
                style: TextStyle(
                  color: GoldenPlayerColors.goldHighlight,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Hold right side for 2x speed',
          style: TextStyle(
            color: GoldenPlayerColors.textPrimary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 2),
        const Text(
          'Release to return to normal',
          style: TextStyle(
            color: GoldenPlayerColors.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
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
    required this.onPickSpeed,
    required this.onCycleFit,
    required this.onRotate,
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
  final VoidCallback onPickSpeed;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    final hasSubs = hasSubtitles;
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
        // Subtitle style (CC). Only where there is a subtitle to style.
        if (hasSubs == null)
          GoldenIconButton(
            icon: Icons.closed_caption_outlined,
            onPressed: onOpenSubtitleStyle,
            tooltip: 'Subtitles',
          )
        else
          ValueListenableBuilder<bool>(
            valueListenable: hasSubs,
            builder: (context, has, _) => has
                ? GoldenIconButton(
                    icon: Icons.closed_caption_outlined,
                    onPressed: onOpenSubtitleStyle,
                    tooltip: 'Subtitles',
                  )
                : const SizedBox.shrink(),
          ),
        const SizedBox(width: 8),
        if (isSeries)
          GoldenIconButton(
            icon: Icons.list_rounded,
            onPressed: onOpenEpisodes,
            tooltip: 'Episodes',
          ),
        if (isSeries) const SizedBox(width: 8),
        _MoreMenu(
          onOpenAudioSources: onOpenAudioSources,
          onOpenSubtitleStyle: onOpenSubtitleStyle,
          onPickSpeed: onPickSpeed,
          onCycleFit: onCycleFit,
          onRotate: onRotate,
        ),
      ],
    );
  }
}

/// The More menu: Audio & Sources, Subtitle style, Speed, Aspect, Rotate.
class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.onOpenAudioSources,
    required this.onOpenSubtitleStyle,
    required this.onPickSpeed,
    required this.onCycleFit,
    required this.onRotate,
  });

  final VoidCallback onOpenAudioSources;
  final VoidCallback onOpenSubtitleStyle;
  final VoidCallback onPickSpeed;
  final VoidCallback onCycleFit;
  final VoidCallback? onRotate;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      color: GoldenPlayerColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
        side: const BorderSide(color: GoldenPlayerColors.divider),
      ),
      onSelected: (choice) {
        switch (choice) {
          case 'audio':
            onOpenAudioSources();
          case 'subtitles':
            onOpenSubtitleStyle();
          case 'speed':
            onPickSpeed();
          case 'aspect':
            onCycleFit();
          case 'rotate':
            onRotate?.call();
        }
      },
      itemBuilder: (context) => <PopupMenuEntry<String>>[
        const PopupMenuItem<String>(
          value: 'audio',
          child: _MenuLabel(
            icon: Icons.audiotrack_rounded,
            text: 'Audio & Sources',
          ),
        ),
        const PopupMenuItem<String>(
          value: 'subtitles',
          child: _MenuLabel(
            icon: Icons.closed_caption_outlined,
            text: 'Subtitle style',
          ),
        ),
        const PopupMenuItem<String>(
          value: 'speed',
          child: _MenuLabel(
            icon: Icons.speed_rounded,
            text: 'Playback speed',
          ),
        ),
        const PopupMenuItem<String>(
          value: 'aspect',
          child: _MenuLabel(
            icon: Icons.aspect_ratio_rounded,
            text: 'Aspect ratio',
          ),
        ),
        if (onRotate != null)
          const PopupMenuItem<String>(
            value: 'rotate',
            child: _MenuLabel(
              icon: Icons.screen_rotation_rounded,
              text: 'Rotate',
            ),
          ),
      ],
      child: const GoldenIconButton(
        icon: Icons.more_vert_rounded,
        onPressed: null,
        tooltip: 'More',
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  const _MenuLabel({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 18, color: GoldenPlayerColors.gold),
        const SizedBox(width: 10),
        Text(
          text,
          style: const TextStyle(color: GoldenPlayerColors.textPrimary),
        ),
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
        SizedBox(
          width: 72,
          height: 72,
          child: Material(
            color: Colors.transparent,
            child: Ink(
              decoration: const BoxDecoration(
                gradient: GoldenPlayerColors.goldGradient,
                shape: BoxShape.circle,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 16,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onTogglePlay,
                child: Icon(
                  isPlaying
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  size: 36,
                  color: Colors.black,
                ),
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
            const SizedBox(width: 6),
            if (onRotate != null)
              GoldenIconButton(
                icon: Icons.fullscreen_rounded,
                onPressed: onRotate,
                tooltip: 'Rotate',
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
          // Buffered band, under the slider's track.
          if (buffered != null)
            ValueListenableBuilder<double>(
              valueListenable: buffered,
              builder: (context, fraction, _) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction.clamp(0.0, 1.0),
                    child: Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
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
