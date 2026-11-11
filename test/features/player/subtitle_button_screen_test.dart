import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';

import 'vlc_screen_harness.dart';

/// The closed-captions button, as the screen drives it.
///
/// The controls-level tests prove the button opens the Subtitles tab and
/// lights while a subtitle is on; those hand the screen's flag in by hand.
/// These prove the flag itself: that a file the source shipped and an
/// embedded track the engine publishes both make it true, and that a film
/// with neither leaves the button off - so the utility row keeps the width
/// the layout tests pin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// What the engine answers `getSubtitleTracks` with, in the shape
  /// [VlcTrackDescription.fromMap] reads. Starts empty: the film has no
  /// embedded track until the test says it does.
  late List<Map<String, Object?>> engineSubtitleTracks;

  setUp(() {
    installEngineMocks();
    engineSubtitleTracks = <Map<String, Object?>>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      return null;
    });
    // The harness's engine answers nothing; this one answers `create` the
    // same way and `getSubtitleTracks` from the list above.
    messenger.setMockMethodCallHandler(vlcChannel, (call) async {
      if (call.method == 'create') {
        return <String, Object?>{'viewId': viewId, 'textureId': viewId};
      }
      if (call.method == 'getSubtitleTracks') {
        return engineSubtitleTracks;
      }
      return null;
    });
  });

  tearDown(() {
    removeEngineMocks();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  /// A phone playing a direct file. The first frame is in, and the engine's
  /// list has been read once - empty, so the button is off.
  Future<void> pumpPhonePlaying(WidgetTester tester) async {
    await pumpPlayer(tester, isTv: false);
    await sendFirstFrame(tester);
    await tester.pump();
    expect(find.byTooltip('Subtitles'), findsNothing);
  }

  testWidgets(
    'an embedded track the engine publishes brings the button up',
    variant: texturePlatform,
    (tester) async {
      await pumpPhonePlaying(tester);

      // The demuxer finishes its parse: a subtitle track appears and the
      // engine's revision moves, which is the screen's cue to read the
      // list again.
      engineSubtitleTracks = <Map<String, Object?>>[
        {'id': 2, 'name': 'Track 1 - [English]', 'language': 'en'},
      ];
      await sendEvent(tester, <String, Object?>{
        ...snapshot(),
        'trackRevision': 1,
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byTooltip('Subtitles'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a subtitle file the source shipped brings the button up',
    variant: texturePlatform,
    (tester) async {
      await pumpPlayer(
        tester,
        isTv: false,
        preloadedStreams: <StreamResult>[
          StreamResult(
            url: 'https://example.com/movie.mp4',
            source: 'Test',
            providerName: 'Test',
            subtitles: <SubtitleFile>[
              SubtitleFile(
                url: 'https://example.com/subs/en.srt',
                label: 'English',
                lang: 'en',
              ),
            ],
          ),
        ],
      );
      await sendFirstFrame(tester);
      await tester.pump();

      expect(find.byTooltip('Subtitles'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
