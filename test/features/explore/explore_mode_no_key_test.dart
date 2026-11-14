import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:skystream/core/config/tmdb_config.dart';
import 'package:skystream/features/explore/data/explore_mode_provider.dart';

/// The Explore Source picker must open without a TMDB key: with no key
/// saved the default source falls back to one that works key-free
/// (Stremio Add-ons), a saved Anime/Stremio mode is kept, and a saved
/// Movies & Shows mode falls back without losing the saved preference.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TmdbConfig.setUserApiKey('');
    TmdbConfig.setNuvioApiKey('');
  });

  tearDown(() {
    TmdbConfig.setUserApiKey('');
    TmdbConfig.setNuvioApiKey('');
  });

  ProviderContainer containerWith({Map<String, Object>? prefs}) {
    SharedPreferences.setMockInitialValues(prefs ?? <String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    return container;
  }

  /// Lets the provider's async persisted-mode load finish. The load goes
  /// through a platform-channel call, so it needs a real (short) delay,
  /// not just microtasks.
  Future<void> settleLoad() async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }

  test('no key and no saved mode starts on Stremio Add-ons', () {
    final container = containerWith();
    expect(container.read(exploreModeProvider), ExploreModeType.stremio);
  });

  test('no key and a saved anime mode keeps anime', () async {
    final container = containerWith(
      prefs: {'explore_mode_type': 'anime'},
    );
    // Read once to start the provider (and its async persisted-mode
    // load); the second read, after the load, is the settled state.
    container.read(exploreModeProvider);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.anime);
  });

  test(
    'no key and a saved movies mode falls back to Stremio '
    'without overwriting the save',
    () async {
      final container = containerWith(
        prefs: {'explore_mode_type': 'movies'},
      );
      container.read(exploreModeProvider);
      await settleLoad();
      expect(container.read(exploreModeProvider), ExploreModeType.stremio);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('explore_mode_type'), 'movies');
    },
  );

  test('with a key, a saved movies mode stays movies', () async {
    TmdbConfig.setUserApiKey('0123456789abcdef0123456789abcdef');
    final container = containerWith(
      prefs: {'explore_mode_type': 'movies'},
    );
    container.read(exploreModeProvider);
    await settleLoad();
    expect(container.read(exploreModeProvider), ExploreModeType.movies);
  });
}
