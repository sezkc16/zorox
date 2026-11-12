# media_kit_video 2.0.1 + mpv PiP (ZoroX v19 fork)

This package is media_kit_video 2.0.1 with the additions ZoroX needs for
Picture-in-Picture from the mpv (media_kit) player. The package name and
version are deliberately UNCHANGED, so the app can point at this folder
with a path dependency and nothing else (including media_kit's own
dependency on `media_kit_video ^2.0.1`) needs to change.

## Why a fork is needed

media_kit renders mpv through an OpenGL ES texture. iOS forbids GPU work
in the background, so that path cannot feed PiP. libmpv also has a
software render API (`mpv_render_context_create` with API type `"sw"`)
that renders frames into CPU buffers; mpv allows ONE render context per
handle, so on PiP start the GL context must be freed and the SW one
created, and on PiP stop the swap runs the other way. That swap can only
be done inside media_kit_video's native iOS code, hence the fork.

## Files changed (all under `ios/Classes/plugin/common/`)

- **`TextureHW.swift`** — `isReady` (render context non-nil); `initMPV`
  no longer calls `MPVHelpers.checkError` (which calls `exit(1)`) when
  render-context creation fails: it logs, leaves the context nil and
  returns, so a failed swap is a retry instead of a crash; `disposeMPV`
  and `render()` guard on a nil context.
- **`TextureSW.swift`** — same non-crashing `initMPV` / guards as above;
  `onFrameRendered: ((CVPixelBuffer) -> Void)?` fires after a frame is
  rendered (and before Flutter is told it is available), so PiP's alpha
  fix lands before either reader; `isReady`; the pixel-buffer pool is
  now IOSurface-backed too (`kCVPixelBufferIOSurfacePropertiesKey`),
  which the PiP layer requires.
- **`TextureSWContext.swift`** — IOSurface property added to the pool
  buffers (see above). No change to how Flutter displays frames.
- **`VideoOutput.swift`** — rewritten around a swap:
  - `texture` is now optional (nil during a swap).
  - `setHardwareAcceleration(_ enabled: Bool, completion:)` swaps the
    render path ASYNCHRONOUSLY on the worker and calls the completion
    on the main thread. It MUST NOT block the caller: the worker
    unregisters the old texture on the main thread, so a caller that
    waits on the main thread deadlocks. It frees the old texture (and
    with it the old mpv render context) before creating the new one,
    retries creation up to 10 times at 50 ms (the old context may still
    be released by a frame in flight), and on failure best-effort
    restores HW. Returns whether the new context was created.
  - `setFrameHandler(_:)` attaches/detaches the PiP frame feed
    (`swTexture?.onFrameRendered`).
  - `registerTextureId()` guards on a nil texture; `_updateCallback`
    returns early while `swappingTexture` or after `disposed`.
  - `_init` refactored to `_createTexture(hardware:)`.
- **`VideoOutputManager.swift`** — `setHardwareAcceleration(handle:enabled:) -> Bool` and `setFrameHandler(handle:handler:)` delegating to the VideoOutput.
- **`MpvPip.swift`** (NEW) — the PiP controller:
  - `AVSampleBufferDisplayLayer` + `AVPictureInPictureController` (sample-buffer playback delegate).
  - `start(handle:duration:hostView:manager:)` — audio session
    (.playback/moviePlayback), swaps to software, attaches the frame
    feed, puts the layer in the Flutter view (160x90, index 0 — it MUST
    be in a visible window with a non-zero frame or PiP is black),
    opens the PiP window.
  - `enqueueFrame` — forces alpha opaque (`| 0xFF000000` on every pixel;
    mpv "bgr0" leaves alpha 0, a strong black-PiP suspect), wraps the
    buffer in a CMSampleBuffer (DisplayImmediately), flushes the layer
    when its status is `.failed`, enqueues it; tracks `framesEnqueued`
    and `meanLuma` (mean luma of every 30th buffer — about 0 while
    frames increase means the feed is black).
  - Playback delegate talks straight to mpv: `mpv_set_property`
    ("pause", flag) and `mpv_command_string("seek <s> relative")`.
  - `stop()` / `teardown()` — stops PiP, detaches the frame feed,
    removes the layer, swaps back to hardware (idempotent).
  - `status()` — diagnostics map (`framesEnqueued`, `meanLuma`,
    `layerStatus`, `layerError`, `isPictureInPictureActive`,
    `isPictureInPicturePossible`, `isSupported`).
- **`MediaKitVideoPlugin.swift`** — registers the PiP channel
  `dev.akash.skystream.mpv_pip` (methods `isSupported`, `start`,
  `stop`, `status`; events `onPipStarted` / `onPipStopped` back to
  Dart), holds the Flutter view as the PiP layer host.

## Dart side (in the app, not this package)

`lib/features/player/presentation/mpv/mpv_player_screen.dart`:
- before starting PiP, `setProperty('hwdec', 'videotoolbox-copy')`
  (GPU-free decode, frames copied to system memory); on stop/restore,
  `setProperty('hwdec', 'videotoolbox')`.
- the PiP button (bottom toolbar + top bar) only appears when
  `isSupported` returns true; manual button only (no auto-PiP yet).
- `status` is surfaced in an in-app note for the first builds, so a
  black feed can be diagnosed on the phone (frames + luma).

## Testing notes

- The swap is ordered on VideoOutput's serial worker thread, so a
  PiP start/stop cannot race a frame render.
- TextureSW has a 3-buffer pool; the PiP layer retains each enqueued
  buffer and it is reused ~3 frames (~100 ms) later, so overlap is
  unlikely. If tearing appears, bump the pool or copy buffers.
- Render at 720p while in PiP (4K runs hot on the software path);
  HDR/Dolby Vision tone mapping and shaders are weaker on it.
- If a build update of media_kit_video lands upstream, re-apply this
  diff onto the new 2.x (the changed files are all in
  `ios/Classes/plugin/common/`).
