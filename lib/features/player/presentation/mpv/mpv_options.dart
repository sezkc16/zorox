/// The mpv options Nuvio sets on iOS that media_kit does not.
///
/// Nuvio's iOS player is a native libmpv bridge
/// (`iosApp/iosApp/Player/MPVPlayerBridge.swift`, `setupMpv` +
/// `configureVideoOutput`); ZoroX's is media_kit, which sets its own fixed
/// set of options at Player creation and exposes no raw-option API on
/// [Player] — only [NativePlayer.setProperty], media_kit's own escape
/// hatch for raw mpv options. The screen applies these before the first
/// open, so they govern every file this player loads.
///
/// What Nuvio sets that media_kit does not, and why each matters for 4K:
///
///   * `hwdec-software-fallback: 300` — iOS can invalidate the VideoToolbox
///     session (Notification Center, PiP, a transient decoder error) and
///     FFmpeg recreates it within a few frames; Nuvio's own comment on
///     this line says to keep hardware decoding meanwhile. media_kit
///     leaves mpv's default, so one transient invalidation can drop a 4K
///     stream to software decode for the rest of the file — 4K HEVC in
///     software is the stutter the viewer reported. 300 frames of grace
///     is Nuvio's value.
///   * `tone-mapping: auto`, `target-colorspace-hint: yes`,
///     `hdr-compute-peak: yes` — Nuvio's HDR path (per-frame peak,
///     display colorspace). media_kit forces `hdr-compute-peak: no` at
///     Player creation and sets neither of the other two, so 4K HDR
///     played through its fixed-peak path; these restore Nuvio's.
///
/// Deliberately NOT here (read before adding):
///
///   * `vo: gpu-next` + `gpu-api: vulkan` + `gpu-context: moltenvk` —
///     Nuvio renders straight onto a Metal layer; media_kit needs
///     `vo=libmpv` for the Flutter texture the [Video] widget shows, so
///     switching the vo would blank the picture. The vo difference stays.
///   * `hwdec: videotoolbox` — already set, via
///     [VideoControllerConfiguration] in the screen's `_init`.
///   * `keep-open: yes`, `subs-fallback: yes` — media_kit already sets
///     both at Player creation.
///   * `vulkan-*` — only for Nuvio's Vulkan path, not media_kit's Metal
///     one.
library;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

/// Nuvio's iOS mpv options, as `option → value`.
const Map<String, String> kMpvNuvioOptions = <String, String>{
  'hwdec-software-fallback': '300',
  'tone-mapping': 'auto',
  'target-colorspace-hint': 'yes',
  'hdr-compute-peak': 'yes',
};

/// Applies [kMpvNuvioOptions] to a player's mpv instance, then reads the
/// active `hwdec` back so the log shows what decode is actually engaged
/// (`videotoolbox` on iOS). A single option failing must not break the
/// open: each set is its own try/catch, and the whole call is best-effort.
Future<void> applyMpvNuvioOptions(NativePlayer platform) async {
  for (final entry in kMpvNuvioOptions.entries) {
    try {
      await platform.setProperty(entry.key, entry.value);
    } catch (e) {
      debugPrint('[mpv] Nuvio option ${entry.key} not applied: $e');
    }
  }
  try {
    final hwdec = await platform.getProperty('hwdec');
    debugPrint('[mpv] hwdec: $hwdec (Nuvio options applied)');
  } catch (e) {
    debugPrint('[mpv] hwdec read-back failed: $e');
  }
}
