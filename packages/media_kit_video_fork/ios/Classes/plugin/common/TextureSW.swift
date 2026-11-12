#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class TextureSW: NSObject, FlutterTexture, ResizableTextureProtocol {
  public typealias UpdateCallback = () -> Void

  private let handle: OpaquePointer
  private let updateCallback: UpdateCallback
  private var renderContext: OpaquePointer?
  private var textureContexts = SwappableObjectManager<TextureSWContext>(
    objects: [],
    skipCheckArgs: true
  )

  /// The fork's PiP feed: called with each freshly rendered pixel buffer
  /// (after it is pushed ready for Flutter). The PiP side enqueues the
  /// buffer into its AVSampleBufferDisplayLayer. Nil when PiP is off.
  public var onFrameRendered: ((CVPixelBuffer) -> Void)?

  /// Whether the software render context was actually created. The swap
  /// (see VideoOutput) must check this: creating a second render context
  /// for a handle that still has one fails, and that must never crash the
  /// app the way upstream's `checkError` (exit(1)) would.
  public var isReady: Bool { renderContext != nil }

  init(
    handle: OpaquePointer,
    updateCallback: @escaping UpdateCallback
  ) {
    self.handle = handle
    self.updateCallback = updateCallback

    super.init()

    DispatchQueue.main.async {
      self.initMPV()
    }
  }

  deinit {
    disposePixelBuffer()
    disposeMPV()
  }

  public func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    let textureContext = textureContexts.current
    if textureContext == nil {
      return nil
    }

    return Unmanaged.passRetained(textureContext!.pixelBuffer)
  }

  private func initMPV() {
    let api = UnsafeMutableRawPointer(
      mutating: (MPV_RENDER_API_TYPE_SW as NSString).utf8String
    )
    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: api),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    // The fork never crashes on a failed render-context creation (unlike
    // upstream's checkError, which calls exit(1)): the texture swap frees
    // the previous context first, and if that has not landed yet the
    // creation fails and the caller retries. A failed context just renders
    // nothing until it is retried.
    let status = mpv_render_context_create(&renderContext, handle, &params)
    if status < 0 {
      NSLog(
        "TextureSW: mpv_render_context_create failed: \(String(cString: mpv_error_string(status)))"
      )
      renderContext = nil
      return
    }

    mpv_render_context_set_update_callback(
      renderContext,
      { (ctx) in
        let that = unsafeBitCast(ctx, to: TextureSW.self)
        DispatchQueue.main.async {
          that.updateCallback()
        }
      },
      UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    )
  }

  private func disposeMPV() {
    guard let renderContext = renderContext else { return }
    mpv_render_context_set_update_callback(renderContext, nil, nil)
    mpv_render_context_free(renderContext)
    self.renderContext = nil
  }

  public func resize(_ size: CGSize) {
    if size.width == 0 || size.height == 0 {
      return
    }

    NSLog("TextureSW: resize: \(size.width)x\(size.height)")
    createPixelBuffer(size)
  }

  private func createPixelBuffer(_ size: CGSize) {
    disposePixelBuffer()

    textureContexts.reinit(
      objects: [
        TextureSWContext(size: size),
        TextureSWContext(size: size),
        TextureSWContext(size: size),
      ],
      skipCheckArgs: true
    )
  }

  private func disposePixelBuffer() {
    textureContexts.reinit(objects: [], skipCheckArgs: true)
  }

  public func render(_ size: CGSize) {
    guard let renderContext = renderContext else { return }
    let textureContext = textureContexts.nextAvailable()
    if textureContext == nil {
      return
    }

    CVPixelBufferLockBaseAddress(
      textureContext!.pixelBuffer,
      CVPixelBufferLockFlags(rawValue: 0)
    )
    defer {
      CVPixelBufferUnlockBaseAddress(
        textureContext!.pixelBuffer,
        CVPixelBufferLockFlags(rawValue: 0)
      )
    }

    var ssize: [Int32] = [Int32(size.width), Int32(size.height)]
    let format: String = "bgr0"
    var pitch: Int = CVPixelBufferGetBytesPerRow(textureContext!.pixelBuffer)
    let buffer = CVPixelBufferGetBaseAddress(textureContext!.pixelBuffer)

    // pointers
    let ssizePtr = ssize.withUnsafeMutableBytes {
      $0.baseAddress?.assumingMemoryBound(to: Int32.self)
    }
    let formatPtr = UnsafeMutablePointer(
      mutating: (format as NSString).utf8String
    )
    let pitchPtr = withUnsafeMutablePointer(to: &pitch) { $0 }
    let bufferPtr = buffer!.assumingMemoryBound(to: UInt8.self)

    var params: [mpv_render_param] = [
      mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: ssizePtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: formatPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: pitchPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: bufferPtr),
      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
    ]

    mpv_render_context_render(renderContext, &params)

    textureContexts.pushAsReady(textureContext!)
    // The fork's PiP feed: the buffer just rendered, for the
    // AVSampleBufferDisplayLayer. Runs before Flutter is told the frame is
    // available, so the PiP side's alpha fix lands before either reader.
    if let onFrameRendered = onFrameRendered {
      onFrameRendered(textureContext!.pixelBuffer)
    }
  }
}
