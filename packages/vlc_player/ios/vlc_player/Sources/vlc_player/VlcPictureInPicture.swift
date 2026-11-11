import AVFoundation
import AVKit
import CoreMedia
import UIKit

/// Picture-in-picture for a texture-backed player, fed from libVLC's frames.
///
/// VLC has no AVPlayerLayer, so the PiP window cannot be an AVPlayerLayer
/// capture: an AVSampleBufferDisplayLayer is fed the decoded frames instead,
/// polled off the player's texture renderer, and handed to an
/// AVPictureInPictureController as its content source.
///
/// iOS 15 or later: the sample-buffer content source did not exist before it.
/// Below that, and on a device with no PiP support, `start()` answers false
/// and the app hides the button — see
/// [VlcPlayerPlatformView.startPictureInPicture].
final class VlcPictureInPictureController: NSObject {
  /// The player this feeds from. Weak: the player owns this controller.
  private weak var player: VlcPlayerPlatformView?

  /// Called with the window's state whenever it changes — started, stopped,
  /// or failed to start — so Dart can hide and show the chrome. See
  /// [VlcPlayerPlatformView.sendPictureInPictureEvent].
  private let onStateChanged: (Bool) -> Void

  private var displayLayer: AVSampleBufferDisplayLayer?
  /// The layer has to live in a window for the PiP controller to take it.
  /// Sized to the video picture's on-screen rect, so the system has a real
  /// source frame to open from; it takes no touches, so it never sits on
  /// top of a button.
  private var hostView: UIView?
  private var pipController: AVPictureInPictureController?
  private var feedTimer: Timer?
  /// The picture's format, kept while its size holds so a description is not
  /// built for every frame.
  private var formatDescription: CMVideoFormatDescription?
  private var formatWidth = 0
  private var formatHeight = 0
  /// Presentation times, when the layer has no timebase to read them from.
  private var frameIndex = 0

  /// Whether the window is up. The answer to a second start while it is.
  var isActive: Bool {
    return pipController?.isPictureInPictureActive ?? false
  }

  init(player: VlcPlayerPlatformView, onStateChanged: @escaping (Bool) -> Void) {
    self.player = player
    self.onStateChanged = onStateChanged
    super.init()
  }

  deinit {
    dispose()
  }

  /// Opens the PiP window. True means the request went out; the result —
  /// started, or failed to start — arrives through [onStateChanged].
  ///
  /// False when the device cannot do PiP, when the player is view-backed and
  /// has no texture to feed from, or when there is no picture yet to show.
  ///
  /// [sourceRect] is the video picture's on-screen frame, which the window
  /// opens from. Nil falls back to the key window's bounds — always a real
  /// frame, never the 1x1 host that the system treated as not-displaying
  /// and silently refused to open from (no window, no failure callback).
  func start(sourceRect: CGRect? = nil) -> Bool {
    guard !isActive else {
      return true
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      return false
    }
    guard let player, player.textureRenderer != nil else {
      return false
    }
    if #available(iOS 15.0, *) {
      return startSampleBufferPiP(sourceRect: sourceRect)
    } else {
      return false
    }
  }

  /// Closes the PiP window, if one is up. The stop completing is what reports
  /// it, through [onStateChanged]; when there is no window to close there is
  /// nothing to report.
  func stop() {
    guard let pipController else {
      return
    }
    if pipController.isPictureInPictureActive {
      pipController.stopPictureInPicture()
    } else {
      // Asked to stop before the start landed, or after it failed: no
      // didStop is coming, so the feed ends here.
      teardown()
    }
  }

  /// Stops the window and drops the feed and the layer, for dispose.
  ///
  /// The window's own didStop still fires after this and is a no-op there.
  /// No state is reported from here: the player is going away with it, and
  /// Dart's controller is being disposed at the same time.
  func dispose() {
    pipController?.stopPictureInPicture()
    teardown()
  }

  @available(iOS 15.0, *)
  private func startSampleBufferPiP(sourceRect: CGRect?) -> Bool {
    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    // The layer's own clock, running at host time, so the presentation times
    // the feed stamps are read against the same clock that advances them.
    var timebase: CMTimebase?
    if CMTimebaseCreateWithMasterClock(
      allocator: kCFAllocatorDefault,
      masterClock: CMClockGetHostTimeClock(),
      timebaseOut: &timebase) == noErr,
      let timebase {
      layer.controlTimebase = timebase
      CMTimebaseSetRate(timebase, rate: 1.0)
    }

    // The source frame: the video picture's real on-screen rect, so the
    // system has something to animate from and treats the content as
    // displaying. A 1x1 host was treated as not-displaying and
    // startPictureInPicture silently did nothing — no window, and no failure
    // callback either, which is why the button froze the screen instead of
    // failing cleanly. The rect is the picture's, not the whole screen, so
    // the layer never draws over the app UI above or below the picture.
    // A missing or degenerate rect falls back to the window's bounds, so a
    // bad measurement degrades to a full-screen source rather than
    // stranding the window again. The host takes no touches, so it can
    // never sit on top of a button.
    guard let window = Self.keyWindow else {
      return false
    }
    let bounds = window.bounds
    var frame = sourceRect ?? bounds
    frame = frame.intersection(bounds)
    if frame.isEmpty || frame.width < 2 || frame.height < 2 {
      frame = bounds
    }
    let view = UIView(frame: frame)
    view.isUserInteractionEnabled = false
    layer.frame = view.bounds
    view.layer.addSublayer(layer)
    window.addSubview(view)

    let contentSource = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: self)
    let pipController = AVPictureInPictureController(contentSource: contentSource)
    pipController.delegate = self
    // The system may start PiP itself when the viewer leaves the app while
    // a film is playing: that is the Home-swipe path, and it needs a
    // controller to already exist - which is also why the screen starts PiP
    // explicitly when the app resigns active (see `VlcPlayerScreen`), rather
    // than relying on this alone. The flag is the system's own auto-start
    // backstop; the Dart-side start on `inactive` is the primary mechanism.
    // (The flag was `false`, with a comment that only the button opens the
    // window - which is also why swiping home did nothing at all.)
    pipController.canStartPictureInPictureAutomaticallyFromInline = true
    // The host view's frame above is the source frame: where the window
    // animates from, and where it restores to. There is no sourceView to
    // set on this controller — the display layer's own view is the source.
    displayLayer = layer
    hostView = view
    self.pipController = pipController

    // One frame first, so the window opens on a picture rather than black,
    // and so a player with nothing decoded yet answers false instead of
    // opening a window that can only fail.
    guard feedFrame() else {
      teardown()
      return false
    }
    startFeed()
    pipController.startPictureInPicture()
    return true
  }

  /// The window the layer lives in: the key window, or any window at all when
  /// the scene has not marked one yet.
  private static var keyWindow: UIWindow? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    return windows.first(where: \.isKeyWindow) ?? windows.first
  }

  private func startFeed() {
    feedTimer?.invalidate()
    // 30 fps: the frame rate libVLC decodes at. The timer holds the block,
    // the block holds the player weakly, so there is no cycle to break.
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      _ = self?.feedFrame()
    }
    RunLoop.main.add(timer, forMode: .common)
    feedTimer = timer
  }

  /// Pulls the newest decoded frame and hands it to the display layer.
  ///
  /// True when a frame was enqueued. False when there is none yet, when the
  /// layer is not ready for another, or when the picture could not be
  /// wrapped. A repeated frame is enqueued again with a fresh timestamp: the
  /// layer keeps showing it either way, and a paused picture is a repeated
  /// frame by definition.
  @discardableResult
  private func feedFrame() -> Bool {
    guard let layer = displayLayer, layer.isReadyForMoreMediaData else {
      return false
    }
    // copyPixelBuffer() follows the Create Rule ("copy" in the name): it
    // hands back a +1 retained reference, so takeRetainedValue() both
    // unwraps the Unmanaged and balances the retain (takeUnretainedValue
    // would leak one reference per frame).
    guard let pixelBuffer = player?.textureRenderer?.copyPixelBuffer()?
      .takeRetainedValue() else {
      return false
    }
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    if formatDescription == nil || width != formatWidth || height != formatHeight {
      var fresh: CMVideoFormatDescription?
      guard CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &fresh) == noErr,
        let fresh else {
        return false
      }
      formatDescription = fresh
      formatWidth = width
      formatHeight = height
    }
    guard let formatDescription else {
      return false
    }
    // "Now", on the layer's own timebase, so the frame is due the moment it
    // arrives: libVLC hands over no presentation timestamp of its own.
    var timing = CMSampleTimingInfo(
      duration: CMTime(value: 1, timescale: 30),
      presentationTimeStamp: currentPresentationTime(),
      decodeTimeStamp: .invalid)
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      dataReady: true,
      makeDataReadyCallback: nil,
      refcon: nil,
      formatDescription: formatDescription,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer) == noErr,
      let sampleBuffer else {
      return false
    }
    layer.enqueue(sampleBuffer)
    return true
  }

  private func currentPresentationTime() -> CMTime {
    if let timebase = displayLayer?.controlTimebase {
      return CMTimebaseGetTime(timebase)
    }
    // No timebase to read from — the layer was left to its own — so count
    // frames at the feed rate instead. Still strictly increasing, which is
    // all the layer asks of a timestamp.
    frameIndex += 1
    return CMTime(value: Int64(frameIndex), timescale: 30)
  }

  /// Ends the feed, drops the layer and lets the PiP controller go.
  ///
  /// Idempotent: the window's didStop, a failed start and dispose() all land
  /// here, and only the first finds anything to do.
  private func teardown() {
    feedTimer?.invalidate()
    feedTimer = nil
    displayLayer?.flush()
    displayLayer?.removeFromSuperlayer()
    displayLayer = nil
    hostView?.removeFromSuperview()
    hostView = nil
    formatDescription = nil
    formatWidth = 0
    formatHeight = 0
    frameIndex = 0
    pipController = nil
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension VlcPictureInPictureController: AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    onStateChanged(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    teardown()
    onStateChanged(false)
  }

  func pictureInPictureControllerFailedToStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController,
    error: Error
  ) {
    teardown()
    onStateChanged(false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    // The app is coming back to the foreground anyway; say so, and the screen
    // clears its PiP state from the didStop that follows.
    completionHandler(true)
  }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension VlcPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    return player?.pipTimeRange() ?? CMTimeRange(start: .invalid, duration: .invalid)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return !(player?.pipIsPlaying ?? false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    if playing {
      player?.play()
    } else {
      player?.pause()
    }
  }

  // The skip callback, as an async method: this SDK imports the
  // completion-handler form as async, so the completion: spelling does
  // NOT satisfy the protocol — and the two spellings share the same
  // Obj-C selector ('pictureInPictureController:skipByInterval:
  // completionHandler:'), so keeping both is a compile error. Async
  // only. (Build 42907892284: "conflicts with method ... with the same
  // Objective-C selector".)
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime
  ) async {
    player?.pipSkip(by: skipInterval.seconds)
  }

  // Called when the PiP window changes size (e.g. pinch-to-zoom). A
  // no-op here: frames are fed at the video's native size and the
  // AVSampleBufferDisplayLayer scales them, so there is no media variant
  // to switch to. (Required by the protocol — without it the type does
  // not conform at all, which was the last remaining build error.)
  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
  }
}
