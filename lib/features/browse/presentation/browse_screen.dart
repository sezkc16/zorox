import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skystream/core/network/dio_client_provider.dart';
import 'package:skystream/l10n/generated/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/tmdb_config.dart';
import '../../../core/domain/entity/multimedia_item.dart';
import '../../../core/router/app_router.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../features/explore/presentation/explore_screen.dart';
import '../../../features/explore/presentation/view_all_screen.dart';
import '../../../features/explore/presentation/widgets/explore_carousel.dart';
import '../../../features/explore/presentation/widgets/media_horizontal_list.dart';
import '../../../features/home/presentation/home_state.dart';
import '../../../features/settings/presentation/general_settings_provider.dart';
import '../../../shared/widgets/custom_widgets.dart';
import '../../../shared/widgets/loading_indicator.dart';
import 'browse_provider.dart';

/// Browse: the world's movies, as the fifth tab (replaces the Detail tab
/// in ZoroX v4).
///
/// With a TMDB API key configured, this is the full Explore/discover page —
/// TMDB trending, popular and top-rated, with its filters and genres.
/// (Set the key here on this screen OR in Settings; either way the tab
/// flips to TMDB immediately, no restart.) Without a key, Explore would only
/// show its "TMDB API key needed" card, so Browse instead shows a world mix:
/// the home sections of ALL installed providers merged and deduplicated
/// (`browseAllProvidersProvider`) — NOT the current provider's feed, which is
/// what Home already shows (v4 bug fix: Browse duplicated Home). The tab is
/// never an empty screen: with any provider installed it always shows real
/// movies from across them, and never shows Home's "From `provider`" card.
///
/// Trending leads in both. On TMDB the hero is the day's trending, then
/// Popular, Trending TV and Top Rated. On the provider mix the Trending
/// section is the hero carousel — named, with its own row below it —
/// followed by the other lists, so every trending title is scrollable and
/// not just the seven the carousel shows.
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
  final _tmdbKeyController = TextEditingController();
  var _tmdbChecking = false;
  String? _tmdbError;

  @override
  void dispose() {
    _scrollController.dispose();
    _carouselAnchor.dispose();
    _tmdbKeyController.dispose();
    super.dispose();
  }

  void _openDetails(MultimediaItem item) {
    DetailsRoute($extra: DetailsRouteExtra(item: item)).push<void>(context);
  }

  /// The key as TMDB expects it: whatever a copy smuggled in is removed —
  /// whitespace anywhere in it, and the zero-width characters chat apps and
  /// web pages insert, which `trim()` does not count as whitespace. Either
  /// one turns a good key into a 401. (Same rule as the Settings dialog.)
  static String _normalizedKey(String raw) =>
      raw.replaceAll(RegExp(r'[\s​-‍⁠﻿]'), '');

  /// TMDB's API page shows two credentials side by side. The v4 "API Read
  /// Access Token" is a JWT — three dot-separated parts, the first starting
  /// `eyJ` — and TMDB answers it with the same 401 as a mistyped key.
  static bool _isReadAccessToken(String key) =>
      key.startsWith('eyJ') && '.'.allMatches(key).length == 2;

  /// Validates the pasted key against TMDB and, when it is good, saves it in
  /// the same place Settings does (`generalSettingsProvider.setTmdbApiKey`,
  /// which persists it and mirrors it into `TmdbConfig`). Saving rebuilds
  /// this screen — `build()` sees the key and returns the full TMDB
  /// Explore page immediately, no restart and no trip to Settings.
  Future<void> _saveTmdbKey() async {
    final key = _normalizedKey(_tmdbKeyController.text);

    if (key.isEmpty) {
      setState(() => _tmdbError = 'Paste your TMDB API key first.');
      return;
    }
    if (_isReadAccessToken(key)) {
      setState(() {
        _tmdbError =
            'That is the "API Read Access Token". Paste the shorter '
            '"API Key" from the same TMDB page instead.';
      });
      return;
    }

    setState(() {
      _tmdbChecking = true;
      _tmdbError = null;
    });

    // Each failure says what it was. One message for all of them told a user
    // whose network cannot reach TMDB that their key was wrong.
    String? problem;
    try {
      final dio = ref.read(dioClientProvider);
      final res = await dio.get<Object?>(
        '${TmdbConfig.baseUrl}/authentication',
        queryParameters: {'api_key': key},
        options: Options(
          validateStatus: (s) => s != null && s < 500,
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      final body = res.data;
      if (res.statusCode == 200 && body is Map && body['success'] == true) {
        problem = null;
      } else if (res.statusCode == 401) {
        problem =
            'TMDB rejected this key. Check that it is the "API Key" '
            '(v3 auth), 32 letters and digits.';
      } else if (res.statusCode == 200) {
        // Something answered for api.themoviedb.org that is not TMDB —
        // the block page a filtering network serves.
        problem = _tmdbUnreachable;
      } else {
        problem =
            'TMDB could not check the key right now (HTTP '
            '${res.statusCode}). Try again in a moment.';
      }
    } catch (_) {
      // Nothing was learned about the key: no connection, a timeout, or
      // a network that will not resolve TMDB.
      problem = _tmdbUnreachable;
    }

    if (!mounted) return;

    if (problem != null) {
      setState(() {
        _tmdbChecking = false;
        _tmdbError = problem;
      });
      return;
    }

    await ref.read(generalSettingsProvider.notifier).setTmdbApiKey(key);
    if (!mounted) return;
    setState(() => _tmdbChecking = false);
    // No navigation needed: build() watches tmdbApiKey, so the moment the
    // provider state updates this tab flips to the TMDB Explore page.
  }

  static const String _tmdbUnreachable =
      "Couldn't reach TMDB to check the key. If your network blocks TMDB, "
      'turn on DNS over HTTPS in Accounts, Network & Downloads, then try '
      'again.';

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
    // The world mix: every installed provider's home sections merged and
    // deduplicated — deliberately NOT Home's single-provider feed, so the
    // two tabs never show the same content.
    final home = ref.watch(browseAllProvidersProvider);

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
          title: 'No providers installed',
          message:
              'Install a plugin from the Plugins tab — Browse shows '
              'Trending and Latest from all of them here.',
          actions: [
            FilledButton(
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
              onPressed: () =>
                  ref.read(browseAllProvidersProvider.notifier).fetch(),
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
              onPressed: () =>
                  ref.read(browseAllProvidersProvider.notifier).fetch(),
              child: const Text('Try again'),
            ),
          ],
        ),
        HomeSuccess(:final data) => _buildSections(context, data),
      },
    );
  }

  Widget _buildSections(
    BuildContext context,
    Map<String, List<MultimediaItem>> data,
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
        : (data.isNotEmpty ? data.entries.first.key : '');
    if (rows.isEmpty && hero.isEmpty) {
      return _buildEmptyState(
        context,
        title: 'No movies found',
        message:
            'The installed providers returned nothing right now. Try '
            'again, or add a TMDB key below for the full Browse.',
        actions: [
          FilledButton(
            onPressed: () =>
                ref.read(browseAllProvidersProvider.notifier).fetch(),
            child: const Text('Try again'),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: () async =>
          ref.read(browseAllProvidersProvider.notifier).fetch(),
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          // No "From <provider>" card here — that is Home's. Browse is the
          // world mix. Instead, the TMDB key card: paste a free key here
          // and this tab becomes the full TMDB Browse immediately.
          SliverToBoxAdapter(child: _tmdbKeyCard(context)),
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

  /// The TMDB key input, right here on Browse — not buried in Settings.
  /// Paste the free key, tap Save, and this tab flips to the full TMDB
  /// Browse (Trending, Popular, Top Rated) at once. The key is stored in
  /// the same place Settings uses, so it stays saved.
  Widget _tmdbKeyCard(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingSm,
      ),
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.5)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(LayoutConstants.spacingMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.vpn_key_rounded,
                    color: scheme.primary,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Unlock the full Browse',
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Paste your free TMDB API key to see Trending, Popular, '
                'Top Rated and more — the world’s movies, not just your '
                'providers.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              CustomTextField(
                controller: _tmdbKeyController,
                decoration: InputDecoration(
                  labelText: 'TMDB API key (v3 auth)',
                  hintText: 'e.g. 0123456789abcdef0123456789abcdef',
                  errorText: _tmdbError,
                  errorMaxLines: 4,
                  prefixIcon: const Icon(Icons.vpn_key_rounded, size: 20),
                ),
                keyboardType: TextInputType.text,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _tmdbChecking ? null : _saveTmdbKey,
                    icon: _tmdbChecking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded, size: 18),
                    label: Text(_tmdbChecking ? 'Checking…' : 'Save key'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse('https://www.themoviedb.org/settings/api'),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new_rounded, size: 16),
                    label: const Text('Get a free key'),
                  ),
                ],
              ),
            ],
          ),
        ),
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
