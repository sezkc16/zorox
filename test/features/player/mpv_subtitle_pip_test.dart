/// The Android PiP window's subtitle size: the caption is a Flutter
/// overlay in fixed logical pixels, so in the tiny PiP window it stays
/// 22pt and is cut off at the right edge (user screenshot, 2026-11-14,
/// Flip 5). PiP halves the font and shrinks the padding; leaving PiP
/// restores the exact fullscreen look.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_subtitle_style.dart';
import 'package:skystream/features/settings/presentation/player_settings_provider.dart';

void main() {
  const settings = PlayerSettings();

  group('mpvSubtitleViewConfiguration PiP', () {
    test('halves the font size in PiP (22 -> 11 at the default)', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.style.fontSize, 11.0);
    });

    test('halves every size step, not just the default', () {
      for (final size in <double>[16, 20, 24, 28]) {
        final config = mpvSubtitleViewConfiguration(
          settings.copyWith(subtitleSize: size),
          screenHeight: 360,
          controlsVisible: false,
          isPip: true,
        );
        expect(config.style.fontSize, size / 2);
      }
    });

    test('PiP padding is small: 8px sides, 8px bottom', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.padding.left, 8.0);
      expect(config.padding.right, 8.0);
      expect(config.padding.bottom, 8.0);
    });

    test('PiP bottom still lifts by the raise, on the small height', () {
      final config = mpvSubtitleViewConfiguration(
        settings.copyWith(subtitleRaise: 0.1),
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      // 8 base + 0.1 * 140 lift.
      expect(config.padding.bottom, closeTo(22.0, 0.001));
    });

    test('fullscreen is unchanged: 22pt, 16px sides, 40px bottom', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(config.style.fontSize, 22.0);
      expect(config.padding.left, 16.0);
      expect(config.padding.right, 16.0);
      expect(config.padding.bottom, 40.0);
    });

    test('fullscreen with the bars up is unchanged: 116px bottom', () {
      final config = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: true,
      );
      expect(config.style.fontSize, 22.0);
      expect(config.padding.bottom, 116.0);
    });

    test('leaving PiP restores the exact fullscreen configuration', () {
      final pip = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      final full = mpvSubtitleViewConfiguration(
        settings,
        screenHeight: 360,
        controlsVisible: false,
      );
      expect(pip.style.fontSize, isNot(full.style.fontSize));
      expect(full.style.fontSize, 22.0);
      expect(full.padding, const EdgeInsets.fromLTRB(16, 0, 16, 40));
    });

    test('PiP font never drops below 6pt even for the S step', () {
      final config = mpvSubtitleViewConfiguration(
        settings.copyWith(subtitleSize: 10),
        screenHeight: 140,
        controlsVisible: false,
        isPip: true,
      );
      expect(config.style.fontSize, 6.0);
    });
  });
}
