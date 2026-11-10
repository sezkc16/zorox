# ZoroX Design Spec — Gold & Black (approved by user 2026-11-11)

Source of truth: the approved design preview `~/workspace/ts-spaces/zorox-new-ui-design/index.html`
(761 lines, artifact slug `zorox-new-ui-design`, "ZoroX New UI Design").
The user confirmed it with "yehi" (2026-11-11 01:00). v2 (2.9.1) only shipped the
gold accent + ZoroX name; this spec is what the final build (v3, 2.9.2) implements.

## Palette (dark only — the app is always dark, cinema feel)

| Token | Value | Use |
|---|---|---|
| Obsidian (background) | `#0A0A0B` | Scaffold / screen background |
| Surface | `#161618` | Cards |
| Card alt | `#141416` | Provider card, source rows, continue-watching cards |
| Field | `#17171A` | Search field, ghost buttons |
| Icon button | `#1B1B1E` | Round icon buttons |
| Border | `#26262A` / `#2A2A2E` / `#2C2C30` | Card borders, chips |
| Row divider | `#1E1E21` | List rows |
| Zoro Gold (accent) | `#D4AF37` (`0xFFD4AF37`) | Buttons, active tab, rating, progress, badges |
| Gold Light | `#F5D67B` | Highlights |
| Gold soft | `rgba(212,175,55,.16)` | Active-tab icon pill, provider dot, icon squares |
| Gold deep | `#A07D14` | (light-mode accent only) |
| Warm White (text) | `#F5F2EA` | Primary text |
| Muted | `#A7A49B` | Secondary text |
| Inactive tab | `#9D9A92` | Unselected nav icons/labels |
| Text on gold | `#1A1402` | Text on gold buttons/badges |
| Green (installed) | `#7DD88F` on `#1D2B1E`, border `#2C4630` | "Installed"/"Connected" badges, green dot `#3ECF6E` |

Fonts in the preview: Sora (headings/brand, 700–800) + Manrope (body). The app
bundles Outfit as its single font family — Outfit is kept (no font swap); the
spec is about colour, layout and shape, not the typeface.

## Floating pill navigation (the single most visible element)

- A rounded pill that FLOATS above the content — not a plain full-width bar
  flush to the bottom edge.
- Geometry: `left/right 14px` inset (24px in the app shell), `bottom 16px`
  (app: home-indicator inset), `border-radius 26px` (fully round pill),
  `padding 8px 6px`, max width 420, centred.
- Surface: `rgba(18,18,20,.88)` glass (blur 14) with `1px #2E2E33` border and
  `0 12px 30px rgba(0,0,0,.5)` shadow.
- 5 tabs with icon + label (10px, bold): Home / Search / Plugins / Library /
  Browse — EXACTLY as the preview shows (the user's own words, 2026-11-11:
  "neeche home search plugin library detail sab esa hi" — v3), then in
  v4 the user asked for the Detail tab to become Browse ("ye section
  hatake browse dalo jisme world ki sab movies dikhr"). The app's shell
  branches were re-mapped to match: Home `/home`, Search `/search`, Plugins
  = the Extensions screen `/extensions` (TojiX repo + providers), Library
  `/library`, Browse `/browse`. Explore is NO LONGER a tab (removed from
  the shell; nothing else referenced it). Settings is a 6th shell branch
  (`/settings`, index 5) — reachable from the gear button in the Home
  AppBar (right of the provider pill), NOT from the tab bar, so its
  sub-routes (player / accounts / nuvio / cloudstream / stremio /
  developer) keep working unchanged. When Settings is open no tab is
  highlighted (it is not one of the 5).
- The "Browse" tab shows the world's movies, Trending first: the full
  Explore/discover page (TMDB trending / popular / top-rated) when a TMDB
  API key is set — the page header then still reads "Explore", its own
  title — and the active provider's home page when no key is set, the
  Trending section as a named hero carousel (with its own scrollable
  Trending row below it) followed by the provider's other lists, so the
  tab is never an empty screen. Tapping a poster opens that title's
  detail page, exactly as a poster tap does everywhere else.
- Labels "Plugins" and "Browse" are hardcoded English strings in the
  nav/sidebar (no l10n key exists for them); Home / Search / Library
  keep using the localized strings. Tab icons: home, search, extension
  (puzzle), video_library, explore (compass).
- Active tab: icon + label in gold `#D4AF37`, icon wrapped in a gold-soft pill
  (`rgba(212,175,55,.16)`, radius 12, padding `3px 10px`).
- Inactive tab: icon + label in `#9D9A92`.
- Hidden on the player screen (player is a top-level route, no nav).

## Header

- Gold Z logo (black square, gold "Z", radius 10, 34px) + "ZoroX" wordmark
  (bold, "X" in gold). The "SkyStream" name appears nowhere.
- Right side: round search icon button (`#1B1B1E`, border `#2A2A2E`, 38px)
  + provider pill (extension icon + provider name, 36px pill).

## Home

- Greeting: small muted "Namaste, Suresh" + heading "Aaj kya dekhna hai?" (21px bold).
- Provider card (taps open the provider selector): `#141416`, border `#26262A`,
  radius 16, padding 12–14. Left: 40px gold-soft square (radius 12) with the
  provider's first letter in gold. Middle: small caps muted "Abhi wala provider"
  + provider name bold 15.5px. Right: gold "Badlo ›".
- Provider chips (horizontal): pill `#161618`, border `#2C2C30`, text `#D8D5CC`,
  12.5px bold, radius 999; selected chip = gold bg + dark text.
- Hero card: radius 20, border `#2A2A2E`, 218px image, bottom gradient fade,
  gold "★ Trending #1" badge (11px, 800, uppercase), title 23px bold, meta
  (year · type · gold-outline quality badge · gold ★ rating), gold Play button
  (radius 12, 42px) + ghost buttons (white .10 bg, white .22 border).
- Section titles: 16.5px bold + gold "Sab dekho" link.
- Continue Watching: 2-col cards `#141416`, border `#26262A`, radius 14, 74px
  image, title 13px, small muted line, 4px gold progress bar on `#2C2C30` track.
- Poster rows: 3-col, poster 2:3, radius 13, border `#26262A`, title 12.5px,
  small muted with gold ★.
- Empty state (no provider): NOT the bare "Select a provider" screen — the
  greeting + provider card + provider chips above, so the home is never empty.

## Detail

- Backdrop 300px + gradient fading to `#0A0A0B`; top bar with back + bookmark
  round icon buttons.
- Header: poster 86px (2:3, radius 12, border `#333`), title 21px 800, meta
  rows (year · duration · gold-outline quality badge · gold ★ rating), genres.
- Actions: gold Play (flex 1) + ghost buttons (`#17171A`, border `#2C2C30`).
- Synopsis `#C9C6BC` 13.5px.
- Source rows: `#141416`, border `#26262A`, radius 14; 38px gold-soft icon
  square; title 14px; small muted line; gold-outline quality badge
  (11px, 800 — 1080p / 4K / 720p). (Already in v2 as the source-picker
  `_QualityBadge`.)
- "More Like This": poster row.

## Player

- Black video area; top bar (back + title 14.5px + small muted subtitle);
  big gold play button (64px circle, gold bg, dark icon, shadow).
- Bottom controls: 5px progress bar (white .28 track, gold fill), time
  11.5px bold, chips (1080p / Sub · Hindi / 1.0× — white .14 bg, white .20
  border, white text, radius 8, 11.5px 800), 40px icon buttons
  (seek ±10s, fullscreen).
- Player Settings rows: 38px gold-soft icon, title 14px, small muted, gold
  switch (46×27, off `#2C2C30`, on gold).
- Up Next: continue-watching cards.
- Player features (v3): pinch-to-zoom on the video (two-finger pinch scales
  1.0–3.0, resets on new media) + bigger buffer (see below).

## Search

- Title "Search" 21px bold. Big field: `#17171A`, border `#2C2C30`,
  radius 13, 44px, muted icon, warm-white text.
- Recent chips; Results poster row; Trending Searches (numbered gold-soft dots).

## Library

- Title "My Library" 21px bold. Chips (My List / Downloads / History),
  active = gold.
- Rows: poster 52px (2:3, radius 9), title 14px, small muted, progress bar,
  gold-outline quality badge. Divider `#1E1E21`.
- Storage card: `#141416`, border `#26262A`, radius 15, "Downloads · 3.2 GB",
  small muted, gold progress bar.

## Extensions

- Title "Extensions" 21px bold.
- Repo card: `#141416`, border `#26262A`, radius 15; "TojiX Repo" +
  "Connected" green badge (`#1D2B1E` / `#7DD88F` / `#2C4630`); repo URL small
  muted; "14 plugins" small.
- Provider rows: gold-soft dot with first letter, name 14.5px, small muted
  with green dot, gold-outline "ON" badge or gold Install button
  (radius 9, 34px).

## Player buffer (v3)

- `kVodCachingMs`: 1000 → 10000 (10 s network cache so a ±10 s double-tap
  seek lands inside the buffer and plays instantly).
- `VlcNetworkConfig.prefetchBufferKiB`: 65536 (64 MiB instance-level
  read-ahead, `--prefetch-buffer-size`; per-media `:prefetch-buffer-size`
  from the buffer plan still overrides it). Trade-off: slightly slower
  start-up + more memory; a seek beyond the buffered window still fetches.

## What is NOT changed

- Dart package name `skystream`, Kotlin MethodChannel strings
  `dev.akash.skystream.*`, default-repo seed, gold Z icon, plugin/provider
  logic, navigation targets, data layer. This is a UI restyle + the two
  player features only.
- The preview's mock content (The Odyssey, fake posters, fake provider
  names) is NOT real data — the app shows the provider's real catalogue.

## Honest differences (v3, tab restructure)

- The preview's Detail screen is a mock of ONE item ("The Odyssey"). The
  app's Detail tab shows the most recently watched item's real detail
  page instead — there is no single "the" detail in a real app. If
  nothing was watched yet, it shows an empty state.
- The preview shows the Explore tab nowhere — the app had an Explore tab.
  Per the user's explicit instruction ("home search plugin library
  detail sab esa hi") Explore was removed from the shell. The Explore
  screen file still exists but is no longer reachable; its data
  providers are still used by other screens (addons / details).
- Settings has no tab (the preview has none either). It is a 6th shell
  branch, opened from the gear button in the Home AppBar. When Settings
  is open, no bottom-nav tab is highlighted.
- The preview's Detail tab uses a gear icon. Kept as-is (faithful to the
  approved design), even though a gear normally means Settings.
