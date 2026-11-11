import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_controls.dart';
import 'package:skystream/features/player/presentation/vlc/vlc_player_screen.dart';

import 'vlc_screen_harness.dart';

/// A PiP start the system never answers must not freeze the player, and
/// leaving the app while a film plays must float it.
///
/// The bug this file holds shut: tapping the PiP button left the screen
/// unresponsive until the app was backgrounded and foregrounded again,
/// because the button set the "in PiP" flag before the native request went
/// out - which unmounts the whole controls subtree - and a start the system
/// silently dropped never sent the event that would clear it. And pressing
/// Home did nothing at all, because nothing asked for PiP on the way out
/// and the background policy paused the film instead.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The native side of the platform PiP channel: how many times the app
  /// asked to enter PiP. Answers true, which is a request gone out, not a
  /// window opened - the window opening, or failing to, is reported through
  /// the engine's `pictureInPicture` event.
  late List<MethodCall> pipCalls;

  setUp(() {
    installEngineMocks();
    pipCalls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
    messenger.setMockMethodCallHandler(pipChannel, (call) async {
      pipCalls.add(call);
      if (call.method == 'enterPip') return true;
      return null;
    });
  });

  tearDown(() {
    removeEngineMocks();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    debugDefaultTargetPlatformOverride = null;
  });

  /// A phone playing a film, on the Android platform override: the PiP
  /// button only exists where the platform can do PiP, and the texture
  /// renderer is read once in initState, so switching the override after
  /// the screen has reached the playing stage cannot change the video path.
  /// The override itself marks nothing dirty, so the screen never re-reads
  /// the PiP gate on the next frame: the Rotate button is the rebuild that
  /// costs nothing - it flips the handset for this video and re-runs build,
  /// which is when the PiP button appears.
  Future<void> pumpPhonePlaying(WidgetTester tester) async {
    await pumpPlayer(tester, isTv: false);
    await sendFirstFrame(tester);
    expect(find.byType(VlcPlayerControls), findsOneWidget);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.tap(find.byTooltip('Rotate'));
    await tester.pump();
    expect(find.byTooltip('PiP'), findsOneWidget);
  }

  /// Keeps the film playing while the fake clock advances: one advancing
  /// position per 400 ms, which is also what keeps the stall watchdog quiet.
  Future<void> keepPlaying(WidgetTester tester, int steps) async {
    for (var i = 0; i < steps; i++) {
      await sendEvent(tester, snapshot(position: 1500 + (i + 1) * 1000));
    }
  }

  testWidgets(
    'a PiP attempt the system never answers takes the chrome back',
    variant: texturePlatform,
    (tester) async {
      await pumpPhonePlaying(tester);

      await tester.tap(find.byTooltip('PiP'));
      await tester.pump();
      expect(
        pipCalls.map((call) => call.method),
        <String>['enterPip'],
        reason: 'the button never asked the platform to open PiP',
      );
      expect(
        find.byType(VlcPlayerControls),
        findsNothing,
        reason: 'the chrome stayed up after the request went out',
      );

      // The window never opens and no event ever arrives: the film keeps
      // playing, past the two-second watchdog, and the chrome comes back.
      await keepPlaying(tester, 6);
      await tester.pump();
      expect(
        find.byType(VlcPlayerControls),
        findsOneWidget,
        reason:
            'a silently dropped PiP start left the player with no touch '
            'handling at all',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a PiP window that opens keeps the chrome off',
    variant: texturePlatform,
    (tester) async {
      await pumpPhonePlaying(tester);

      await tester.tap(find.byTooltip('PiP'));
      await tester.pump();
      expect(find.byType(VlcPlayerControls), findsNothing);

      // The window opened: the engine says so, which stands the watchdog
      // down. The film keeps playing past two seconds and the chrome stays
      // off - the window, not the screen, is showing the film now.
      await sendEvent(tester, <String, Object?>{'pictureInPicture': true});
      await keepPlaying(tester, 6);
      await tester.pump();
      expect(
        find.byType(VlcPlayerControls),
        findsNothing,
        reason: 'the watchdog fired on a window that had opened fine',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'leaving the app while playing floats the video',
    variant: texturePlatform,
    (tester) async {
      await pumpPhonePlaying(tester);

      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      await tester.pump();
      expect(
        pipCalls.map((call) => call.method),
        <String>['enterPip'],
        reason: 'going Home never asked for PiP',
      );
      expect(
        find.byType(VlcPlayerControls),
        findsNothing,
        reason: 'the chrome stayed up after leaving the app',
      );

      // Coming back closes the attempt and brings the chrome with it.
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      expect(find.byType(VlcPlayerControls), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
