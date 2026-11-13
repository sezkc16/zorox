/// Labels for audio/subtitle tracks in the golden drawers.
///
/// The engine names a track generically ("Audio 1", "1VegaMovies.tw") and
/// reports its language as an ISO code ("hin", "kor") — the original
/// SkyStream shows "MoviesDrives.bid - [English] 5.1", so a row here must
/// never read "Audio 1" with no clue which language it is. The language is
/// promoted into the main label, and the channel count is the small detail
/// under it.
library;

import '../../domain/track_language.dart';

/// A readable language name for an ISO code ("hin" -> "Hindi"), or null
/// when the source gave no language.
String? goldenLanguageName(String? language) {
  final value = language?.trim();
  if (value == null || value.isEmpty || value.toLowerCase() == 'und') {
    return null;
  }
  final mapped = languageNameForCode(value);
  if (mapped != null) return mapped;
  // Already a name rather than a code, most likely: `Brazilian Portuguese`.
  if (value.length > 3) return value;
  return value.toUpperCase();
}

/// Whether [name] is the engine counting rather than naming ("Audio 1",
/// "Track 3", "Subtitle 2").
bool _isGenericTrackName(String name) =>
    RegExp(
      r'^(audio |subtitle |spu )?track\s*#?\d*$',
      caseSensitive: false,
    ).hasMatch(name) ||
    RegExp(r'^(audio|subtitle)\s+\d+$', caseSensitive: false).hasMatch(name);

/// The row label for a track: the language alone when the name is generic
/// ("Audio 1" + "hin" -> "Hindi"), else the name plus the language in
/// brackets ("1VegaMovies.tw" + "hin" -> "1VegaMovies.tw - [Hindi]").
String goldenTrackLabel(String name, String? language) {
  final lang = goldenLanguageName(language);
  final trimmed = name.trim();
  if (lang != null) {
    if (trimmed.isEmpty || _isGenericTrackName(trimmed)) return lang;
    return '$trimmed - [$lang]';
  }
  return trimmed.isEmpty ? 'Unknown' : trimmed;
}

/// The channel count as the original shows it ("5.1", "Stereo", "Mono").
String? goldenChannelName(int? channels) => switch (channels) {
  null || <= 0 => null,
  1 => 'Mono',
  2 => 'Stereo',
  6 => '5.1',
  8 => '7.1',
  final int other => '$other ch',
};
