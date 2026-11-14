import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../features/explore/presentation/explore_screen.dart';
import '../../../features/settings/presentation/general_settings_provider.dart';

/// Browse: the world's movies, as the fifth tab (replaces the Detail tab
/// in ZoroX v4).
///
/// This tab is the full Explore/discover page. With a TMDB API key
/// configured it shows TMDB trending, popular and top-rated, with its
/// filters and genres — and it is reachable WITHOUT a key too: the
/// Explore Source picker opens with no key saved, Anime (AniList) and
/// Stremio Add-ons work directly, and only the Movies & Shows source
/// asks for the key (its own prompt on the Explore page). No key is
/// baked into the app; the key is the user's own, from Settings.
/// (Set the key in Settings OR from the Movies & Shows prompt; either
/// way the tab flips to TMDB immediately, no restart.)
///
/// While the key is set, the page header reads "Explore": that is the
/// discover page's own title, and the tab itself reads "Browse".
class BrowseScreen extends ConsumerWidget {
  const BrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched so a key added in Settings flips the Movies & Shows rows
    // to the TMDB page without relaunching: the setter mirrors it into
    // TmdbConfig first.
    ref.watch(generalSettingsProvider.select((s) => s.tmdbApiKey));
    return const ExploreScreen();
  }
}
