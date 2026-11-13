/// The Nuvio iOS mpv options the screen applies to media_kit.
///
/// A pure map test: the options are the fix for 4K stutter (see
/// mpv_options.dart), and a typo in a key would silently set nothing —
/// mpv_set_property_string on an unknown name is a no-op — so the keys
/// and values are pinned here.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_options.dart';

void main() {
  test('carries Nuvio\'s iOS 4K options', () {
    // The VideoToolbox session guard: without it, one transient
    // invalidation drops 4K to software decode for the rest of the file.
    expect(kMpvNuvioOptions['hwdec-software-fallback'], '300');
    // Nuvio's HDR path (media_kit forces hdr-compute-peak to 'no').
    expect(kMpvNuvioOptions['tone-mapping'], 'auto');
    expect(kMpvNuvioOptions['target-colorspace-hint'], 'yes');
    expect(kMpvNuvioOptions['hdr-compute-peak'], 'yes');
  });

  test('does not touch the video output', () {
    // vo=libmpv is what the [Video] widget renders through; Nuvio's
    // vo=gpu-next would blank the picture, so it must never be in here.
    expect(kMpvNuvioOptions.containsKey('vo'), isFalse);
    expect(kMpvNuvioOptions.containsKey('gpu-api'), isFalse);
    expect(kMpvNuvioOptions.containsKey('gpu-context'), isFalse);
    // hwdec itself is set by the VideoControllerConfiguration, not here.
    expect(kMpvNuvioOptions.containsKey('hwdec'), isFalse);
  });
}
