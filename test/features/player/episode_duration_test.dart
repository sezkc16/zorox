import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/episode_duration.dart';

/// History stores the duration in milliseconds, the Episodes drawer once
/// read that number as seconds and so showed a three-hour film as
/// 2376:00:00 — the value, times a thousand, clamped by the formatter.
/// A row stored that way is now never believed: a film longer than a day
/// is not a duration, it is a corrupt number, and falls back to the
/// plugin's runtime.
void main() {
  group('episodeDurationFromHistoryMs', () {
    test('reads milliseconds, not seconds', () {
      // Avengers Endgame: Encore, ~3h01m. Stored as milliseconds.
      expect(
        episodeDurationFromHistoryMs(10860000, runtimeMinutes: 181),
        const Duration(hours: 3, minutes: 1),
      );
    });

    test('a film in seconds would read as 2376 hours — it does not', () {
      // 10,860,000 stored as seconds is 3016 hours, clamped by the
      // formatter to 2376:00:00: the exact number the drawer showed.
      // Read as milliseconds it is the real three hours.
      expect(
        episodeDurationFromHistoryMs(10860000, runtimeMinutes: 181),
        isNot(const Duration(hours: 2376)),
      );
    });

    test('a value over a day is corrupt, not a duration', () {
      // A row stored in seconds by mistake lands here: 10,860,000
      // seconds, read as milliseconds, is 125 days — not a film.
      expect(
        episodeDurationFromHistoryMs(10860000000, runtimeMinutes: 181),
        const Duration(hours: 3, minutes: 1),
        reason: 'falls back to the plugin runtime',
      );
    });

    test('a day exactly is still believed', () {
      expect(
        episodeDurationFromHistoryMs(86400000, runtimeMinutes: null),
        const Duration(hours: 24),
      );
    });

    test('a millisecond over a day is not believed', () {
      expect(
        episodeDurationFromHistoryMs(86400001, runtimeMinutes: null),
        isNull,
        reason: 'no runtime to fall back on',
      );
    });

    test('zero or a negative value falls back to the runtime', () {
      expect(
        episodeDurationFromHistoryMs(0, runtimeMinutes: 181),
        const Duration(hours: 3, minutes: 1),
      );
      expect(
        episodeDurationFromHistoryMs(-1000, runtimeMinutes: 90),
        const Duration(hours: 1, minutes: 30),
      );
    });

    test('no stored duration and no runtime is nothing', () {
      expect(episodeDurationFromHistoryMs(0, runtimeMinutes: null), isNull);
      expect(episodeDurationFromHistoryMs(0, runtimeMinutes: 0), isNull);
    });

    test('a runtime under a minute is nothing', () {
      expect(
        episodeDurationFromHistoryMs(0, runtimeMinutes: 0),
        isNull,
        reason: 'a film is not shorter than a minute',
      );
    });
  });
}
