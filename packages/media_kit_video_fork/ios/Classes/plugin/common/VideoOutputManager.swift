#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class VideoOutputManager: NSObject {
  private let registry: FlutterTextureRegistry
  private var videoOutputs = [Int64: VideoOutput]()

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
  }

  public func create(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    textureUpdateCallback: @escaping VideoOutput.TextureUpdateCallback
  ) {
    let videoOutput = VideoOutput(
      handle: handle,
      configuration: configuration,
      registry: self.registry,
      textureUpdateCallback: textureUpdateCallback
    )

    self.videoOutputs[handle] = videoOutput
  }

  public func setSize(
    handle: Int64,
    width: Int64?,
    height: Int64?
  ) {
    let videoOutput = self.videoOutputs[handle]
    if videoOutput == nil {
      return
    }

    videoOutput!.setSize(
      width: width,
      height: height
    )
  }

  public func destroy(
    handle: Int64
  ) {
    let videoOutput = self.videoOutputs[handle]
    if videoOutput == nil {
      return
    }

    self.videoOutputs[handle] = nil
  }

  /// Fork (ZoroX v19): swaps one player's render path between hardware
  /// (GL) and software (CPU). Asynchronous: [completion] is called on the
  /// main thread with whether the new render context was created. Used by
  /// mpv PiP (software while PiP is on, hardware again when it stops).
  /// Must not block the caller (see VideoOutput.setHardwareAcceleration).
  public func setHardwareAcceleration(
    handle: Int64,
    enabled: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    guard let videoOutput = self.videoOutputs[handle] else {
      DispatchQueue.main.async { completion(false) }
      return
    }
    videoOutput.setHardwareAcceleration(enabled, completion: completion)
  }

  /// Fork (ZoroX v19): attaches / detaches the PiP frame feed for one
  /// player. Each frame the software texture renders is handed to
  /// [handler]; nil detaches it.
  public func setFrameHandler(
    handle: Int64,
    handler: ((CVPixelBuffer) -> Void)?
  ) {
    guard let videoOutput = self.videoOutputs[handle] else {
      return
    }
    videoOutput.setFrameHandler(handler)
  }
}
