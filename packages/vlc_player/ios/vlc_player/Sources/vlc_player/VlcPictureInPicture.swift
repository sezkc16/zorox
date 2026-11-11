import AVFoundation
import AVKit
import CoreMedia
import os
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
  /// [VlcPlayerPlatformView.sendPictureInPictureEvent]. The second value is
  /// the failure's reason in the system's words, when there is one: the
  /// delegate's `failedToStart` error, or why the start never became
  /// possible. Dart shows it on screen, so a silent button has a reason the
  /// viewer can report.
  private let onStateChanged: (Bool, String?) -> Void

  private var displayLayer: AVSampleBufferDisplayLayer?
  /// The layer has to live in a window for the PiP controller to take it.
  /// Sized to the video picture's on-screen rect, so the system has a real
  /// source frame to open from; it takes no touches, so it never sits on
  /// top of a button.
  private var hostView: UIView?
  /// Diagnostics for the PiP attempt, readable in Console.app: every refusal
  /// logs its reason, so a phone that silently shows no window can be told
  /// apart from one that never asked. (No user data: sizes, counts, errors.)
  private static let pipLog = OSLog(subsystem: "com.toji.zorox", category: "pip")

  /// How long the controller has to report `isPictureInPicturePossible`
  /// before the attempt is abandoned. The window normally opens in well
  /// under a second; Dart's own watchdog is longer than this (five seconds),
  /// so giving up here reports the failure first and the two never race.
  private static let possibleTimeout: TimeInterval = 3.0
  private var pipController: AVPictureInPictureController?
  private var feedTimer: Timer?
  /// The picture's format, kept while its size holds so a description is not
  /// built for every frame.
  private var formatDescription: CMVideoFormatDescription?
  private var formatWidth = 0
  private var formatHeight = 0
  /// Presentation times, when the layer has no timebase to read them from.
  private var frameIndex = 0
  /// Whether a start is still waiting on `isPictureInPicturePossible`.
  private var wantsStart = false
  /// The wait for `isPictureInPicturePossible`, one-shot: it fires when the
  /// layer has presented content, which is when the system will accept a
  /// start. A start issued before that is silently dropped — no window, no
  /// failure callback — which is what the button did before this gate. The
  /// `.initial` option also fires at once with the value the controller
  /// already has, so a start on an already-possible controller goes out in
  /// the same call.
  private var possibleObs: NSKeyValueObservation?
  private var pipStartTimeout: DispatchWorkItem?
  /// Frames handed to the layer since this attempt began, and why the last
  /// feed failed — the timeout's report, so a dead attempt says which of
  /// the two it was.
  private var framesEnqueued = 0
  private var lastFeedFailure: String?

  /// Whether the window is up. The answer to a second start while it is.
  var isActive: Bool {
    return pipController?.isPictureInPictureActive ?? false
  }

  /// Whether the system would accept a start right now. The debug line Dart
  /// shows when a start fails.
  @available(iOS 15.0, *)
  var isPictureInPicturePossible: Bool {
    return pipController?.isPictureInPicturePossible ?? false
  }

  init(player: VlcPlayerPlatformView, onStateChanged: @escaping (Bool, String?) -> Void) {
    self.player = player
    self.onStateChanged = onStateChanged
    super.init()
  }

  deinit {
    dispose()
  }

  /// Opens the PiP window. True means the request went out — or is waiting
  /// on `isPictureInPicturePossible` (see [prepare]); the result — started,
  /// or failed to start — arrives through [onStateChanged]. A second start
  /// while one is already pending answers true without doing anything twice.
  ///
  /// False when the device cannot do PiP, when the player is view-backed and
  /// has no texture to feed from, or when there is no window to host the
  /// layer in. Each refusal is logged, so a silent button on the phone has
  /// a reason in Console.app.
  ///
  /// [sourceRect] is the video picture's on-screen frame, which the window
  /// opens from. Nil falls back to the key window's bounds — always a real
  /// frame, never the 1x1 host that the system treated as not-displaying
  /// and silently refused to open from (no window, no failure callback).
  func start(sourceRect: CGRect? = nil) -> Bool {
    guard !isActive else {
      return true
    }
    guard !wantsStart else {
      return true
    }
    // The layer and the controller are UIKit objects: the method channel
    // calls on the main thread, but a start from anywhere else must still
    // land there, or the layer is built on a thread that never presents it.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        _ = self?.start(sourceRect: sourceRect)
      }
      return true
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      os_log("PiP refused: not supported on this device", log: Self.pipLog, type: .error)
      return false
    }
    guard let player, player.textureRenderer != nil else {
      os_log("PiP refused: no texture to feed from", log: Self.pipLog, type: .error)
      return false
    }
    guard #available(iOS 15.0, *) else {
      os_log("PiP refused: iOS 15 required", log: Self.pipLog, type: .error)
      return false
    }
    // Build now if the eager path never ran (or failed): the gate below is
    // the same either way, so a late build behaves exactly like an early
    // one.
    guard prepare(sourceRect: sourceRect) else {
      return false
    }
    guard let pipController = pipController else {
      return false
    }
    // The eager host sits under Flutter's view so it never covers the
    // controls; for the start itself it comes to the front, re-framed to
    // the picture's current rect, so the layer is unoccluded while the
    // system decides. The chrome is already coming off on the Dart side,
    // so nothing is left for it to cover.
    if let view = hostView, let window = view.window {
      updateSourceRect(sourceRect)
      window.addSubview(view)
    }
    // libVLC's audio output can reset the session after play starts, and
    // PiP refuses to open on a session that is not playback. Re-assert it
    // at the moment of the request — the player holds the session for the
    // whole film, so this only repairs a category someone else moved.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)
    os_log(
      "PiP audio session: category=%{public}@",
      log: Self.pipLog, type: .debug, session.category.rawValue)

    // The gate. A start issued while `isPictureInPicturePossible` is false
    // is silently dropped — no window, no failure callback — so the button
    // used to do nothing at all: a freshly created controller almost always
    // reports false, and only flips to true once the layer is in a window
    // and showing content. Start the moment the system says it is possible,
    // and give up on a timer so a layer that never presents still reports
    // its failure instead of hanging. `.initial` fires at once with the
    // value the controller already has, so a start on an eager controller
    // that is already possible goes out in the same call.
    wantsStart = true
    os_log("PiP waiting for isPictureInPicturePossible", log: Self.pipLog, type: .debug)
    possibleObs = pipController.observe(
      \.isPictureInPicturePossible, options: [.initial, .new]
    ) { [weak self] controller, _ in
      guard let self, self.wantsStart, controller.isPictureInPicturePossible else { return }
      self.wantsStart = false
      self.beginPictureInPicture()
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.wantsStart else { return }
      let reason = "Picture-in-picture never became possible "
        + "(frames enqueued: \(self.framesEnqueued), "
        + "last feed failure: \(self.lastFeedFailure ?? "none"))"
      os_log(
        "PiP gave up: %{public}@",
        log: Self.pipLog, type: .error, reason)
      self.wantsStart = false
      self.teardown()
      self.onStateChanged(false, reason)
    }
    pipStartTimeout = timeout
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.possibleTimeout, execute: timeout)
    return true
  }

  /// The start itself, once the system will accept it. The window opening,
  /// or failing to, arrives through the delegate and [onStateChanged].
  /// Idempotent: the observation's `.initial` fire, a later change and a
  /// second tap all land here, and only the first starts.
  @available(iOS 15.0, *)
  private func beginPictureInPicture() {
    guard let pipController else { return }
    pipStartTimeout?.cancel()
    pipStartTimeout = nil
    possibleObs?.invalidate()
    possibleObs = nil
    os_log(
      "PiP starting (frames enqueued: %{public}d)",
      log: Self.pipLog, type: .debug, framesEnqueued)
    pipController.startPictureInPicture()
  }

  /// Re-frames the host view (and its layer) to the video picture's current
  /// on-screen rect. The eager build only knows the window's bounds; the tap
  /// knows the picture. A missing or degenerate rect falls back to the
  /// window's bounds, so a bad measurement degrades to a full-screen source
  /// rather than stranding the window.
  private func updateSourceRect(_ sourceRect: CGRect?) {
    guard let window = Self.keyWindow, let view = hostView, let layer = displayLayer else {
      return
    }
    let bounds = window.bounds
    var frame = sourceRect ?? bounds
    frame = frame.intersection(bounds)
    if frame.isEmpty || frame.width < 2 || frame.height < 2 {
      frame = bounds
    }
    view.frame = frame
    layer.frame = view.bounds
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

  /// Builds the layer, host view and controller, and starts the feed — but
  /// does NOT start the window. Called eagerly when playback starts, so a
  /// controller already exists — and is already possible — by the time the
  /// viewer taps PiP or leaves the app: `canStartPictureInPictureAutomaticallyFromInline`
  /// only works when the controller exists and is possible BEFORE the app
  /// goes away, and a controller built on tap has neither. The tap path in
  /// [start] calls this too when the eager build never ran, so a late build
  /// behaves exactly like an early one. Idempotent: a second call answers
  /// true without rebuilding.
  ///
  /// False when the device cannot do PiP, when the player is view-backed and
  /// has no texture to feed from, or when there is no window to host the
  /// layer in. The host view goes UNDER Flutter's view
  /// (`insertSubview(_:at: 0)`), so the eager layer never covers the
  /// controls; [start] brings it to the front for the start itself.
  @available(iOS 15.0, *)
  func prepare(sourceRect: CGRect? = nil) -> Bool {
    if pipController != nil {
      return true
    }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      os_log("PiP prepare refused: not supported on this device", log: Self.pipLog, type: .error)
      return false
    }
    guard let player, player.textureRenderer != nil else {
      os_log("PiP prepare refused: no texture to feed from", log: Self.pipLog, type: .error)
      return false
    }
    guard let window = Self.keyWindow else {
      os_log("PiP prepare refused: no window to host the layer", log: Self.pipLog, type: .error)
      return false
    }
    // libVLC's audio output can reset the session after play starts, and PiP
    // refuses to open on a session that is not playback. Re-assert it when
    // the controller is built — [start] re-asserts it again at the moment of
    // the request, in case libVLC moved it since.
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    try? session.setActive(true)

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

    let view = UIView(frame: window.bounds)
    view.isUserInteractionEnabled = false
    layer.frame = view.bounds
    view.layer.addSublayer(layer)
    // Under Flutter's view: the layer is in the window (which is what the
    // system needs to present its content) but it never draws over the app
    // UI. If an occluded layer ever turns out not to count as presenting,
    // the fallback is a plain `addSubview` here — the tap path brings the
    // view to the front for the start itself either way.
    window.insertSubview(view, at: 0)

    // The source frame: the video picture's real on-screen rect, so the
    // system has something to animate from and treats the content as
    // displaying. A 1x1 host was treated as not-displaying and
    // startPictureInPicture silently did nothing — no window, and no failure
    // callback either, which is why the button froze the screen instead of
    // failing cleanly. The rect is the picture's, not the whole screen, so
    // the layer never draws over the app UI above or below the picture.
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
    framesEnqueued = 0
    lastFeedFailure = nil
    updateSourceRect(sourceRect)

    // The feed, from now: `isPictureInPicturePossible` stays false until
    // the layer has presented a frame, and the eager build is what gives
    // it frames to present long before the tap.
    startFeed()
    _ = feedFrame()
    os_log("PiP controller prepared", log: Self.pipLog, type: .debug)
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
  /// frame by definition. Every failure records its reason in
  /// [lastFeedFailure], so the gate's timeout can report it (and only the
  /// first failure of a run is logged — a dead feed at 30 fps must not
  /// flood the log).
  @discardableResult
  private func feedFrame() -> Bool {
    guard let layer = displayLayer, layer.isReadyForMoreMediaData else {
      lastFeedFailure = "layer not ready"
      return false
    }
    if layer.status == .failed {
      // A bad buffer fails the layer; flush resets it so the next frame can
      // go in, instead of every later feed failing the same way.
      let error = layer.error
      layer.flush()
      os_log(
        "PiP layer failed (%{public}@); flushed",
        log: Self.pipLog, type: .error,
        error?.localizedDescription ?? "unknown")
      lastFeedFailure = "layer failed"
      return false
    }
    // copyPixelBuffer() follows the Create Rule ("copy" in the name): it
    // hands back a +1 retained reference, so takeRetainedValue() both
    // unwraps the Unmanaged and balances the retain (takeUnretainedValue
    // would leak one reference per frame). It does NOT consume the frame:
    // CopyPending keeps `pending_`, so Flutter's texture and this feed each
    // get a retained copy of the latest picture.
    guard let pixelBuffer = player?.textureRenderer?.copyPixelBuffer()?
      .takeRetainedValue() else {
      lastFeedFailure = "no frame from texture"
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
        lastFeedFailure = "no format description"
        return false
      }
      formatDescription = fresh
      formatWidth = width
      formatHeight = height
    }
    guard let formatDescription else {
      lastFeedFailure = "no format description"
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
      lastFeedFailure = "no sample buffer"
      return false
    }
    // Show at once: the window opens on this frame, and a buffer whose
    // presentation time the layer has already passed would otherwise sit
    // unseen while `isPictureInPicturePossible` stays false.
    CMSetAttachment(
      sampleBuffer,
      key: kCMSampleAttachmentKey_DisplayImmediately,
      value: kCFBooleanTrue,
      attachmentMode: kCMAttachmentMode_ShouldPropagate)
    layer.enqueue(sampleBuffer)
    framesEnqueued += 1
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
  /// here, and only the first finds anything to do. The readiness gate is
  /// cancelled here too: a pending start must not pop a window up after the
  /// viewer has already come back to the full player.
  private func teardown() {
    possibleObs?.invalidate()
    possibleObs = nil
    pipStartTimeout?.cancel()
    pipStartTimeout = nil
    wantsStart = false
    framesEnqueued = 0
    lastFeedFailure = nil
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
    os_log("PiP window opened", log: Self.pipLog, type: .debug)
    onStateChanged(true, nil)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    os_log("PiP window closed", log: Self.pipLog, type: .debug)
    teardown()
    onStateChanged(false, nil)
  }

  func pictureInPictureControllerFailedToStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController,
    error: Error
  ) {
    os_log(
      "PiP failed to start: %{public}@",
      log: Self.pipLog, type: .error, error.localizedDescription)
    teardown()
    // The error, in the system's words — Dart shows it on screen, so a
    // failed start has a reason the viewer can report.
    onStateChanged(false, error.localizedDescription)
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
