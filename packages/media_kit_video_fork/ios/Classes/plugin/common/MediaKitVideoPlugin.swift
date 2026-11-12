#if canImport(Flutter)
  import Flutter
#elseif canImport(FlutterMacOS)
  import FlutterMacOS
#endif

public class MediaKitVideoPlugin: NSObject, FlutterPlugin {
  private static let CHANNEL_NAME = "com.alexmercerind/media_kit_video"

  /// Fork (ZoroX v19): the mpv PiP channel. The Dart player calls it to
  /// start/stop PiP; it notifies Dart when PiP starts or stops.
  private static let PIP_CHANNEL_NAME = "dev.akash.skystream.mpv_pip"

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if canImport(Flutter)
      let binaryMessenger = registrar.messenger()
      let registry = registrar.textures()
      let utils: UtilsProtocol? = nil
    #elseif canImport(FlutterMacOS)
      let binaryMessenger = registrar.messenger
      let registry = registrar.textures
      let utils: UtilsProtocol? = Utils(registrar)
    #endif

    let channel = FlutterMethodChannel(
      name: CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    let instance = MediaKitVideoPlugin(
      registry: registry,
      channel: channel,
      utils: utils
    )
    registrar.addMethodCallDelegate(instance, channel: channel)

    // Fork: the PiP channel, handled by the same instance (its method
    // names do not collide with the video channel's).
    let pipChannel = FlutterMethodChannel(
      name: PIP_CHANNEL_NAME,
      binaryMessenger: binaryMessenger
    )
    instance.pipChannel = pipChannel
    registrar.addMethodCallDelegate(instance, channel: pipChannel)
  }

  private let channel: FlutterMethodChannel
  private let videoOutputManager: VideoOutputManager
  private let utils: UtilsProtocol?

  /// Fork: PiP state.
  private var pipChannel: FlutterMethodChannel?
  private var pip: MpvPip?

  /// The Flutter view the PiP display layer rides on. The layer must be
  /// in a visible window with a non-zero frame, or PiP is black. Resolved
  /// lazily at PiP start (the app is foreground then, so the window is
  /// set); the v2 plugin registrar exposes no `view` accessor, so the key
  /// window's root view is used instead.
  #if canImport(Flutter)
    private static func flutterHostView() -> UIView? {
      let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
      for scene in scenes {
        if let window = scene.windows.first(where: { $0.isKeyWindow }) {
          if let view = window.rootViewController?.view {
            return view
          }
        }
      }
      for scene in scenes {
        if let window = scene.windows.first {
          if let view = window.rootViewController?.view {
            return view
          }
        }
      }
      return nil
    }
  #endif

  init(
    registry: FlutterTextureRegistry,
    channel: FlutterMethodChannel,
    utils: UtilsProtocol?
  ) {
    self.channel = channel
    videoOutputManager = VideoOutputManager(
      registry: registry
    )
    self.utils = utils
  }

  public func handle(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "VideoOutputManager.Create":
      handleCreateMethodCall(call.arguments, result)
    case "VideoOutputManager.SetSize":
      handleSetSizeMethodCall(call.arguments, result)
    case "VideoOutputManager.Dispose":
      handleDisposeMethodCall(call.arguments, result)
    case "Utils.EnterNativeFullscreen":
      handleEnterNativeFullscreenMethodCall(call.arguments, result)
    case "Utils.ExitNativeFullscreen":
      handleExitNativeFullscreenMethodCall(call.arguments, result)
    // Fork: mpv PiP (channel dev.akash.skystream.mpv_pip).
    case "isSupported":
      result(MpvPip.isSupported)
    case "start":
      handlePipStartMethodCall(call.arguments, result)
    case "stop":
      handlePipStopMethodCall(result)
    case "status":
      result(pip?.status() ?? [
        "framesEnqueued": 0,
        "meanLuma": 0.0,
        "layerStatus": -1,
        "layerError": "",
        "isPictureInPictureActive": false,
        "isPictureInPicturePossible": false,
        "isSupported": MpvPip.isSupported,
      ] as [String: Any])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Fork: starts mpv PiP. Arguments: handle (the mpv handle as an int),
  /// duration (seconds, 0 for live).
  private func handlePipStartMethodCall(
    _ arguments: Any?,
    _ result: @escaping FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handle: Int64?
    if let h = args?["handle"] as? Int64 {
      handle = h
    } else if let h = args?["handle"] as? Int {
      handle = Int64(h)
    } else if let h = args?["handle"] as? NSNumber {
      handle = h.int64Value
    } else {
      handle = nil
    }
    let duration = (args?["duration"] as? NSNumber)?.doubleValue ?? 0
    guard let handle = handle else {
      return result(FlutterError(
        code: "bad_arguments",
        message: "PiP start needs an mpv handle",
        details: nil
      ))
    }
    guard let hostView = Self.flutterHostView() else {
      return result(FlutterError(
        code: "no_host_view",
        message: "PiP needs a view in a window",
        details: nil
      ))
    }
    if pip == nil { pip = MpvPip() }
    guard let pip = pip else {
      return result(FlutterError(
        code: "pip_failed",
        message: "Could not create PiP",
        details: nil
      ))
    }
    pip.onStarted = { [weak self] in
      self?.pipChannel?.invokeMethod("onPipStarted", arguments: nil)
    }
    pip.onStopped = { [weak self] in
      self?.pipChannel?.invokeMethod("onPipStopped", arguments: nil)
    }
    // Async: the texture swap runs on the video worker and reports back
    // on the main thread (blocking here would deadlock the unregister).
    pip.start(
      handle: handle,
      duration: duration,
      hostView: hostView,
      manager: videoOutputManager
    ) { [weak self] started in
      guard let self = self else { return }
      if started {
        result(true)
      } else {
        self.pip = nil
        result(FlutterError(
          code: "pip_failed",
          message: "Picture-in-picture could not start",
          details: nil
        ))
      }
    }
  }

  /// Fork: stops mpv PiP (and restores the hardware render path).
  private func handlePipStopMethodCall(_ result: @escaping FlutterResult) {
    pip?.stop()
    pip = nil
    result(nil)
  }

  private func handleCreateMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)
    let configDict = args?["configuration"] as! [String: Any]
    let configuration = VideoOutputConfiguration.fromDict(configDict)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.create(
      handle: handle!,
      configuration: configuration,
      textureUpdateCallback: { (_ textureId: Int64, _ size: CGSize) in
        self.channel.invokeMethod(
          "VideoOutput.Resize",
          arguments: [
            "handle": handle!,
            "id": textureId,
            "rect": [
              "top": 0,
              "left": 0,
              "width": size.width,
              "height": size.height,
            ],
          ] as [String: Any]
        )
      }
    )

    result(nil)
  }

  private func handleSetSizeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let widthStr = args?["width"] as! String
    let heightStr = args?["height"] as! String

    let handle: Int64? = Int64(handleStr)
    let width: Int64? = Int64(widthStr)
    let height: Int64? = Int64(heightStr)

    assert(handle != nil, "handle must be an Int64")

    self.videoOutputManager.setSize(
      handle: handle!,
      width: width,
      height: height
    )

    result(nil)
  }

  private func handleDisposeMethodCall(
    _ arguments: Any?,
    _ result: FlutterResult
  ) {
    let args = arguments as? [String: Any]
    let handleStr = args?["handle"] as! String
    let handle: Int64? = Int64(handleStr)

    assert(handle != nil, "handle must be an Int64")

    videoOutputManager.destroy(
      handle: handle!
    )

    result(nil)
  }

  private func handleEnterNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.enterNativeFullscreen()
    result(nil)
  }

  private func handleExitNativeFullscreenMethodCall(
    _: Any?,
    _ result: FlutterResult
  ) {
    if utils == nil {
      return result(FlutterMethodNotImplemented)
    }

    utils?.exitNativeFullscreen()
    result(nil)
  }
}
