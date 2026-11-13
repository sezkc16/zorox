/// The mpv player's subtitle look, shared by the player screen and its CC
/// sheet so the Style tab's preview and the on-video caption can never
/// disagree.
///
/// The mpv engine (media_kit) draws subtitles itself through
/// [SubtitleViewConfiguration], so — unlike libVLC — the style is a plain
/// Flutter [TextStyle] plus a bottom padding, and it applies at once while
/// the video plays: changing a setting rebuilds the configuration, no
/// re-open needed.
///
/// The numbers come from the stock [PlayerSettings] the VLC player already
/// persists, so the two players share one saved style:
///
///   * size — the stock `subtitleSize` (default 22). The Style tab offers
///     S/M/L/XL steps of it;
///   * text colour — the stock `subtitleColor`;
///   * background — the stock `subtitleBackgroundColor` + opacity. "None" is
///     opacity 0, "semi" 0.5, "solid" 1.0, all on black;
///   * edge — the stock `subtitleOutline` for none/outline, and the mpv-only
///     `subtitleShadow` flag for a drop shadow (the stock outline enum has
///     no shadow; libVLC ignores the flag);
///   * position — the stock `subtitleRaise`, a share of the picture's height
///     the lines are lifted from the bottom. The Style tab's slider and its
///     +5/+10/−5/−10 nudge buttons both write it, through
///     `setSubtitleRaise`, which holds it to the stock range [0, 0.2].
library;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../settings/presentation/player_settings_provider.dart';
import '../../domain/subtitle_style.dart';

/// The Style tab's size steps: S/M/L/XL, as stock font sizes.
const Map<String, double> kMpvSubtitleSizes = <String, double>{
  'S': 16,
  'M': 20,
  'L': 24,
  'XL': 28,
};

/// The Style tab's text colours, in order.
const List<(String label, int value)> kMpvSubtitleColors =
    <(String, int)>[
      ('White', 0xFFFFFFFF),
      ('Yellow', 0xFFFFFF00),
      ('Cyan', 0xFF00FFFF),
      ('Green', 0xFF00FF00),
    ];

/// The Style tab's background choices: label + the opacity written with
/// black. "None" is opacity 0 — no box at all.
const List<(String label, double opacity)> kMpvSubtitleBackgrounds =
    <(String, double)>[
      ('None', 0.0),
      ('Semi', 0.5),
      ('Solid', 1.0),
    ];

/// The Style tab's edge choices.
const List<String> kMpvSubtitleEdges = <String>['None', 'Outline', 'Shadow'];

/// The nudge buttons' steps, in lift units: +5/−5 moves 0.05, +10/−10 moves
/// 0.1 — the stock raise values themselves, so a nudge always lands on one.
const double kMpvRaiseNudgeSmall = 0.05;
const double kMpvRaiseNudgeLarge = 0.1;

/// The bottom padding the caption sits at when the bars are hidden, and when
/// they are up — the v14 low position, lifted above the controls bar while
/// the bars are up. The raise is added on top of whichever applies.
const double kMpvSubtitlePaddingHidden = 40;
const double kMpvSubtitlePaddingControls = 116;

/// The text style the on-video caption (and the Style tab's preview line)
/// are drawn in, from the saved settings.
TextStyle mpvSubtitleTextStyle(PlayerSettings settings) {
  final background = Color(
    settings.subtitleBackgroundColor,
  ).withValues(alpha: settings.subtitleBackgroundOpacity.clamp(0.0, 1.0));
  final text = Color(
    settings.subtitleColor,
  ).withValues(alpha: settings.subtitleTextOpacity.clamp(0.0, 1.0));
  return TextStyle(
    height: 1.4,
    fontSize: settings.subtitleSize.clamp(10.0, 80.0),
    // The Font setting (Default / Netflix / Serif / Monospace): the stock
    // VLC path applies it at creation, and mpv must too — otherwise the
    // setting silently does nothing on the mpv caption.
    fontFamily: subtitleFontFamily(settings.subtitleFont),
    color: text,
    fontWeight: settings.subtitleBold ? FontWeight.bold : FontWeight.w500,
    // Opacity 0 is no box at all, whatever the colour says — null, not a
    // transparent colour, is how the view is told to draw none.
    backgroundColor: background.a == 0 ? null : background,
    shadows: _mpvSubtitleShadows(settings),
  );
}

/// The edge, as Flutter shadows: none draws nothing, an outline is drawn as
/// shadows around each glyph, a drop shadow as one offset shadow.
List<Shadow>? _mpvSubtitleShadows(PlayerSettings settings) {
  if (settings.subtitleShadow) {
    return const <Shadow>[
      Shadow(
        offset: Offset(2, 2),
        blurRadius: 3,
        color: Color(0xcc000000),
      ),
    ];
  }
  switch (settings.subtitleOutline) {
    case SubtitleOutline.none:
      return null;
    case SubtitleOutline.thin:
    case SubtitleOutline.normal:
    case SubtitleOutline.thick:
      final spread = settings.subtitleOutline == SubtitleOutline.thick
          ? 2.0
          : 1.5;
      return <Shadow>[
        for (final dx in <double>[-spread, 0.0, spread])
          for (final dy in <double>[-spread, 0.0, spread])
            if (dx != 0 || dy != 0)
              Shadow(
                offset: Offset(dx, dy),
                blurRadius: 0,
                color: Colors.black,
              ),
      ];
  }
}

/// The whole subtitle configuration for the mpv video view: the text style
/// above, centred, lifted by the saved raise.
///
/// [screenHeight] is the landscape screen height, the frame the raise is a
/// share of. The lift is added on top of the base padding, so the caption
/// never drops under the controls bar.
SubtitleViewConfiguration mpvSubtitleViewConfiguration(
  PlayerSettings settings, {
  required double screenHeight,
  required bool controlsVisible,
}) {
  final liftPx = settings.subtitleRaise.clamp(0.0, 0.5) * screenHeight;
  final base = controlsVisible
      ? kMpvSubtitlePaddingControls
      : kMpvSubtitlePaddingHidden;
  return SubtitleViewConfiguration(
    style: mpvSubtitleTextStyle(settings),
    textAlign: TextAlign.center,
    // media_kit's SubtitleView scales text down by sqrt(area / 1920x1080)
    // when no textScaler is given — on a phone in landscape that is ~0.44,
    // so a 22pt caption renders at ~10pt. 1.0 renders the configured size
    // as-is, matching the VLC player's look.
    textScaler: const TextScaler.linear(1.0),
    padding: EdgeInsets.fromLTRB(16, 0, 16, base + liftPx),
  );
}

/// Which size step [size] is nearest to, for the Style tab's selected chip.
String mpvSizeStepFor(double size) {
  var best = 'M';
  var bestDistance = double.infinity;
  for (final entry in kMpvSubtitleSizes.entries) {
    final distance = (entry.value - size).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = entry.key;
    }
  }
  return best;
}

/// Which background choice [opacity] is nearest to, for the Style tab.
String mpvBackgroundFor(double opacity) {
  var best = 'Semi';
  var bestDistance = double.infinity;
  for (final entry in kMpvSubtitleBackgrounds) {
    final distance = (entry.$2 - opacity).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = entry.$1;
    }
  }
  return best;
}

/// Which edge choice the settings describe, for the Style tab.
String mpvEdgeFor(PlayerSettings settings) {
  if (settings.subtitleShadow) return 'Shadow';
  if (settings.subtitleOutline == SubtitleOutline.none) return 'None';
  return 'Outline';
}
