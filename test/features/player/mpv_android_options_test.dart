import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_android_options.dart';

/// Android 4K lag: the Golden player hardcoded `hwdec: 'videotoolbox'`
/// for every platform. VideoToolbox is Apple-only — on Android mpv
/// could not use it and fell back to software decoding, and 4K HEVC in
/// software is the continuous stutter the viewer reported (v20+6 release
/// APK, Z Flip 5), while the same file is smooth on iOS. These tests pin
/// the platform split and the Android option set, including the guard
/// that the v20+1 black-screen value never comes back.
void main() {
  group('mpvHwdecForPlatform', () {
    test('Apple platforms keep videotoolbox', () {
      expect(mpvHwdecForPlatform(TargetPlatform.iOS), 'videotoolbox');
      expect(mpvHwdecForPlatform(TargetPlatform.macOS), 'videotoolbox');
    });

    test('Android gets auto-safe (mediacodec), not videotoolbox', () {
      expect(mpvHwdecForPlatform(TargetPlatform.android), 'auto-safe');
    });

    test('every other platform gets auto-safe too', () {
      expect(mpvHwdecForPlatform(TargetPlatform.linux), 'auto-safe');
      expect(mpvHwdecForPlatform(TargetPlatform.windows), 'auto-safe');
      expect(mpvHwdecForPlatform(TargetPlatform.fuchsia), 'auto-safe');
    });
  });

  group('kMpvAndroidOptions', () {
    test('carries the safe presentation options', () {
      expect(kMpvAndroidOptions['video-sync'], 'display-resample');
      expect(kMpvAndroidOptions['framedrop'], 'decoder+vo');
      expect(kMpvAndroidOptions['hwdec-software-fallback'], '300');
    });

    test('never carries the v20+1 black-screen value', () {
      expect(kMpvAndroidOptions.containsKey('hdr-compute-peak'), isFalse);
      expect(kMpvAndroidOptions.containsKey('tone-mapping'), isFalse);
      expect(kMpvAndroidOptions.containsKey('target-colorspace-hint'),
          isFalse);
    });

    test('never touches the video output', () {
      expect(kMpvAndroidOptions.containsKey('vo'), isFalse);
      expect(kMpvAndroidOptions.containsKey('gpu-api'), isFalse);
      expect(kMpvAndroidOptions.containsKey('gpu-context'), isFalse);
    });
  });
}
