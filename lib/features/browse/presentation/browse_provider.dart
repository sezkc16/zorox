import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/extensions/extension_manager.dart';
import '../../../features/home/presentation/home_state.dart';

part 'browse_provider.g.dart';

/// Browse's world-movies feed: home sections merged across ALL installed
/// providers, deduplicated, so Browse is genuinely different from Home.
///
/// Home shows only the active provider's feed (`homeDataProvider`). Browse
/// used to fall back to the same single-provider feed when no TMDB key was
/// set, so the two tabs showed identical content (v4 bug, user-reported
/// 2026-11-11: Browse showed "From HDHub4u" + "Change" + the same Latest
/// hero as Home). This provider fixes it: it fetches every installed
/// provider's home in parallel and merges same-named sections into one
/// world mix, with "Trending" hoisted first. No provider card is shown on
/// Browse in this mode — that card is Home's.
///
/// One provider failing must not take the rest down, so each fetch is
/// wrapped in its own try/catch and a failure contributes nothing.
@Riverpod(keepAlive: true)
class BrowseAllProviders extends _$BrowseAllProviders {
  int _fetchToken = 0;

  @override
  HomeState build() {
    _fetchToken++;
    final providers = ref.watch(extensionManagerProvider);
    if (providers.isEmpty) {
      return const HomeNoProvider();
    }
    Future.microtask(() => fetch());
    return const HomeLoading();
  }

  Future<void> fetch() async {
    final token = ++_fetchToken;
    state = const HomeLoading();

    final providers = ref.read(extensionManagerProvider);
    if (providers.isEmpty) {
      state = const HomeNoProvider();
      return;
    }

    final results = await Future.wait(
      providers.map((provider) async {
        try {
          return await provider.getHome();
        } catch (_) {
          return const <String, List<MultimediaItem>>{};
        }
      }),
    );
    if (token != _fetchToken || !ref.mounted) return;

    final merged = _merge(results);
    if (merged.values.every((rows) => rows.isEmpty)) {
      state = const HomeError('No provider returned any movies right now.');
      return;
    }
    state = HomeSuccess(merged);
  }

  /// Merges same-named sections across providers into one world mix.
  ///
  /// Deduplicated by identity: TMDB id when the item has one, else IMDb id,
  /// else the normalized title, else the URL. The same movie from two
  /// providers therefore appears once, under the first provider that
  /// returned it. Section order follows first appearance, except
  /// "Trending" which is hoisted first so it leads the tab.
  Map<String, List<MultimediaItem>> _merge(
    List<Map<String, List<MultimediaItem>>> homes,
  ) {
    final seen = <String>{};
    final merged = <String, List<MultimediaItem>>{};
    for (final home in homes) {
      for (final entry in home.entries) {
        final items = entry.value.where((item) {
          return seen.add(_identityKey(item));
        }).toList();
        if (items.isEmpty) continue;
        merged.putIfAbsent(entry.key, () => []).addAll(items);
      }
    }
    if (merged.containsKey('Trending')) {
      final trending = merged.remove('Trending')!;
      return {'Trending': trending, ...merged};
    }
    return merged;
  }

  String _identityKey(MultimediaItem item) {
    if (item.tmdbId != null && item.tmdbId! > 0) {
      return 'tmdb:${item.tmdbId}';
    }
    final imdb = item.imdbId?.trim();
    if (imdb != null && imdb.isNotEmpty) return 'imdb:$imdb';
    final title = item.title.trim().toLowerCase();
    if (title.isNotEmpty) return 'title:$title';
    return 'url:${item.url}';
  }
}
