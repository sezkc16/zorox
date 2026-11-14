import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_bottom_nav/liquid_glass_bottom_nav.dart';
import 'package:reicons/reicons.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

/// The app's bottom navigation, built on the `liquid_glass_bottom_nav`
/// package (0.0.14): a floating frosted-glass pill with a physics sliding
/// bubble, drag-to-switch and haptics.
///
/// The five tabs use the Reicon icon font as plain [IconData] — Filled
/// (`ReiconFilledIcons.home/.puzzle/.library/.grid`), except Search which
/// is Outline (`ReiconIcons.search`, per M M 2026-11-14) — so the exact
/// same icons render on iOS and Android — the font is bundled in the app,
/// no per-platform work, no asset files.
///
/// The package renders its glass only on Impeller — on by default on iOS,
/// explicitly enabled in AndroidManifest.xml
/// (`io.flutter.embedding.android.EnableImpeller`). Where Impeller is
/// unavailable it falls back to a standard Material bar with the same
/// items. Pass [impellerSupported] false to force that fallback (tests).
///
/// The widget is a [Positioned] overlay: the shell must place it as a
/// direct child of a [Stack] (see [AppScaffold]), not as a Scaffold
/// bottomNavigationBar.
///
/// The package always shows icon + label — it has no scroll-driven label
/// collapse, so the Nuvio label-collapse behaviour is not available with
/// it.
class CustomBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final void Function(int) onTap;

  /// Forces the package's legacy Material fallback when false.
  final bool impellerSupported;

  const CustomBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.impellerSupported = true,
  });

  /// The pill's bottom offset above the system bottom inset. The package
  /// default is 16; 8 sits the pill a little lower — closer to the bottom
  /// edge, so it reads as a proper bottom nav instead of floating mid-row
  /// over the last posters — without touching the pill itself (glass, gold
  /// active, icons, labels all unchanged). `insets` also sets the pill's
  /// side margins, so the pill is a little wider too; the package offers
  /// no separate bottom offset.
  static const double _kBottomMargin = 8.0;

  /// How far the pill sits below the package position. The package's
  /// `insets` also scales the pill's padding, corner radius and side
  /// margins, so lowering `insets` further would shrink the pill itself;
  /// the shell shifts it down by this much instead, keeping the pill's
  /// look (glass, gold active, icons, labels) unchanged. 8 sits the pill
  /// right above the home-indicator zone.
  static const double lowerBy = 8.0;

  /// Vertical space the floating nav occupies above the system bottom
  /// inset — the shell reserves this so content clears the bar. The
  /// package's [LiquidGlassNavBar.contentBottomInset] (96) is pill 68 +
  /// bottom margin 16 + 12 breathing buffer; with the margin at
  /// [_kBottomMargin] the reserve shrinks by the same amount, so the last
  /// content row stays fully visible above the pill (no content hidden
  /// behind it).
  static const double height =
      LiquidGlassNavBar.contentBottomInset - 16.0 + _kBottomMargin;

  /// The pill's offset from the screen bottom (matching 4c-app convention).
  static double bottomInsetFor(BuildContext context) =>
      math.max(MediaQuery.viewPaddingOf(context).bottom - 8, 12);

  @override
  Widget build(BuildContext context) {
    final localizations = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return LiquidGlassNavBar(
      items: [
        LiquidGlassNavItem(
          id: 'home',
          label: localizations.home,
          icon: ReiconFilledIcons.home,
        ),
        LiquidGlassNavItem(
          id: 'search',
          label: localizations.search,
          // Outline, not Filled — M M asked for the outline search icon
          // (2026-11-14); the other four tabs stay Filled.
          icon: ReiconIcons.search,
        ),
        const LiquidGlassNavItem(
          id: 'plugins',
          // Preview tab name (no l10n key for it): the user approved
          // "Plugins" — the Extensions screen (TojiX repo + providers).
          label: 'Plugins',
          icon: ReiconFilledIcons.puzzle,
        ),
        LiquidGlassNavItem(
          id: 'library',
          label: localizations.library,
          icon: ReiconFilledIcons.library,
        ),
        const LiquidGlassNavItem(
          id: 'browse',
          // Preview tab name (no l10n key for it): the user asked for a
          // "Browse" tab here in place of the Detail tab (v4) — the world's
          // movies, from TMDB when a key is set, the active provider's home
          // page otherwise.
          label: 'Browse',
          icon: ReiconFilledIcons.grid,
        ),
      ],
      selectedIndex: currentIndex,
      onTap: onTap,
      impellerSupported: impellerSupported,
      // A little lower than the package default (see [_kBottomMargin]).
      insets: _kBottomMargin,
      // Gold accent for the selected tab; muted grey otherwise.
      activeColor: colorScheme.primary,
      inactiveColor: Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF9D9A92)
          : colorScheme.onSurfaceVariant,
      iconSize: 28,
      labelStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
    );
  }
}
