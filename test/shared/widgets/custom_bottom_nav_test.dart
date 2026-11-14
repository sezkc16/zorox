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

  // v20+21: the pill must sit at the bottom edge on iOS. The package
  // positions its root Positioned at
  // MediaQuery.padding.bottom + insets, so with the shell's MediaQuery
  // override the pill's bottom must equal targetBottomGap even when the
  // real safe-area padding is 34 (iPhone home indicator).
  testWidgets('pill lands at the bottom edge on an iPhone-like safe area',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            padding: EdgeInsets.only(bottom: 34),
          ),
          child: Scaffold(
            body: Stack(
              children: [
                const SizedBox.expand(),
                Builder(
                  builder: (context) {
                    final mq = MediaQuery.of(context);
                    return MediaQuery(
                      data: mq.copyWith(
                        padding: mq.padding.copyWith(
                          bottom: CustomBottomNavBar.navPaddingBottom(
                            context,
                          ),
                        ),
                      ),
                      child: CustomBottomNavBar(
                        currentIndex: 0,
                        onTap: (_) {},
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The package's root Positioned: left/right are the side margins
    // (insets = 8) and bottom is the pill's gap from the screen edge.
    final positioned = tester
        .widgetList<Positioned>(find.byType(Positioned))
        .where((p) => p.left == 8.0 && p.right == 8.0)
        .toList();
    expect(positioned, hasLength(1));
    expect(positioned.single.bottom, CustomBottomNavBar.targetBottomGap);
  });

  testWidgets('navPaddingBottom only ever lowers the pill', (tester) async {
    double? seen34;
    double? seen0;
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            MediaQuery(
              data: const MediaQueryData(
                padding: EdgeInsets.only(bottom: 34),
              ),
              child: Builder(
                builder: (context) {
                  seen34 = CustomBottomNavBar.navPaddingBottom(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
            MediaQuery(
              data: const MediaQueryData(padding: EdgeInsets.zero),
              child: Builder(
                builder: (context) {
                  seen0 = CustomBottomNavBar.navPaddingBottom(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
    expect(seen34, 0.0);
    expect(seen0, 0.0);
  });

  test('content clearance covers the pill top plus buffer', () {
    expect(CustomBottomNavBar.targetBottomGap, 8.0);
    // 8 (gap) + 68 (pill) + 12 (buffer).
    expect(CustomBottomNavBar.contentClearance, 88.0);
  });
}
