/// The subtitle fonts bundled with the app, and where libVLC finds them.
///
/// The Netflix subtitle font is Roboto (Apache License 2.0, see
/// `assets/fonts/Roboto-LICENSE.txt`), a clean grotesque in the same family as
/// the face Netflix subtitles use. Flutter draws it from the bundled family
/// (`subtitleFontFamily` returns the family name), but libVLC's freetype
/// reads font *files*, not app families, so the `.ttf` is copied to a
/// readable path in the documents directory at startup and the engine is
/// handed that path instead (see `subtitleEngineStyleFrom`).
///
/// If the copy ever fails - first launch on a read-only filesystem, an asset
/// the bundle does not carry - the engine falls back to the family name, and
/// freetype to its own default face. A font that cannot be copied must never
/// stop startup, so every failure is swallowed here.
library;

import 'dart:io';
import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

/// The bundled Netflix subtitle face, as it is declared in pubspec.yaml.
const String kNetflixSubtitleFontAsset = 'assets/fonts/Roboto-Regular.ttf';

/// The family name Flutter draws the Netflix face under (pubspec `fonts:`).
const String kNetflixSubtitleFontFamily = 'Roboto';

/// The file name the face is copied to under the documents directory.
const String kNetflixSubtitleFontFileName = 'Roboto-Regular.ttf';

/// The path libVLC is handed for the Netflix face, once it has been copied.
/// Null until [prepareBundledSubtitleFonts] has run, and null again if the
/// copy failed.
String? _netflixSubtitleFontPath;

/// The path libVLC reads the Netflix face from, or null when it is not
/// available (yet or at all).
String? get netflixSubtitleFontPath => _netflixSubtitleFontPath;

/// Copy the bundled subtitle fonts to readable files, once per install.
///
/// Writes only when the file is missing or its size moved, so a warm start
/// costs one stat. Awaited in `main()` before the first player can be
/// created, so the engine always finds the path; failures are swallowed and
/// leave [_netflixSubtitleFontPath] null.
Future<void> prepareBundledSubtitleFonts() async {
  try {
    final Directory dir = await getApplicationDocumentsDirectory();
    final Directory fontsDir = Directory('${dir.path}/fonts');
    if (!await fontsDir.exists()) {
      await fontsDir.create(recursive: true);
    }
    final File file = File('${fontsDir.path}/$kNetflixSubtitleFontFileName');
    final ByteData data = await rootBundle.load(kNetflixSubtitleFontAsset);
    final List<int> bytes = data.buffer.asUint8List();
    if (!await file.exists() || await file.length() != bytes.length) {
      await file.writeAsBytes(bytes, flush: true);
    }
    _netflixSubtitleFontPath = file.path;
  } catch (_) {
    _netflixSubtitleFontPath = null;
  }
}
