import 'package:collection/collection.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/tmdb_config.dart';

part 'explore_mode_provider.g.dart';

const String _kExploreModeKey = 'explore_mode_type';

enum ExploreModeType { movies, anime, stremio }

// App-wide user state that persists to SharedPreferences. Disposing it would
// snap the mode back to `movies` and re-read prefs asynchronously; the
// keepAlive `genres` provider watching it is the only reason that never
// happened.
@Riverpod(keepAlive: true)
class ExploreMode extends _$ExploreMode {
  @override
  ExploreModeType build() {
    _loadPersistedMode();
    // Without a TMDB key the Movies & Shows mode can only show its
    // key prompt, so start on a source that works key-free. The
    // persisted mode still wins once it loads (below).
    return TmdbConfig.apiKey.isEmpty
        ? ExploreModeType.stremio
        : ExploreModeType.movies;
  }

  Future<void> _loadPersistedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedMode = prefs.getString(_kExploreModeKey);
      if (savedMode != null) {
        final matched = ExploreModeType.values.firstWhereOrNull(
          (e) => e.name == savedMode,
        );
        if (matched != null && state != matched) {
          state = _usableMode(matched);
        }
      } else {
        // Backward compatibility for old boolean key
        final oldBool = prefs.getBool('explore_mode_is_anime');
        if (oldBool == true && state != ExploreModeType.anime) {
          state = ExploreModeType.anime;
        }
      }
    } catch (_) {}
  }

  /// A saved Movies & Shows mode is only usable with a TMDB key; without
  /// one it falls back to Stremio Add-ons, which needs no key. The
  /// fallback is in-memory only — the saved preference is left alone so
  /// Movies & Shows comes back as soon as a key is saved.
  static ExploreModeType _usableMode(ExploreModeType mode) =>
      mode == ExploreModeType.movies && TmdbConfig.apiKey.isEmpty
          ? ExploreModeType.stremio
          : mode;

  void setMode(ExploreModeType mode) {
    state = mode;
    _persistMode(mode);
  }

  void setAnimeMode(bool isAnime) {
    setMode(isAnime ? ExploreModeType.anime : ExploreModeType.movies);
  }

  Future<void> _persistMode(ExploreModeType mode) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kExploreModeKey, mode.name);
    } catch (_) {}
  }
}
