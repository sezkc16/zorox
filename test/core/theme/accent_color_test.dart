/// Which accent the app comes up in when the user has never chosen one.
///
/// Gold is the default — the app's Gold & Black identity. An explicit
/// choice in Settings > Accent color is honoured and persisted across
/// restarts; a value no release ever wrote (storage outlives downgrades
/// and hand-editing) falls back to Gold, the same as nothing recorded.
///
/// These tests drive the real [StorageService] against a real Hive box in
/// a temp directory, so "nothing recorded yet" is the genuine state rather
/// than a fake's idea of it.
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:skystream/core/storage/storage_service.dart';
import 'package:skystream/core/theme/accent_color.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late StorageService storage;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('accent_color');
    // StorageService.init() asks path_provider where to put its boxes.
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => dir.path,
    );
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  ProviderContainer boot() {
    final container = ProviderContainer(
      overrides: [storageServiceProvider.overrideWithValue(storage)],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('nothing chosen yet', () {
    test('comes up Gold', () {
      expect(storage.getAccentColor(), isNull, reason: 'nothing recorded yet');

      expect(boot().read(accentColorProvider), ZoroxAccent.gold);
    });
  });

  group('an explicit choice in Settings', () {
    test('Blue is honoured', () async {
      await storage.saveAccentColor('blue');

      expect(boot().read(accentColorProvider), ZoroxAccent.blue);
    });

    test('every preset round-trips through storage', () async {
      for (final accent in ZoroxAccent.values) {
        await storage.saveAccentColor(accent.name);

        expect(
          boot().read(accentColorProvider),
          accent,
          reason: '${accent.name} should survive a restart',
        );
      }
    });
  });

  test('a value no release ever wrote falls back to Gold', () async {
    await storage.saveAccentColor('sepia');

    expect(boot().read(accentColorProvider), ZoroxAccent.gold);
  });

  test('choosing an accent records it', () async {
    final container = boot();

    await container
        .read(accentColorProvider.notifier)
        .setAccent(ZoroxAccent.purple);

    expect(container.read(accentColorProvider), ZoroxAccent.purple);
    expect(storage.getAccentColor(), 'purple');
  });

  test('the palette has 8 distinct, named presets', () {
    expect(ZoroxAccent.values.length, 8);
    expect(
      ZoroxAccent.values.map((a) => a.color).toSet().length,
      8,
      reason: 'no two presets share a color',
    );
    for (final accent in ZoroxAccent.values) {
      expect(accent.label, isNotEmpty);
    }
  });
}
