#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

// This class creates and manipulates the different types of FlutterTexture,
// handles resizing, rendering calls, and notify Flutter when a new frame is
// available to render.
//
// To improve the user experience, a worker is used to execute heavy tasks on a
// dedicated thread.
//
// FORK (ZoroX v19): the texture can be swapped between hardware (OpenGL ES)
// and software rendering while the player lives, for mpv Picture-in-Picture:
// iOS revokes GPU access in the background, so PiP can only be fed by a
// software render context. Swap with [setHardwareAcceleration], which frees
// the old render context before creating the new one (mpv allows one per
// handle) and re-registers the texture so Dart's VideoController picks up
// the new texture id. A failed creation (the old context not freed yet)
// never crashes the app — the swap retries instead.
public class VideoOutput: NSObject {
  // Will be called on the main thread
  public typealias TextureUpdateCallback = (Int64, CGSize) -> Void

  private static let isSimulator: Bool = {
    let isSim: Bool
    #if targetEnvironment(simulator)
      isSim = true
    #else
      isSim = false
    #endif
    return isSim
  }()

  private let handle: OpaquePointer
  private let enableHardwareAcceleration: Bool
  private let registry: FlutterTextureRegistry
  private let textureUpdateCallback: TextureUpdateCallback
  private let worker: Worker = .init()
  private var width: Int64?
  private var height: Int64?
  // Optional (fork): the texture is nil during a hardware/software swap.
  private var texture: ResizableTextureProtocol?
  private var textureId: Int64 = -1
  private var currentSize: CGSize = CGSize.zero
  private var disposed: Bool = false

  /// Which kind of texture is live, for the swap.
  private var usingHardwareAcceleration: Bool = false

  /// True while a hardware/software swap is in flight; frame callbacks
  /// return early rather than touching a texture being replaced.
  private var swappingTexture = false

  /// The live textures, held directly so the swap can ask each whether its
  /// render context was actually created, and so the PiP frame feed can be
  /// attached to the software one.
  private var hwTexture: TextureHW?
  private var swTexture: TextureSW?

  init(
    handle: Int64,
    configuration: VideoOutputConfiguration,
    registry: FlutterTextureRegistry,
    textureUpdateCallback: @escaping TextureUpdateCallback
  ) {
    let handle = OpaquePointer(bitPattern: Int(handle))
    assert(handle != nil, "handle casting")

    self.handle = handle!
    width = configuration.width
    height = configuration.height
    enableHardwareAcceleration = configuration.enableHardwareAcceleration
    self.registry = registry
    self.textureUpdateCallback = textureUpdateCallback

    super.init()

    worker.enqueue {
      self._init()
    }
  }

  deinit {
    worker.cancel()

    disposed = true
    disposeTextureId()
  }

  public func setSize(width: Int64?, height: Int64?) {
    worker.enqueue {
      self.width = width
      self.height = height
    }
  }

  private func _init() {
    let enableHardwareAcceleration =
      VideoOutput.isSimulator ? false : enableHardwareAcceleration

    NSLog(
      "VideoOutput: enableHardwareAcceleration: \(enableHardwareAcceleration)"
    )

    if VideoOutput.isSimulator {
      NSLog(
        "VideoOutput: warning: hardware rendering is disabled in the iOS simulator, due to an incompatibility with OpenGL ES"
      )
    }

    _createTexture(hardware: enableHardwareAcceleration)
    usingHardwareAcceleration = enableHardwareAcceleration

    DispatchQueue.main.sync { [weak self]() in
      guard let that = self else {
        return
      }
      that.registerTextureId()
    }
  }

  /// Creates the texture of the requested kind, replacing any live one.
  /// Must run on the worker (the texture lives there).
  private func _createTexture(hardware: Bool) {
    // A fresh texture starts with NO pixel buffers — they are created by
    // resize(), which _updateCallback only calls when the video size
    // CHANGES. The size does not change across a HW<->SW swap, so a
    // swapped-in texture would never render a frame (the SW texture
    // feeds PiP nothing and PiP start times out with no window; a
    // swapped-back HW texture shows black after PiP stops) unless the
    // size is forced to "changed". Resetting here covers every creation
    // path (init, swap, retry); the next frame then resizes the new
    // texture and renders into it.
    currentSize = .zero
    if hardware {
      swTexture = nil
      let hw = TextureHW(
        handle: handle,
        // Use `weak self` to prevent memory leaks
        updateCallback: { [weak self]() in
          guard let that = self else {
            return
          }
          that.updateCallback()
        }
      )
      hwTexture = hw
      texture = SafeResizableTexture(hw)
    } else {
      hwTexture = nil
      let sw = TextureSW(
        handle: handle,
        // Use `weak self` to prevent memory leaks
        updateCallback: { [weak self]() in
          guard let that = self else {
            return
          }
          that.updateCallback()
        }
      )
      swTexture = sw
      texture = SafeResizableTexture(sw)
    }
  }

  /// Swaps the render path between hardware (GL) and software (CPU).
  ///
  /// Asynchronous: the swap runs on the worker and [completion] is called
  /// on the main thread with whether the new texture's render context was
  /// created. It MUST NOT block the calling thread — the worker unregisters
  /// the old texture on the main thread (`DispatchQueue.main.sync`), so a
  /// caller that waits on the main thread would deadlock it. Frees the old
  /// texture — and with it the old mpv render context — before creating
  /// the new one, and re-registers the texture so Dart's VideoController
  /// picks up the new id via VideoOutput.Resize. A creation that fails
  /// because the old context had not landed yet is retried (up to
  /// ~500 ms); it never crashes the app.
  public func setHardwareAcceleration(
    _ enabled: Bool,
    completion: @escaping (Bool) -> Void
  ) {
    worker.enqueue {
      let result = self._setHardwareAcceleration(enabled)
      DispatchQueue.main.async {
        completion(result)
      }
    }
  }

  private func _setHardwareAcceleration(_ enabled: Bool) -> Bool {
    if disposed { return false }
    let target = VideoOutput.isSimulator ? false : enabled
    if target == usingHardwareAcceleration { return true }
    swappingTexture = true
    defer { swappingTexture = false }

    // 1. Unregister the old texture from Flutter synchronously. This
    //    releases Flutter's reference to the texture object.
    let oldId = textureId
    textureId = -1
    DispatchQueue.main.sync {
      self.registry.unregisterTexture(oldId)
    }
    // 2. Release our reference. If this was the last one the texture
    //    deallocates and frees its mpv render context (on this thread).
    //    A frame still in flight in the engine can hold it a moment
    //    longer; the creation below is retried for exactly that.
    texture = nil
    hwTexture = nil
    swTexture = nil

    // 3. Create the new texture (a new mpv render context) and register
    //    it, retrying while the old context is still being freed.
    usingHardwareAcceleration = target
    var attempts = 0
    var ready = false
    while attempts < 10 && !ready {
      _createTexture(hardware: target)
      ready = target
        ? (hwTexture?.isReady ?? false)
        : (swTexture?.isReady ?? false)
      if !ready {
        // Drop the failed texture and try again after a short wait.
        texture = nil
        hwTexture = nil
        swTexture = nil
        Thread.sleep(forTimeInterval: 0.05)
        attempts += 1
      }
    }
    if !ready {
      NSLog("VideoOutput: texture swap to \(target ? "HW" : "SW") failed")
      // Best effort: put the hardware texture back so the video is not
      // left without one.
      if target == false {
        usingHardwareAcceleration = true
        _createTexture(hardware: true)
        DispatchQueue.main.sync { [weak self] in
          guard let that = self else { return }
          that.registerTextureId()
        }
      }
      return false
    }

    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // textureUpdateCallback must run on the main thread
      that.registerTextureId()
    }
    return true
  }

  /// Attaches / detaches the PiP frame feed: each frame the software
  /// texture renders is handed to [handler]. A no-op while the live
  /// texture is the hardware one (PiP only runs on the software path).
  public func setFrameHandler(_ handler: ((CVPixelBuffer) -> Void)?) {
    worker.enqueue {
      self.swTexture?.onFrameRendered = handler
    }
  }

  // Must be run on the main thread
  private func registerTextureId() {
    // Textures must be registered on the platform thread.
    guard let texture = texture else { return }
    textureId = registry.register(texture)
    // textureUpdateCallback must run on the main thread
    textureUpdateCallback(textureId, CGSize(width: 0, height: 0))
  }

  private func disposeTextureId() {
    let registry_ = self.registry
    let textureId_ = self.textureId
    textureId = -1
    DispatchQueue.main.async {
      // Textures must be unregistered on the platform thread
      registry_.unregisterTexture(textureId_)
    }
  }

  public func updateCallback() {
    worker.enqueue {
      self._updateCallback()
    }
  }

  private func _updateCallback() {
    if disposed || swappingTexture { return }
    guard let texture = texture else { return }

    let size = videoSize

    if size.width == 0 || size.height == 0 {
      return
    }

    if currentSize != size {
      currentSize = size

      texture.resize(size)
      DispatchQueue.main.sync { [weak self] in
        guard let that = self else { return }
        // textureUpdateCallback must run on the main thread
        that.textureUpdateCallback(that.textureId, size)
      }
    }

    if disposed {
      return
    }

    texture.render(size)
    DispatchQueue.main.sync { [weak self] in
      guard let that = self else { return }
      // Textures must be marked as available from the main thread
      that.registry.textureFrameAvailable(that.textureId)
    }
  }

    private var videoSize: CGSize {
        // fixed size
        if width != nil && height != nil {
            return CGSize(
                width: Double(width!),
                height: Double(height!)
            )
        }

        let params = MPVHelpers.getVideoOutParams(handle)
        return CGSize(
            width: Double(width ?? (params.rotate == 0 || params.rotate == 180
                                    ? params.dw
                                    : params.dh)),
            height: Double(height ?? (params.rotate == 0 || params.rotate == 180
                                      ? params.dh
                                      : params.dw))
        )
  }
}
