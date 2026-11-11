/// The Netflix subtitle font: what each renderer is handed for it, and the
/// guarantee that a fresh install's subtitles do not change.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/domain/subtitle_fonts.dart';
import 'package:skystream/features/player/domain/subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

void main() {
  group('subtitleFontFamily', () {
    test('Netflix is the bundled Roboto family', () {
      expect(
        subtitleFontFamily(SubtitleFont.netflix),
        kNetflixSubtitleFontFamily,
      );
      expect(kNetflixSubtitleFontFamily, 'Roboto');
    });

    test('Default and the other fonts are unchanged', () {
      expect(subtitleFontFamily(SubtitleFont.standard), isNull);
      expect(subtitleFontFamily(SubtitleFont.serif), isNotNull);
      expect(subtitleFontFamily(SubtitleFont.monospace), isNotNull);
    });

    test('the enum offers Netflix', () {
      expect(SubtitleFont.values, contains(SubtitleFont.netflix));
    });
  });

  group('subtitleEngineStyleFrom', () {
    test('a fresh install creates the player exactly as it always did', () {
      expect(
        subtitleEngineStyleFrom(const PlayerSettings()).toOptions(),
        subtitleStyleFrom(const PlayerSettings()).toOptions(),
      );
    });

    test('Netflix hands libVLC the bundled Roboto family when no file path '
        'has been prepared yet', () {
      final options = subtitleEngineStyleFrom(
        const PlayerSettings(subtitleFont: SubtitleFont.netflix),
      ).toOptions();
      expect(
        options,
        contains('--freetype-font=$kNetflixSubtitleFontFamily'),
      );
    });

    test('a non-Netflix font is untouched', () {
      final style = subtitleEngineStyleFrom(
        const PlayerSettings(subtitleFont: SubtitleFont.serif),
      );
      expect(style.fontFamily, subtitleFontFamily(SubtitleFont.serif));
    });
  });
}
