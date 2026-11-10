import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/extensions/extension_manager.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../features/explore/presentation/explore_screen.dart';
import '../../../features/explore/presentation/view_all_screen.dart';
import '../../../features/explore/presentation/widgets/explore_carousel.dart';
import '../../../features/explore/presentation/widgets/media_horizontal_list.dart';
import '../../../features/home/presentation/home_provider.dart';
import '../../../features/home/presentation/home_state.dart';
import '../../../features/settings/presentation/general_settings_provider.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// Browse: the world's movies, as the fifth tab (replaces the Detail tab
/// in ZoroX v4).
///
/// With a TMDB API key configured (Settings, or the Nuvio plugins screen),
/// this is the full Explore/discover page — TMDB trending, popular and
/// top-rated, with its filters and genres. Without a key, Explore would
/// only show its "TMDB API key needed" card, so Browse instead shows the
/// active provider's own home page — the installed plugins' trending and
/// latest lists, the same sections Home shows. The tab is never an empty
/// screen: with a provider installed it always shows real movies.
///
/// Trending leads in both. On TMDB the hero is the day's trending, then
/// Popular, Trending TV and Top Rated. On the provider fallback the
/// Trending section is the hero carousel — named, with its own row below
/// it — followed by the provider's other lists, so every trending title
/// is scrollable and not just the seven the carousel shows.
///
/// While the key is set, the page header reads "Explore": that is the
/// discover page's own title, and the tab itself reads "Browse".
class BrowseScreen extends ConsumerStatefulWidget {
  const BrowseScreen({super.key});

  @override
  ConsumerState<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends ConsumerState<BrowseScreen> {
  final _scrollController = ScrollController();
  final _carouselAnchor = FocusNode(debugLabel: 'browse_carousel_anchor');

  @override
  void dispose() {
    _scrollController.dispose();
    _carouselAnchor.dispose();
    super.dispose();
  }

  void _openDetails(MultimediaItem item) {
    DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(context);
  }

  @override
  Widget build(BuildContext context) {
    // Watched so a key added in Settings flips this tab to the TMDB page
    // without relaunching: the setter mirrors it into TmdbConfig first.
    ref.watch(generalSettingsProvider.select((s) => s.tmdbApiKey));
    // A key means the full TMDB discover page; without one the provider
    // fallback below keeps the tab full of real movies.
    if (TmdbConfig.apiKey.isNotEmpty) return const ExploreScreen();
    return _buildProviderBrowse(context);
  }

  Widget _buildProviderBrowse(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final home = ref.watch(homeDataProvider);
    final provider = ref.watch(activeProviderProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Browse',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        centerTitle: false,
      ),
      body: switch (home) {
        HomeLoading() => const Center(child: AppLoadingIndicator()),
        HomeNoProvider() => _buildEmptyState(
          context,
          title: 'No provider selected',
          message:
              'Pick a provider on Home, or install one from Plugins — '
              'Browse shows its movies here.',
          actions: [
            FilledButton(
              onPressed: () => const HomeRoute().go(context),
              child: const Text('Choose a provider'),
            ),
            OutlinedButton(
              onPressed: () => const ExtensionsRoute().go(context),
              child: const Text('Plugins'),
            ),
          ],
        ),
        HomeOffline() => _buildEmptyState(
          context,
          title: l10n.noInternetError,
          message: 'Check your connection and try again.',
          actions: [
            FilledButton(
              onPressed: () => ref.read(homeDataProvider.notifier).fetch(),
              child: const Text('Try again'),
            ),
          ],
        ),
        HomeError(:final message) => _buildEmptyState(
          context,
          title: 'Could not load movies',
          message: message,
          actions: [
            FilledButton(
              onPressed: () => ref.read(homeDataProvider.notifier).fetch(),
              child: const Text('Try again'),
            ),
          ],
        ),
        HomeSuccess(:final data) =>
          _buildSections(context, data, provider?.name),
      },
    );
  }

  Widget _buildSections(
    BuildContext context,
    Map<String, List<MultimediaItem>> data,
    String? providerName,
  ) {
    // Every section as a row — Trending included, so all of its movies
    // are scrollable, not just the seven the carousel shows.
    final rows = [
      for (final entry in data.entries)
        if (entry.value.isNotEmpty) entry,
    ];
    final hero = data.containsKey('Trending')
        ? data['Trending']!
        : (data.isNotEmpty
              ? data.values.first
              : const <MultimediaItem>[]);
    // The carousel's section, named so the user sees Trending leads:
    // 'Trending' when the provider has one, else its first section.
    final heroTitle = data.containsKey('Trending')
        ? 'Trending'
        : (data.isNotEmpty ? data.entries.first.key : '');    if (rows.isEmpty && hero.isEmpty) {
      return _buildEmptyState(
        context,
        title: 'No movies found',
        message:
            'This provider returned nothing right now. Try again, or pick '
            'another provider on Home.',
        actions: [
          FilledButton(
            onPressed: () => ref.read(homeDataProvider.notifier).fetch(),
            child: const Text('Try again'),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () async => ref.read(homeDataProvider.notifier).fetch(),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          if (providerName != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LayoutConstants.spacingMd,
                  LayoutConstants.spacingXs,
                  LayoutConstants.spacingMd,
                  LayoutConstants.spacingSm,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'From $providerName',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () => const HomeRoute().go(context),
                      child: const Text('Change'),
                    ),
                  ],
                ),
              ),
            ),
          if (hero.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  LayoutConstants.spacingMd,
                  LayoutConstants.spacingSm,
                  LayoutConstants.spacingMd,
                  LayoutConstants.spacingXs,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.trending_up_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      heroTitle,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: ExploreCarousel(
                movies: hero.take(7).toList(),
                scrollController: _scrollController,
                onNavigateUp: () => _carouselAnchor.requestFocus(),
                onTap: _openDetails,
              ),
            ),
          ],
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index >= rows.length) return null;
                final entry = rows[index];
                return MediaHorizontalList(
                  title: entry.key,
                  mediaList: entry.value,
                  category: ViewAllCategory.providerContent,
                  showViewAll: true,
                  onTap: _openDetails,
                  heroTagPrefix: 'browse',
                );
              },
              childCount: rows.length,
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.only(
              bottom: LayoutConstants.shellBottomContentPadding(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(
    BuildContext context, {
    required String title,
    required String message,
    required List<Widget> actions,
  }) {
    return ListView(
      padding: const EdgeInsets.all(LayoutConstants.spacingLg),
      children: [
        const SizedBox(height: LayoutConstants.spacingLg),
        Icon(
          Icons.movie_outlined,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: LayoutConstants.spacingMd),
        Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: LayoutConstants.spacingSm),
        Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: LayoutConstants.spacingLg),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: LayoutConstants.spacingSm,
          children: actions,
        ),
      ],
    );
  }
}
