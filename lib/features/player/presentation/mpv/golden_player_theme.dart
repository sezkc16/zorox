/// Design tokens for the Premium Golden MPV player.
///
/// Black + champagne-gold, Netflix-inspired. The mockup the user sent
/// ("CineStream — Premium Movie & Series Player") is the layout/style
/// reference; the ZoroX name and branding stay, only the look is gold.
///
/// Tokens (from the spec):
///   * primary background #080808, secondary #141210, surface #1C1915
///   * primary gold #D4AF37, highlight gold #F5D78E,
///     gold gradient #B8862B → #F5D78E
///   * primary text #FFFFFF, secondary text #AAAAAA, divider #403424
library;

import 'package:flutter/material.dart';

/// The golden player's palette.
abstract final class GoldenPlayerColors {
  static const Color background = Color(0xFF080808);
  static const Color backgroundSecondary = Color(0xFF141210);
  static const Color surface = Color(0xFF1C1915);
  static const Color gold = Color(0xFFD4AF37);
  static const Color goldHighlight = Color(0xFFF5D78E);
  static const Color goldDeep = Color(0xFFB8862B);
  static const Color textPrimary = Color(0xFFFFFFFF);
  static const Color textSecondary = Color(0xFFAAAAAA);
  static const Color divider = Color(0xFF403424);

  /// The gold gradient, deep → highlight, for the seekbar and the play
  /// button.
  static const LinearGradient goldGradient = LinearGradient(
    colors: <Color>[goldDeep, goldHighlight],
  );

  /// The top gradient over the video: black fading out downward.
  static const LinearGradient topScrim = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[Color(0xCC000000), Color(0x00000000)],
  );

  /// The bottom gradient over the video: black fading out upward.
  static const LinearGradient bottomScrim = LinearGradient(
    begin: Alignment.bottomCenter,
    end: Alignment.topCenter,
    colors: <Color>[Color(0xCC000000), Color(0x00000000)],
  );

  /// The drawer's edge: a hairline of gold on a dark surface.
  static const BorderSide drawerBorder = BorderSide(
    color: Color(0xFF403424),
  );
}

/// Motion: smooth 200–300 ms, as the spec asks.
abstract final class GoldenPlayerMotion {
  static const Duration fast = Duration(milliseconds: 200);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration drawer = Duration(milliseconds: 280);
  static const Curve curve = Curves.easeOutCubic;
}

/// Radii for the rounded, floating controls.
abstract final class GoldenPlayerRadii {
  static const double button = 24;
  static const double pill = 20;
  static const double card = 12;
  static const double drawer = 16;
}

/// Formats a playback time as mm:ss, or h:mm:ss past an hour.
String goldenFormatTime(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 86400 * 99);
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  final mm = minutes.toString().padLeft(2, '0');
  final ss = seconds.toString().padLeft(2, '0');
  if (hours > 0) return '$hours:$mm:$ss';
  return '$mm:$ss';
}

/// A round, translucent-dark icon button with a gold icon when active.
///
/// Used for every control in the top and bottom bars: the dark disc keeps
/// the icon legible over any frame, and the gold is the active state.
class GoldenIconButton extends StatelessWidget {
  const GoldenIconButton({
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.tooltip,
    this.size = 40,
    this.iconSize = 22,
    super.key,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final bool active;
  final String? tooltip;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final button = SizedBox(
      width: size,
      height: size,
      child: Material(
        color: Colors.black.withValues(alpha: 0.45),
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Icon(
              icon,
              size: iconSize,
              color: active
                  ? GoldenPlayerColors.goldHighlight
                  : GoldenPlayerColors.textPrimary,
            ),
          ),
        ),
      ),
    );
    final tip = tooltip;
    if (tip == null) return button;
    return Tooltip(message: tip, child: button);
  }
}

/// A small gold pill, for the speed chip and the "Playing" badge.
class GoldenPill extends StatelessWidget {
  const GoldenPill({
    required this.child,
    this.filled = false,
    this.onTap,
    super.key,
  });

  final Widget child;
  final bool filled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: filled
            ? GoldenPlayerColors.gold
            : Colors.black.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(GoldenPlayerRadii.pill),
        border: Border.all(
          color: filled
              ? Colors.transparent
              : GoldenPlayerColors.gold.withValues(alpha: 0.6),
        ),
      ),
      child: DefaultTextStyle(
        style: TextStyle(
          color: filled
              ? Colors.black
              : GoldenPlayerColors.goldHighlight,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
        child: child,
      ),
    );
    final tap = onTap;
    if (tap == null) return pill;
    return InkWell(
      onTap: tap,
      borderRadius: BorderRadius.circular(GoldenPlayerRadii.pill),
      child: pill,
    );
  }
}

/// A section label inside a drawer: small, gold, uppercase.
class GoldenSectionLabel extends StatelessWidget {
  const GoldenSectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: GoldenPlayerColors.gold,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
