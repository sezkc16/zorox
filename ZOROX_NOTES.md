# ZoroX — personal fork of SkyStream

ZoroX is a personal build of [SkyStream](https://github.com/akashdh11/skystream)
(v2.9.0), rebranded for personal use. Same app, same CloudStream (.cs3)
support — different name, icon, bundle ID, and your own repository
pre-installed.

## What's customized (v1)

| Thing | Where | Value |
|---|---|---|
| App name | `ios/Runner/Info.plist` (`CFBundleDisplayName`, `CFBundleName`), `android/app/src/main/AndroidManifest.xml` (`android:label`), `lib/main.dart` (`title`, `label`) | ZoroX |
| iOS bundle ID | `ios/Runner.xcodeproj/project.pbxproj` (`PRODUCT_BUNDLE_IDENTIFIER`) | `com.toji.zorox` |
| Android app ID | `android/app/build.gradle.kts` (`namespace`, `applicationId`), Kotlin package `android/app/src/main/kotlin/com/toji/zorox/` | `com.toji.zorox` |
| App icon | `ios/Runner/Assets.xcassets/AppIcon.appiconset/` (21 PNGs), `android/app/src/main/res/mipmap-*/ic_launcher*.png`, `assets/images/ic_launcher_foreground.png` | Gold "Z" on black (master: `zorox_icon_1024.png`) |
| Default repo | `lib/core/cloudstream/cloudstream_repository.dart` (`_defaultRepositoryUrl` + `_seedDefaultRepository()`) | `https://raw.githubusercontent.com/sezkc16/katdrama/builds/plugins.json` |

The original developer's Apple Team ID was removed from the Xcode project;
the build is unsigned (see below).

## How to customize further

- **App name** — change the three places in the table above.
- **Icon** — replace the 1024×1024 master, then re-export the iOS sizes
  (see `ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json`) and
  the Android densities (mdpi 108, hdpi 162, xhdpi 216, xxhdpi 324,
  xxxhdpi 432 for foreground/monochrome; 48/72/96/144/192 for the legacy
  `ic_launcher.png`).
- **Theme / accent color** — `lib/core/theme/app_theme.dart`: `primary`
  (`0xFF448AFF`, blue) and the `seedColor` in `createDarkTheme` (same blue).
  For the black-and-gold look, use gold `0xFFD4AF37` in both places.
- **Default repository** — edit `_defaultRepositoryUrl` in
  `lib/core/cloudstream/cloudstream_repository.dart`. To stop pre-adding
  any repo, delete the `unawaited(_seedDefaultRepository());` line in
  `load()`. Removing a repo inside the app still works as normal, and a
  removed repo is never re-added (it is remembered in SharedPreferences).
- **TMDB / Trakt / SIMKL / MAL / AniList / AnimeSkip / OpenSubtitles keys**
  — the v1 build ships without them, so those integrations run degraded.
  Add them as repository secrets with the same names upstream uses, then
  generate a `dart-defines.json` in `.github/workflows/ios.yml` before the
  build step (see upstream `release.yml` for the exact file).

## Build & install (iOS)

1. Push to `master` (or Run workflow manually) — the `Build ZoroX iOS
   (Unsigned IPA)` workflow builds on `macos-latest` with Flutter 3.47.7.
2. Download the `ZoroX-iOS-unsigned` artifact from the run
   (`ZoroX-<version>-unsigned.ipa`).
3. Sign it with **ESign** and install — same flow as the MLBB IPA.
   Free Apple ID: 7-day cert, refresh weekly; the app counts toward the
   3-app sideload limit.
