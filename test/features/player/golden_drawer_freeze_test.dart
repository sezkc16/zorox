import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/mpv/golden_drawer.dart';
import 'package:skystream/features/player/presentation/mpv/golden_options_drawer.dart';
import 'package:skystream/features/player/presentation/mpv/golden_player_theme.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel_data.dart';

/// Repro for the v20+2 drawer-open freeze (user phone report 2026-11-14):
/// tapping any drawer button (CC / Episodes / Audio / Sources) freezes the
/// whole app while audio keeps playing. The drawer never appears.
///
/// This pumps the drawer section EXACTLY as `GoldenPlayerControls._buildStack`
/// wires it — the scrim AnimatedSwitcher (fade only) + the panel
/// AnimatedSwitcher (slide only) — with the real `GoldenDrawerScrim` and the
/// real `GoldenSourcesDrawer`. If `pumpAndSettle` times out, the freeze
/// reproduces in the widget tree alone.
void main() {
  testWidgets('v20 drawer shell: opening the Sources drawer settles',
      (tester) async {
    final panelData = ValueNotifier<PanelData>(
      const PanelData(
        sources: <StreamResult>[
          StreamResult(
            url: 'https://example.com/a.m3u8',
            source: 'FSL 2160p WEB-DL [16.74 GB]',
            quality: 2160,
          ),
          StreamResult(
            url: 'https://example.com/b.m3u8',
            source: 'PixelDrain 1080p',
            quality: 1080,
          ),
        ],
        currentSourceIndex: 0,
        playedSources: <int>{0},
      ),
    );
    addTearDown(panelData.dispose);

    var drawerOpen = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: StatefulBuilder(
            builder: (context, setState) {
              return Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Center(
                    child: ElevatedButton(
                      onPressed: () => setState(() => drawerOpen = true),
                      child: const Text('Open drawer'),
                    ),
                  ),
                  AnimatedSwitcher(
                    duration: GoldenPlayerMotion.drawer,
                    switchInCurve: GoldenPlayerMotion.curve,
                    switchOutCurve: GoldenPlayerMotion.curve,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: !drawerOpen
                        ? const SizedBox.shrink(
                            key: ValueKey<String>('scrim-none'),
                          )
                        : GoldenDrawerScrim(
                            key: const ValueKey<String>('scrim-open'),
                            onClose: () =>
                                setState(() => drawerOpen = false),
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
                      return SlideTransition(
                        position: offset,
                        child: child,
                      );
                    },
                    child: !drawerOpen
                        ? const SizedBox.shrink(
                            key: ValueKey<String>('none'),
                          )
                        : GoldenSourcesDrawer(
                            key: const ValueKey<String>('sources'),
                            panelData: panelData,
                            onClose: () =>
                                setState(() => drawerOpen = false),
                          ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open drawer'));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('FSL 2160p WEB-DL [16.74 GB]'), findsOneWidget);

    // The scrim covers the whole screen: a tap on the video side (left,
    // away from the right-side panel) dismisses the drawer. This guards
    // the scrim's size — a zero-size scrim would never see the tap.
    await tester.tapAt(const Offset(50, 300));
    await tester.pumpAndSettle(const Duration(seconds: 5));
    expect(find.text('Sources'), findsNothing);
  });
}
