public class TextureSWContext {
  public let pixelBuffer: CVPixelBuffer

  init(size: CGSize) {
    self.pixelBuffer = TextureSWContext.createPixelBuffer(size)
  }

  deinit {
    TextureSWContext.disposePixelBuffer(pixelBuffer)
  }

  private static func createPixelBuffer(_ size: CGSize) -> CVPixelBuffer {
    // Metal-compatible (as upstream) AND IOSurface-backed: the fork's PiP
    // layer (AVSampleBufferDisplayLayer) requires IOSurface-backed buffers
    // to display them. IOSurface backing does not change how Flutter
    // displays the same buffer.
    let attrs =
      [
        kCVPixelBufferMetalCompatibilityKey: true,
        kCVPixelBufferIOSurfacePropertiesKey: [:],
      ] as CFDictionary

    var pixelBuffer: CVPixelBuffer?
    let cvret = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(size.width),
      Int(size.height),
      kCVPixelFormatType_32BGRA,
      attrs,
      &pixelBuffer
    )
    assert(cvret == kCVReturnSuccess, "CVPixelBufferCreate")

    return pixelBuffer!
  }

  private static func disposePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
    // 'CVPixelBufferRelease' is unavailable: Core Foundation objects are
    // automatically memory managed
  }
}
