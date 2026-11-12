# ZoroX v19 (2.9.18) — mpv player feature parity

Build on the mpv (media_kit) line. Approved design: Gold & Black
(#0a0a0b / #f5f2ea / #a7a49b / #d4af37), compact bottom icon toolbar
(settings / subtitles / audio / speed / lock / PiP / rotate /
fullscreen), gold seek bar above it, centre play/pause + ±10 s seek,
top bar back + title + PiP button. Sheets are Gold & Black bottom
sheets with a close handle / swipe-down to dismiss.

## v19 bug-fix build (2.9.18+2) — 11 user-reported bugs, all fixed

Version stays 2.9.18, build number bumped to +2 so the IPA is
distinguishable from the first v19 (2.9.18, no build number).

1. **Double-tap seek no longer turns on 2x.** The tap-and-hold 2x
   timer (550 ms) fired during a double-tap sequence. Now the
   double-tap handler stamps the time and cancels the hold timer, and
   both the tap-down and the timer callback suppress 2x for 800 ms
   after a double-tap seek.
2. **Playback freeze — stall watchdog + visible buffering.** The mpv
   screen had no mid-play stall detection and no recovery, and with the
   controls hidden there was no buffering indication at all (a stall
   read as a dead video). Now a watchdog (5 s tick, gated on playing +
   foreground + not-PiP + not-live) re-seeks after 10 s of no position
   advance, fails over to the next source, then fails with a message.
   A gold spinner shows over the video while buffering with the
   controls hidden.
3. **No URL on screen in landscape.** The top bar title / sub-line /
   source list / error text are sanitised: any URL-like title or label
   is replaced by the episode name, the host, or "Video"; URL tokens
   are stripped from error text.
4. **PiP works — button AND auto-PiP.** Two root causes: (a) the PiP
   button called `startPictureInPicture()` before ANY frame was
   enqueued, so `isPictureInPicturePossible` was false and the start
   failed silently (MpvPip now waits for the first enqueued frame, up
   to 3 s, and fires `onStarted` only from the delegate, not
   optimistically); (b) the mpv screen had NO lifecycle handler at
   all — no auto-PiP trigger. Now `didChangeAppLifecycleState` on
   `hidden` auto-starts PiP (playing + PiP available + not already in
   PiP) and on `resumed` exits it (VLC parity). The Video widget's
   `pauseUponEnteringBackgroundMode` was also `true` — it paused the
   engine the moment the app left, freezing the PiP picture and never
   resuming it; now `false`.
5. **Continue Watching.** The Home section already existed, but the
   mpv screen never wrote watch progress (only a scrobbling tracker).
   Now a `PlaybackProgressRecorder` is created next to the tracker,
   fed the same progress samples, and flushed on pause / dispose /
   background / episode switch — so partially-watched items appear in
   Continue Watching with a progress bar and resume at the saved
   position (also works for libVLC history entries).
6. **Episode rows show a poster.** Each episode row now has a 48x72
   rounded thumbnail (episode `posterUrl`, falling back to the series
   poster; `CachedNetworkImage`, lazy/cached, neutral film-icon
   placeholder on empty/error).
7. **Toolbar pill inset.** The pill has a 12 dp right margin (matching
   the approved premium preview) on top of the bar's 12 dp padding,
   so it is no longer flush in the corner in landscape.
8. **Top-bar PiP button removed.** PiP lives only in the bottom
   toolbar pill (+ auto-PiP on Home swipe).
9. **Premium toolbar.** Frosted-glass gold-tinted gradient pill
   (backdrop blur), 1 px hairline gold border, layered shadow + gold
   glow, inset top highlight, larger corner radius (22). Icons are
   40 px buttons / 21 px icons (30 px / 18 px on a narrow screen, 3 px
   gaps, 4 px right margin) painted in the shared gold gradient with a
   subtle drop shadow; PiP-on keeps a small gold dot under its icon.
   Same 8 icons, same order, Gold & Black only.
10. **Aspect ratio options.** The fullscreen pill icon no longer just
    toasts "Already fullscreen" — it opens an Aspect ratio sheet:
    Fit (default, whole picture), Fill / Zoom (crop to the screen, no
    bars, via BoxFit.cover), 16:9 and 4:3 (via mpv
    `video-aspect-override`). Each pick applies at once and toasts the
    mode.
11. **Subtitles render — picture subtitles routed to mpv.** The
    Flutter overlay draws from mpv's `sub-text`, which is EMPTY for
    picture subtitles (Blu-ray PGS / DVD VobSub — the "Forced" and
    "SDH" tracks inside most MKVs): there is no text to draw, and mpv
    rendered nothing either (`sub-visibility=no`), so a selected track
    showed nothing at all. Now every subtitle selection goes through
    `_selectSubtitleTrack`: picture tracks (codec in
    hdmv_pgs_subtitle / pgs / dvd_subtitle / vobsub / dvb_subtitle /
    xsub) get `sub-visibility=yes` so mpv renders the bitmaps into the
    video; text tracks keep it `no` (the overlay is the only renderer,
    and the one the drag and style panel move). Applies to the picker
    rows and the auto-select alike.


## What v19 adds (all in `lib/features/player/presentation/mpv/mpv_player_screen.dart`)

1. **Pre-play source selection** — `_resolveAndOpen` now passes
   `onCandidates` / `onProbe` / `pick` / `abandon` to `resolvePlayback`
   (the same pick/abandon race the VLC screen runs). While resolving,
   a source list shows with a "Source X of N" pill, each row with its
   probe status (checking / reachable / unseekable / unreachable /
   not a video); tapping a row plays it; backing out abandons the
   resolve and leaves the player. Row keys are
   `player-startup-row-$index` (matching VLC).
2. **Episode picker** — `effectiveEpisodes` / `nextEpisodeFor` /
   `previousEpisodeFor` (episode_navigator.dart). The settings sheet has
   an Episodes section (tap to switch, "S1 E1 · Episode 1" rows) and
   the toolbar has previous/next episode buttons. Switching mirrors
   VLC `_startEpisode`: reset per-episode state, set the new episode,
   re-run `_resolveAndOpen`. Manual only — no auto-advance/countdown.
3. **Audio picker** — surfaced through the toolbar speaker icon (and
   kept on the top-bar icon). The sheet re-checks tracks as they arrive
   async (StreamBuilder on `_player.stream.tracks`), so it fills in
   instead of returning early on an empty list. Gold check on the
   active track.
4. **Subtitle picker** — same, through the toolbar CC icon (kept on
   the top-bar icon): Off + external plugin subs + embedded tracks,
   StreamBuilder so it fills in as tracks arrive, gold check on the
   active one, plugin subs auto-selected first.
   media_kit seeds every track list with 'auto'/'no' pseudo-tracks —
   the audio/subtitle pickers and the subtitle auto-select filter those
   out, so only real tracks list (and auto-select picks the first real
   embedded track, not 'auto').
5. **Tabbed panel (Sources / Audio / Subtitles / Episodes)** — one
   Gold & Black panel with tabs at the top, replacing the three separate
   sheets. The toolbar opens it on the tab its icon stands for (tune →
   Sources, CC → Subtitles, speaker → Audio). Sources = source list +
   Quality (Auto + WxH); Audio = "Track N - Language" rows with the
   channel layout below (e.g. "5.1"), a gold check on the active track,
   and a Retry (re-resolve) at the bottom; Subtitles = Off / plugin
   files / embedded tracks + a Subtitle style row; Episodes = episode
   rows (series only).
6. **Subtitle style panel** — from the Subtitles tab, rows with - / +
   steppers: Text size, Text colour (cycles the caption colours),
   Background (Off + reset), Outline (None/Thin/Normal/Thick), Position
   (Bottom/Top preset). A note says these change the subtitle
   appearance for subtitle files and subtitles inside the video. The
   style is drawn by the Flutter overlay (mpv's sub-* properties render
   nothing while libass is off), so it applies to both.
7. **Subtitle long-press drag** — the built-in overlay is hidden
   (`visible: false`) and the subtitle is drawn by a custom overlay.
   Long-press the text to grab it (gold outline), drag it anywhere on
   the picture, release to drop. The position is a fraction of the video
   area and is persisted (Hive `mpv_sub_pos_x`/`_y`), so it stays across
   videos and sessions. The Position preset resets it to Bottom/Top.
   Works for embedded + plugin subtitles (both are `sub-text`). Only
   the text is a hit target; taps elsewhere still toggle controls /
   zoom / volume.
8. **Loading-screen Back button** — the resolving spinner now has a
   top-left Back button (the pre-play source list already had one).
   Tapping it abandons the resolve AND pops. A `_resolveAbandoned`
   flag stops the late open: resolvePlayback answers an abandon with
   the default source, so the flag (not the completer alone) is what
   keeps the video from opening behind the screen the viewer left.
9. **Brightness/volume HUD** — the old centred text box is replaced by
   a top-centre dark pill with a gold sun (brightness) or speaker
   (volume) icon, a gold fill bar for the level, and the % value. It
   fades and slides in on a vertical swipe, follows the level live, and
   fades out ~1.5 s after the swipe ends. Display-only (never eats a
   tap).
10. **Double-tap seek flash moved to the side** — the centre "+10s" /
    "-10s" pill is gone (the viewer found it annoying), and the centre
    play/pause flash is gone too. A double-tap seek now shows a SMALL
    pill at the edge where the tap happened (left for -10 s, right for
    +10 s, gold replay/forward icon + "-10s"/"+10s"), fading out in
    ~700 ms. The ±10 s seek itself is unchanged; the progress bar / time
    still shows the new position.
11. **Horizontal scrub** — drag left/right on the video to move through
    it (right = forward, left = backward). While dragging, a small pill
    above the bottom bar previews the time the drag will land on; on
    release, the video seeks there. The seek happens only on release,
    so the mpv backward cache makes a backward scrub instant. The
    gesture arena sends mostly-horizontal drags to the scrub and
    mostly-vertical ones to brightness/volume, so they never fight; a
    double-tap is a tap, not a drag. Sensitivity: a full-width drag
    moves 10% of the duration.
12. **Tap the time to toggle remaining time** — tap the time display
    ("21:30 / 44:39") to show the remaining time with a minus sign
    ("-23:09", total − position). Tap again to go back. LIVE stays
    LIVE. Session state.
13. **Tap-and-hold 2x speed** — press and hold the RIGHT half of the
    screen: after ~550 ms the video plays at 2x, with a small gold
    "2x speed" pill at the top centre; lift the finger and it returns
    to the previous speed. A quick tap or a drag never reaches the
    550 ms timer, so double-tap seek and vertical volume swipes are
    unaffected; the hold uses the tap recognizer + a timer (not a
    long-press recognizer), so it cannot steal the arena from the
    subtitle's long-press drag — and 550 ms is longer than the
    subtitle long-press timeout (500 ms), so grabbing the subtitle
    wins first. A hold that just ended does not also toggle the
    controls. Edge case: double-tap-AND-hold still seeks +10 s first
    (the double-tap fires on the second tap down) and then goes 2x —
    the same as YouTube.
14. **Speed sheet now lists 2x and 3x** — the speeds are 0.5x, 0.75x,
    1x, 1.25x, 1.5x, 1.75x, 2x, 3x; the current speed has a gold
    checkmark. Selecting one sets the rate persistently via
    `player.setRate`.
15. **Skip Intro (all series, not just anime)** — intro/outro segments
    come from the same crowdsourced source the libVLC player uses
    (`fetchSkipSegments`: IntroDB by TMDB/IMDb id + AnimeSkip by AniList
    id, both opt-in in settings; empty is normal). The segments are
    looked up in the background on open and on each episode switch
    (playback never waits on them). A gold "Skip Intro" chip (bottom-
    right, above the bottom bar, localised "Skip Intro"/"Skip Recap"/
    "Skip Outro") shows only while the position is inside a segment;
    tapping it jumps to the segment's end. Auto Skip (Settings → Player,
    default ON) jumps automatically on the position ticks, once per
    segment (guarded so a seek in flight does not re-fire); when OFF,
    only the chip shows. No chip when the episode has no timestamps.

## PiP (mpv) — the fork: `packages/media_kit_video_fork`

media_kit has no iOS PiP, so v19 forks media_kit_video 2.0.1 (path
dependency; same name/version, so nothing else changes) and adds a
software-render PiP path. See
`packages/media_kit_video_fork/ZOROX_MPV_PIP_FORK.md` for the full
notes. The short version:

- iOS forbids GPU work in the background, so PiP cannot be fed by
  media_kit's GL texture. libmpv's software render API
  (`mpv_render_context_create` with `"sw"`, verified present in the
  v18 Mpv.framework) renders into CPU buffers; mpv allows ONE render
  context per handle, so PiP start frees the GL one and creates the SW
  one, and PiP stop swaps back.
- The swap lives inside the fork: `VideoOutput.setHardwareAcceleration`
  (async — it must NOT block the main thread, or the texture unregister
  deadlocks), `TextureHW`/`TextureSW` (non-crashing context creation —
  upstream's `checkError` calls `exit(1)`; the fork logs and retries
  instead), IOSurface-backed SW buffers, `onFrameRendered` feed.
- `MpvPip.swift` (new): AVSampleBufferDisplayLayer +
  AVPictureInPictureController; layer in the Flutter view (160x90,
  index 0 — it must be in a visible window with a non-zero frame or PiP
  is black); alpha forced opaque (`| 0xFF000000`, mpv "bgr0" leaves
  alpha 0 — a strong black-PiP suspect); play/pause/seek go straight
  to mpv (`mpv_set_property` pause, `mpv_command_string` seek);
  diagnostics (`framesEnqueued`, `meanLuma` of every 30th buffer —
  ~0 while frames increase means the feed is black — `layerStatus`,
  `layerError`, `isPictureInPicturePossible`/`Active`).
- Channel `dev.akash.skystream.mpv_pip` (`isSupported` / `start` /
  `stop` / `status`, events `onPipStarted` / `onPipStopped`).
- Dart: before PiP, `setProperty('hwdec', 'videotoolbox-copy')`; on
  stop/restore, `setProperty('hwdec', 'videotoolbox')`. The PiP button
  only shows when `isSupported` is true; manual button only (no
  auto-PiP yet). If the native side cannot show real video, the button
  stays out — no black PiP is shipped.
- The libVLC engine and vlc_player package are untouched; the mpv line
  is the active player. Reverting the player is a one-line route change.

## Version / build

- Version 2.9.18 (`pubspec.yaml` + `app_router.dart` comment).
- `flutter analyze lib`: TODO (run after the fork switch).
- Player test suite (`flutter test test/features/player/`):
  - Run 1 (before the fork switch): 1756 passed, 2 skipped, 16 failed.
    v17 baseline was 1755 passed / 10 failed. The visible failures are
    VLC-screen tests (not mpv); the full list is being re-captured.
  - TODO: final run result + whether the extra failures are pre-existing.
- Build: TODO (run id, head commit, IPA size/MD5).

## Phone test checklist (for the user)

- Pre-play source list: open a movie — the source list must appear
  before play; tap a row, it plays that source; back out, it leaves.
- Loading Back button: open a movie and tap Back WHILE it is still
  loading (spinner) — it must leave the player at once and no video
  must start behind it.
- Tabbed panel: tune → Sources (switch source, Quality Auto + WxH),
  speaker → Audio ("Track N - Language", channels below, gold check,
  Retry at the bottom), CC → Subtitles (Off / files / embedded, gold
  check), series → Episodes tab switches episodes; prev/next buttons
  switch episodes.
- Subtitle style: from the Subtitles tab, open Subtitle style — the - /
  + steppers change size, colour, background, outline, position; the
  change shows on the video at once and survives reopening the player.
- Subtitle drag: long-press the subtitle on the video, drag it
  somewhere else, release — it stays there; reopen the video, it is
  still there.
- Brightness/volume HUD: swipe vertically on the left (brightness) and
  right (volume) — a dark pill slides in at the top centre with a sun /
  speaker icon, a gold fill bar and the %; it follows the swipe live
  and fades out ~1.5 s after.
- Double-tap seek: double-tap left/right — a SMALL pill appears at that
  edge ("-10s"/"+10s") and fades quickly; NOTHING big appears in the
  centre any more, and the seek still jumps ±10 s.
- Horizontal scrub: drag left/right on the video — a small pill previews
  the target time; lift the finger to seek there.
- Tap the time ("21:30 / 44:39") to show the remaining time ("-23:09");
  tap again to go back.
- Press and HOLD the right half of the screen → 2x speed while held
  (a small "2x speed" pill shows); lift the finger → back to normal.
- Speed sheet (gauge icon): 0.5x, 0.75x, 1x, 1.25x, 1.5x, 1.75x, 2x,
  3x — tap one to set it (gold check on the current speed).
- Next / Previous Episode buttons: in the bottom toolbar, left of the
  time (series only — a movie has no episodes, so they are hidden).
  They switch episodes the same way as the episode picker (per-episode
  state reset + re-resolve). At the first episode Previous is greyed,
  at the last Next is greyed; both have a 42x42 tap target.
- PiP (the big one): tap the PiP button — the PiP window must show
  REAL VIDEO (not black). Test a local H.264 MP4, a remote MKV, an HLS
  stream, paused → PiP, PiP → app restore, and PiP in the background
  for 2+ minutes. If PiP is black, report it (frames/luma will tell
  whether the feed or the window is at fault) — the other features are
  not blocked on PiP.

## Not in v19

- Nav bar redesign (v20, 2.9.19) — not built here.
- Side-car subtitle download, ClearKey DRM, auto-advance to the next
  episode (same limits as v18-mpv).
- The libVLC hand-off fallback for PiP (only if the SW PiP proves
  unworkable — report first, do not implement silently).

## Phone test — the bug-fix build (2.9.18+2)

- Double-tap seek rapidly on both sides: only ±10 s seeks, never 2x.
- Play a long video: no freeze mid-play; if the source stalls, a
  spinner shows and it re-seeks / fails over on its own.
- Landscape: no raw URL anywhere on screen (title line, source line,
  error text).
- PiP: tap the toolbar PiP button → real video (not black, not
  nothing); swipe Home during playback → PiP opens on its own; return
  to the app → PiP closes and fullscreen returns.
- Continue Watching: watch part of a video, go back — a Continue
  Watching row shows it with a progress bar; tapping resumes where
  you left off.
- Episodes sheet: each row shows a poster thumbnail on the left.
- Bottom toolbar: the pill sits inset from the right edge (not in the
  corner) and looks premium (frosted glass, gold hairline, gold glow,
  gradient gold icons); no PiP button in the top bar.
- Aspect ratio: tap the fullscreen/aspect icon → Fit / Fill / Zoom /
  16:9 / 4:3 sheet; Fill crops out the black bars; 16:9 / 4:3 stretch
  the picture.
- Subtitles: pick "Forced" (PGS) on an MKV → the subtitle text/picture
  appears on the video; pick a text track → the subtitle appears and
  can be dragged and restyled.

