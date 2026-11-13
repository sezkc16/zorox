/// Android-only mpv options, and the platform-dependent hardware decoder.
///
/// Why this file exists: the Golden player hardcodes `hwdec: 'videotoolbox'`
/// in its [VideoControllerConfiguration] — correct on iOS, where
/// VideoToolbox is the hardware decoder, but on Android VideoToolbox does
/// not exist. media_kit_video 2.0.1's Android controller uses the passed
/// `hwdec` verbatim (`android_video_controller/real.dart`: `hwdec:
/// configuration.hwdec ?? await getDefaultHwdec()`), so Android got
/// `hwdec=videotoolbox`, mpv could not use it, and fell back to SOFTWARE
/// decoding. 4K HEVC in software on a phone CPU is the continuous stutter
/// the viewer reported on Android (v20+6 release APK, Z Flip 5) — while
/// the same file is smooth on iOS, where VideoToolbox engages. Debug
/// overhead was ruled out: the lag persisted in the release build.
///
/// The fix has two parts, both Android-only (the iOS path is smooth and
/// is not touched):
///
///   1. [mpvHwdecForPlatform] — iOS/macOS keep `'videotoolbox'`; Android
///      gets `'auto-safe'`, media_kit's own Android default, which
///      resolves to mediacodec (see the `hwdec-codecs` list media_kit
///      sets: h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1).
///   2. [kMpvAndroidOptions] — the safe presentation options media_kit
///      does not set, applied via [NativePlayer.setProperty] before the
///      first open (the same escape hatch v20+1 used; the mechanism was
///      never the problem — the `hdr-compute-peak=yes` VALUE was, and it
///      is NOT in this map, never add it):
///        * `video-sync: display-vdrop` — sync to the display's vsync
///          and drop/duplicate video frames to match it, instead of
///          mpv's default `video-sync=audio` (24 fps film on a 120 Hz
///          phone judders under `audio`). A presentation option; it
///          cannot blank the picture.
///        * `framedrop: decoder+vo` — when the decoder or the video
///          output cannot keep up, drop frames instead of letting A/V
///          drift grow. Same safety as above.
///        * `hwdec-software-fallback: 300` — Nuvio's value (the safest
///          of its options): if the hardware decoder glitches
///          transiently, keep hardware decoding for 300 frames while
///          FFmpeg recreates the session, instead of dropping to
///          software decode for the rest of the file.
///
/// [logMpvDecodeInfo] is the lightweight diagnostic: one debugPrint of
/// the decoder actually engaged (`hwdec-current`) and the video codec,
/// read back once on first play. If it prints `mediacodec`, hardware
/// decode is engaged; if it prints nothing/`no`, the file is still on
/// software decode and the hwdec fix did not take.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// The mpv hardware decoder for [platform].
///
/// Apple platforms use VideoToolbox; everything else uses media_kit's
/// Android default `'auto-safe'` (mediacodec on Android). Pure, so it is
/// unit-tested (see `mpv_android_options_test.dart`).
String mpvHwdecForPlatform(TargetPlatform platform) {
  switch (platform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return 'videotoolbox';
    case TargetPlatform.android:
    case TargetPlatform.linux:
    case TargetPlatform.windows:
    case TargetPlatform.fuchsia:
      return 'auto-safe';
  }
}

/// Android-only mpv options, as `option → value`.
///
/// Deliberately NOT here (read before adding):
///
///   * `hdr-compute-peak: yes` — the v20+1 black-screen cause. media_kit
///     forces it to `no` with `vo=libmpv`; enabling it blanks the video
///     and stalls the player. NEVER retry.
///   * `tone-mapping`, `target-colorspace-hint` — Nuvio's HDR path; not
///     needed for the Android lag and out of scope here.
///   * `vo`, `gpu-api`, `gpu-context` — media_kit owns the video output
///     (`vo=gpu` + `gpu-context=android` on Android, `vo=libmpv` on
///     iOS); changing it breaks the Flutter texture.
const Map<String, String> kMpvAndroidOptions = <String, String>{
  'video-sync': 'display-vdrop',
  'framedrop': 'decoder+vo',
  'hwdec-software-fallback': '300',
};

/// Applies [kMpvAndroidOptions] to a player's mpv instance, then reads
/// the `hwdec` option back so the log shows what was set. A single
/// option failing must not break the open: each set is its own
/// try/catch, and the whole call is best-effort.
Future<void> applyMpvAndroidOptions(NativePlayer platform) async {
  for (final entry in kMpvAndroidOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] Android option ${entry.key} not applied: $e');
    }
  }
  try {
    final hwdec = await platform.getProperty('hwdec');
    debugPrint('[mpv] hwdec: $hwdec (Android options applied)');
  } catch (e) {
    debugPrint('[mpv] hwdec read-back failed: $e');
  }
}

/// One-time diagnostic: reads the decoder actually engaged back from
/// mpv and prints it. Call once, on first play — before the first frame
/// `hwdec-current` is empty, so reading it earlier proves nothing.
///
/// Expected on Android: `hwdec-current: mediacodec`. If it prints
/// empty/`no`, the file is still on software decode.
Future<void> logMpvDecodeInfo(Player player) async {
  try {
    final platform = player.platform;
    if (platform is! NativePlayer) return;
    final hwdecCurrent = await platform.getProperty('hwdec-current');
    final codec = await platform.getProperty('video-codec');
    debugPrint('[mpv] decode: hwdec-current=$hwdecCurrent codec=$codec');
  } catch (e) {
    debugPrint('[mpv] decode read-back failed: $e');
  }
}
