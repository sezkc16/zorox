import AVKit
import CoreMedia
import CoreVideo
import Flutter

/// Drives Picture-in-Picture from mpv's software render context.
///
/// The fork's TextureSW renders each frame into a CVPixelBuffer; the
/// VideoOutput forwards those buffers to [enqueueFrame], which wraps them
/// in CMSampleBuffers and feeds an AVSampleBufferDisplayLayer that an
/// AVPictureInPictureController shows. Play/pause/seek from the PiP
/// controls go straight to mpv (not through Dart) because the Dart round
/// trip is unreliable in the background.
///
/// Diagnostics (for the in-app verification the v19 build carries):
/// [framesEnqueued] counts the buffers fed to the layer, [meanLuma] is the
/// mean luma of every 30th buffer (about 0 while frames increase means the
/// feed is black), and [layerStatus]/[layerError] report the layer's state.
final class MpvPip: NSObject, AVPictureInPictureControllerDelegate,
                    AVPictureInPictureSampleBufferPlaybackDelegate {

  let layer = AVSampleBufferDisplayLayer()
  var pip: AVPictureInPictureController?
  var mpv: OpaquePointer?
  var duration: Double = 0
  var paused = false
  var framesEnqueued = 0
  var meanLuma: Double = 0
  var onStarted: (() -> Void)?
  var onStopped: (() -> Void)?

  private var frameCount = 0
  private var didTeardown = false
  private var manager: VideoOutputManager?
  private var handle: Int64 = 0
  private var hostView: UIView?

  /// Whether this device can show PiP at all.
  static var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  /// Starts PiP for the mpv handle: swaps the render path to software,
  /// attaches the frame feed, and opens the PiP window. Asynchronous —
  /// [completion] is called on the main thread with whether PiP opened.
  /// Leaves nothing half-built on failure.
  func start(
    handle: Int64,
    duration: Double,
    hostView: UIView,
    manager: VideoOutputManager,
    completion: @escaping (Bool) -> Void
  ) {
    guard !isActive else { completion(false); return }
    guard let mpvHandle = OpaquePointer(bitPattern: Int(handle)) else {
      completion(false)
      return
    }
    guard MpvPip.isSupported else { completion(false); return }

    self.handle = handle
    self.mpv = mpvHandle
    self.duration = duration
    self.manager = manager
    self.hostView = hostView
    didTeardown = false

    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback,
        mode: .moviePlayback
      )
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("MpvPip: audio session failed: \(error)")
    }

    // 1. The software render context: free the GL one first (mpv allows
    //    one render context per handle), then attach the frame feed.
    //    Async — see VideoOutput.setHardwareAcceleration (blocking the
    //    main thread here would deadlock the unregister).
    manager.setHardwareAcceleration(handle: handle, enabled: false) { [weak self] swapped in
      guard let self = self else { completion(false); return }
      if !swapped || self.didTeardown {
        self.reset()
        completion(false)
        return
      }
      self.manager?.setFrameHandler(handle: handle) { [weak self] pb in
        self?.enqueueFrame(pb)
      }

      // 2. The layer MUST be in a visible window with a non-zero frame, or
      //    PiP is black. It rides on the Flutter view, behind the engine's
      //    own layers, and is removed when PiP stops.
      self.layer.frame = CGRect(x: 0, y: 0, width: 160, height: 90)
      self.layer.videoGravity = .resizeAspect
      hostView.layer.insertSublayer(self.layer, at: 0)

      // 3. The PiP window.
      let source = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: self.layer,
        playbackDelegate: self
      )
      let controller = AVPictureInPictureController(contentSource: source)
      controller.delegate = self
      self.pip = controller
      if !(self.pip?.isPictureInPicturePossible ?? false) {
        self.teardown()
        completion(false)
        return
      }
      self.pip?.startPictureInPicture()
      self.onStarted?()
      completion(true)
    }
  }

  var isActive: Bool { pip != nil && !didTeardown }

  /// Stops PiP (Dart-initiated). The delegate's stop callback runs
  /// [teardown] too, which is idempotent.
  func stop() {
    pip?.stopPictureInPicture()
    teardown()
  }

  /// Frees everything PiP owns: the frame feed, the layer, the window, and
  /// the software render path (back to hardware). Idempotent.
  func teardown() {
    if didTeardown { return }
    didTeardown = true
    if let manager = manager, handle != 0 {
      manager.setFrameHandler(handle: handle, handler: nil)
      // Back to the hardware render path for the Flutter texture.
      // Fire-and-forget: the video keeps playing on the software texture
      // until the swap completes, and the re-registered texture id reaches
      // Dart via VideoOutput.Resize.
      let handle = handle
      manager.setHardwareAcceleration(handle: handle, enabled: true) { _ in }
    }
    layer.removeFromSuperlayer()
    pip = nil
    mpv = nil
    manager = nil
    hostView = nil
    onStopped?()
  }

  /// Resets the object after a failed start (nothing was built).
  private func reset() {
    mpv = nil
    manager = nil
    hostView = nil
  }

  /// One rendered frame, into the PiP layer.
  func enqueueFrame(_ pb: CVPixelBuffer) {
    // mpv's "bgr0" leaves alpha at 0, which the layer would show as
    // transparent (black). Force it opaque. Runs on the worker thread,
    // before Flutter is told the frame is available, so the write lands
    // before either reader.
    CVPixelBufferLockBaseAddress(pb, [])
    if let base = CVPixelBufferGetBaseAddress(pb) {
      let w = CVPixelBufferGetWidth(pb)
      let h = CVPixelBufferGetHeight(pb)
      let stride = CVPixelBufferGetBytesPerRow(pb)
      let px = base.assumingMemoryBound(to: UInt32.self)
      let count = stride / 4 * h
      frameCount += 1
      let sampleLuma = frameCount % 30 == 0
      var sum: UInt64 = 0
      for i in 0..<count {
        var v = px[i]
        v |= 0xFF000000
        px[i] = v
        if sampleLuma {
          let r = (v >> 16) & 0xFF
          let g = (v >> 8) & 0xFF
          let b = v & 0xFF
          sum += (UInt64(r) * 299 + UInt64(g) * 587 + UInt64(b) * 114) / 1000
        }
      }
      if sampleLuma && count > 0 {
        meanLuma = Double(sum) / Double(count)
      }
      _ = w
    }
    CVPixelBufferUnlockBaseAddress(pb, [])

    var fd: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: nil,
      imageBuffer: pb,
      formatDescriptionOut: &fd
    )
    guard let fd = fd else { return }
    var timing = CMSampleTimingInfo(
      duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
      decodeTimeStamp: .invalid
    )
    var sb: CMSampleBuffer?
    CMSampleBufferCreateReadyWithImageBuffer(
      allocator: nil,
      imageBuffer: pb,
      formatDescription: fd,
      sampleTiming: &timing,
      sampleBufferOut: &sb
    )
    guard let sb = sb else { return }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sb,
      createIfNecessary: true
    ),
       let first = (attachments as NSArray).firstObject {
      CFDictionarySetValue(
        unsafeBitCast(first, to: CFMutableDictionary.self),
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately)
          .toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
    if layer.status == .failed { layer.flush() }
    layer.enqueue(sb)
    framesEnqueued += 1
  }

  /// Diagnostics for the in-app verification (see the v19 build notes).
  func status() -> [String: Any] {
    return [
      "framesEnqueued": framesEnqueued,
      "meanLuma": meanLuma,
      "layerStatus": layer.status.rawValue,
      "layerError": layer.error?.localizedDescription ?? "",
      "isPictureInPictureActive": pip?.isPictureInPictureActive ?? false,
      "isPictureInPicturePossible": pip?.isPictureInPicturePossible ?? false,
      "isSupported": MpvPip.isSupported,
    ]
  }

  // MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

  /// Straight to mpv, not through Dart: the round trip is unreliable in
  /// the background.
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    var flag: Int32 = playing ? 0 : 1
    if let mpv = mpv {
      mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
    }
    paused = !playing
    pictureInPictureController.invalidatePlaybackState()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    let seconds = CMTimeGetSeconds(skipInterval)
    if let mpv = mpv {
      let command = "seek \(seconds) relative"
      command.withCString { cString in
        mpv_command_string(mpv, cString)
      }
    }
    completionHandler()
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    if duration <= 0 {
      // A live stream has no end; the PiP timeline is open-ended.
      return CMTimeRange(start: .zero, duration: .positiveInfinity)
    }
    return CMTimeRange(
      start: .zero,
      duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    paused
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {}

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    teardown()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("MpvPip: failed to start PiP: \(error)")
    teardown()
  }
}
