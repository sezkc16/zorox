import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reicons/reicons.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:skystream/shared/widgets/custom_bottom_nav.dart';

/// The v20 bar: the `liquid_glass_bottom_nav` package's floating glass pill
/// with the five Reicon icons — Filled, except Search which is Outline
/// (M M, 2026-11-14). The package renders its glass only
/// on Impeller; in the test environment the renderer falls back, but the
/// tabs, labels, selection colour and tap routing are all plain widgets and
/// are what this tests.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Brightness brightness, {
    int currentIndex = 0,
    void Function(int)? onTap,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                CustomBottomNavBar(
                  currentIndex: currentIndex,
                  onTap: onTap ?? (_) {},
                ),
              ],
            ),
          ),
        ),
      );

  testWidgets('shows all five tabs with their labels', (tester) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.text('Library'), findsOneWidget);
    expect(find.text('Browse'), findsOneWidget);
  });

  testWidgets('shows the five Reicon icons', (tester) async {
    await pump(tester, Brightness.dark);
    await tester.pumpAndSettle();
    expect(find.byIcon(ReiconFilledIcons.home), findsOneWidget);
    // Search is Outline, not Filled (M M, 2026-11-14); the other four
    // stay Filled.
    expect(find.byIcon(ReiconIcons.search), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.puzzle), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.library), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.grid), findsOneWidget);
  });

  testWidgets('tapping a tab reports its index', (tester) async {
    var tapped = -1;
    await pump(tester, Brightness.dark, onTap: (i) => tapped = i);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Library'));
    await tester.pumpAndSettle();
    expect(tapped, 3);
  });

  testWidgets('the selected tab wears the gold accent', (tester) async {
    await pump(tester, Brightness.dark, currentIndex: 2);
    await tester.pumpAndSettle();
    final element = tester.element(find.byType(CustomBottomNavBar));
    final primary = Theme.of(element).colorScheme.primary;
    // The package tints the selected tab's icon with the active colour,
    // which the bar sets to the theme primary (gold).
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.puzzle)).color,
      primary,
    );
    // ... and an unselected tab does not wear it.
    expect(
      tester.widget<Icon>(find.byIcon(ReiconFilledIcons.home)).color,
      isNot(primary),
    );
  });

  testWidgets('the legacy fallback renders the same tabs', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              const SizedBox.expand(),
              CustomBottomNavBar(
                currentIndex: 0,
                onTap: (_) {},
                impellerSupported: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Plugins'), findsOneWidget);
    expect(find.byIcon(ReiconFilledIcons.grid), findsOneWidget);
  });

  testWidgets('iOS pill drops to the Android spot; Android does not move',
      (tester) async {
    // The override must be cleared before the test body returns: the
    // framework verifies all foundation debug vars are unset after the
    // body, before addTearDown callbacks run.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      // iPhone 15 Pro Max: 34pt home-indicator inset -> 18pt extra shift,
      // landing the pill 16pt from the bottom edge, as on Android.
      double shift = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewPadding: EdgeInsets.only(bottom: 34),
            ),
            child: Builder(
              builder: (context) {
                shift = CustomBottomNavBar.extraLowerBy(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(shift, 18.0);

      // Android (gesture nav, ~16pt inset): no shift at all.
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      shift = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              viewPadding: EdgeInsets.only(bottom: 16),
            ),
            child: Builder(
              builder: (context) {
                shift = CustomBottomNavBar.extraLowerBy(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );
      expect(shift, 0.0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
