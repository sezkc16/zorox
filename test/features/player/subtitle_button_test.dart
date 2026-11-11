import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/providers/device_info_provider.dart';
import 'package:skystream/features/player/domain/side_car_subtitles.dart';
import 'package:skystream/features/player/presentation/vlc/panel/player_panel.dart'
    show PlayerPanelTab;
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/widgets/player_control_components.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:vlc_player/vlc_player.dart';

import 'fake_vlc_engine.dart';

/// The closed-captions button in the player chrome.
///
/// Without it, a subtitle is two taps away behind the Options panel's first
/// tab - Sources for a source list - and a subtitle that is on but not in the
/// viewer's language looks like no subtitle at all. The button opens the
/// panel straight on the Subtitles tab, where the video's own tracks and the
/// source's subtitle files are listed side by side, and it is lit while any
/// subtitle is on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget host(Widget child) => ProviderScope(
    overrides: [
      deviceProfileProvider.overrideWithValue(
        const AsyncValue.data(DeviceProfile(isTv: false)),
      ),
      playerSettingsProvider.overrideWithBuild(
        (_, _) => const PlayerSettings(),
      ),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(fit: StackFit.expand, children: [child]),
      ),
    ),
  );

  /// The real controller over the shared engine fake, with the controls on
  /// screen. [opened] collects the tabs the panel was asked to open on.
  /// [hasSubtitles] is the screen's flag for whether this media has a
  /// subtitle to pick; without it - or with it false - the button is
  /// absent, which is also what the pinned layout tests rely on.
  Future<(VlcPlayerController, FakeVlcEngine)> pumpControls(
    WidgetTester tester, {
    List<PlayerPanelTab>? opened,
    Set<PlayerPanelTab>? panelTabs,
    SideCarSubtitles? sideCars,
    ValueListenable<bool>? hasSubtitles,
  }) async {
    final engine = FakeVlcEngine();
    engine.install();
    addTearDown(engine.dispose);
    final controller = await engine.attach();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      host(
        VlcPlayerControls(
          controller: controller,
          title: 'Channel One',
          subtitle: 'S1 E1',
          onBack: () {},
          onOpenPanel: opened == null
              ? null
              : (tab) async {
                  opened.add(tab);
                },
          panelTabs:
              panelTabs ??
              const <PlayerPanelTab>{
                PlayerPanelTab.audio,
                PlayerPanelTab.subtitles,
              },
          hasSubtitles: hasSubtitles,
          sideCars: sideCars,
        ),
      ),
    );
    await tester.pump();
    return (controller, engine);
  }

  /// The subtitles button's lit state, read off the button itself.
  bool subtitleLit(WidgetTester tester) => tester
      .widget<PlayerIconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is PlayerIconButton && widget.tooltip == 'Subtitles',
        ),
      )
      .highlight;

  /// Ends the test with playback paused, so the controller's one-second stall
  /// watchdog is not still armed when flutter_test checks for pending timers.
  Future<void> park(FakeVlcEngine engine, WidgetTester tester) async {
    await engine.emit({'state': 'paused'});
    await tester.pump();
  }

  testWidgets(
    'the subtitles button opens the panel on the Subtitles tab',
    (tester) async {
      final opened = <PlayerPanelTab>[];
      final (_, engine) = await pumpControls(
        tester,
        opened: opened,
        hasSubtitles: ValueNotifier<bool>(true),
      );

      await tester.tap(find.byTooltip('Subtitles'));
      await tester.pump();

      expect(opened, <PlayerPanelTab>[PlayerPanelTab.subtitles]);
      await park(engine, tester);
    },
  );

  testWidgets(
    'no subtitles button without a panel to open',
    (tester) async {
      final (_, engine) = await pumpControls(tester);

      expect(find.byTooltip('Subtitles'), findsNothing);
      await park(engine, tester);
    },
  );

  testWidgets(
    'no subtitles button when the media has none to pick',
    (tester) async {
      final (_, engine) = await pumpControls(
        tester,
        opened: <PlayerPanelTab>[],
        hasSubtitles: ValueNotifier<bool>(false),
      );

      // The utility row has no width to spare on a handset: the button is
      // only there when there is a track to pick.
      expect(find.byTooltip('Subtitles'), findsNothing);
      await park(engine, tester);
    },
  );

  testWidgets(
    'the button arrives when subtitles do, and leaves when they go',
    (tester) async {
      final hasSubtitles = ValueNotifier<bool>(false);
      addTearDown(hasSubtitles.dispose);
      final (_, engine) = await pumpControls(
        tester,
        opened: <PlayerPanelTab>[],
        hasSubtitles: hasSubtitles,
      );
      expect(find.byTooltip('Subtitles'), findsNothing);

      hasSubtitles.value = true;
      await tester.pump();
      expect(find.byTooltip('Subtitles'), findsOneWidget);

      hasSubtitles.value = false;
      await tester.pump();
      expect(find.byTooltip('Subtitles'), findsNothing);
      await park(engine, tester);
    },
  );

  testWidgets(
    'lit while an embedded subtitle track is on',
    (tester) async {
      final (_, engine) = await pumpControls(
        tester,
        opened: <PlayerPanelTab>[],
        hasSubtitles: ValueNotifier<bool>(true),
      );
      expect(subtitleLit(tester), isFalse);

      engine.activeSubtitleId = 3;
      await engine.emit();
      await tester.pump();
      expect(subtitleLit(tester), isTrue);

      engine.activeSubtitleId = -1;
      await engine.emit();
      await tester.pump();
      expect(subtitleLit(tester), isFalse);
      await park(engine, tester);
    },
  );

  testWidgets(
    'lit while a subtitle file is on screen',
    (tester) async {
      Future<List<int>?> fetch(Uri url, Map<String, String>? headers) async =>
          utf8.encode(
            '1\n00:00:00,000 --> 10:00:00,000\nHello\n',
          );
      final sideCars = SideCarSubtitles(fetch: fetch);
      addTearDown(sideCars.dispose);
      final tracks = sideCars.replaceSourceTracks([
        (
          url: Uri.parse('https://example.com/subs/en.srt'),
          label: 'English',
          language: 'en',
          headers: null,
        ),
      ]);
      expect(await sideCars.select(tracks.single), isTrue);

      final (_, engine) = await pumpControls(
        tester,
        opened: <PlayerPanelTab>[],
        hasSubtitles: ValueNotifier<bool>(true),
        sideCars: sideCars,
      );
      await tester.pump();

      // The engine has no subtitle track on: the file alone lights it.
      expect(engine.activeSubtitleId, -1);
      expect(subtitleLit(tester), isTrue);
      await park(engine, tester);
    },
  );
}
