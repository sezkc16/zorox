import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:go_router/go_router.dart';
import 'package:skystream/features/home/presentation/home_screen.dart';
import 'package:skystream/features/search/presentation/search_screen.dart';
import 'package:skystream/features/library/presentation/library_screen.dart';
import 'package:skystream/features/addons/presentation/addons_screen.dart';
import 'package:skystream/features/addons/presentation/addon_detail_screen.dart';
import 'package:skystream/features/addons/presentation/addon_catalog_screen.dart';
import 'package:skystream/features/settings/presentation/settings_screen.dart';
// v19 (2.9.18) mpv build: the player route points at the mpv engine
// (MpvPlayerScreen) so the user can compare it with v17 (libVLC). The VLC
// screen stays in the repo untouched; to go back, point PlayerRoute at
// VlcPlayerScreen again (import
// features/player/presentation/vlc/vlc_player_screen.dart).
import 'package:skystream/features/player/presentation/mpv/mpv_player_screen.dart';
import '../../features/extensions/screens/extensions_screen.dart';
import '../../features/nuvio/presentation/nuvio_plugins_screen.dart';
import '../../features/cloudstream/presentation/cloudstream_screen.dart';
import '../../features/settings/presentation/player_settings_screen.dart';
import '../../features/settings/presentation/account_settings_screen.dart';
import '../../features/settings/presentation/developer_options_screen.dart';
import '../../features/details/presentation/details_screen.dart';
import '../../features/browse/presentation/browse_screen.dart';
import '../../features/details/presentation/tmdb_movie_details_screen.dart';
import '../../features/explore/presentation/view_all_screen.dart';
import '../domain/entity/multimedia_item.dart';
import 'package:skystream/shared/widgets/app_scaffold.dart';
import '../../core/storage/settings_repository.dart';
import 'route_transitions.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:flutter/foundation.dart';
import '../logger/app_logger.dart';

part 'app_router.g.dart';

// --- Route Data Classes ---

@TypedStatefulShellRoute<AppShellRouteData>(
  branches: [
    TypedStatefulShellBranch<HomeBranchData>(
      routes: [TypedGoRoute<HomeRoute>(path: '/home')],
    ),
    TypedStatefulShellBranch<SearchBranchData>(
      routes: [TypedGoRoute<SearchRoute>(path: '/search')],
    ),
    // ZoroX (approved design preview): the bottom nav is EXACTLY
    // Home / Search / Plugins / Library / Browse, as the user asked
    // ("neeche home search plugin library detail sab esa hi" in v3, then
    // "ye section hatake browse dalo" for v4 — Detail out, Browse in).
    // Plugins = the Extensions screen (TojiX repo + providers).
    // Browse = the world's movies: the Explore/discover page when a TMDB
    // key is set, the active provider's home page otherwise — so the tab
    // is never an empty screen. Explore is no longer a tab. Settings stays
    // as a 6th branch — reachable from the Home AppBar gear, not from the
    // tab bar — so its sub-routes (player / accounts / nuvio / cloudstream /
    // stremio / developer) keep working unchanged.
    TypedStatefulShellBranch<PluginsBranchData>(
      routes: [TypedGoRoute<ExtensionsRoute>(path: '/extensions')],
    ),
    TypedStatefulShellBranch<LibraryBranchData>(
      routes: [TypedGoRoute<LibraryRoute>(path: '/library')],
    ),
    TypedStatefulShellBranch<BrowseBranchData>(
      routes: [TypedGoRoute<BrowseRoute>(path: '/browse')],
    ),
    TypedStatefulShellBranch<SettingsBranchData>(
      routes: [
        TypedGoRoute<SettingsRoute>(
          path: '/settings',
          routes: [
            TypedGoRoute<PlayerSettingsRoute>(path: 'player'),
            TypedGoRoute<AccountSettingsRoute>(path: 'accounts'),
            TypedGoRoute<NuvioPluginsRoute>(path: 'nuvio'),
            TypedGoRoute<CloudStreamRoute>(path: 'cloudstream'),
            TypedGoRoute<AddonsRoute>(path: 'stremio'),
            TypedGoRoute<DeveloperOptionsRoute>(path: 'developer'),
          ],
        ),
      ],
    ),
  ],
)
class AppShellRouteData extends StatefulShellRouteData {
  const AppShellRouteData();

  @override
  Widget builder(
    BuildContext context,
    GoRouterState state,
    StatefulNavigationShell navigationShell,
  ) {
    return AppScaffold(navigationShell: navigationShell);
  }
}

class HomeBranchData extends StatefulShellBranchData {
  const HomeBranchData();
}

class HomeRoute extends GoRouteData with $HomeRoute {
  const HomeRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) => const HomeScreen();
}

class SearchBranchData extends StatefulShellBranchData {
  const SearchBranchData();
}

class SearchRoute extends GoRouteData with $SearchRoute {
  const SearchRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const SearchScreen();
}

class PluginsBranchData extends StatefulShellBranchData {
  const PluginsBranchData();
}

class BrowseBranchData extends StatefulShellBranchData {
  const BrowseBranchData();
}

class BrowseRoute extends GoRouteData with $BrowseRoute {
  const BrowseRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const BrowseScreen();
}

class LibraryBranchData extends StatefulShellBranchData {
  const LibraryBranchData();
}

class LibraryRoute extends GoRouteData with $LibraryRoute {
  final int? tab;
  const LibraryRoute({this.tab});

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      LibraryScreen(initialTab: tab ?? 0);
}

class SettingsBranchData extends StatefulShellBranchData {
  const SettingsBranchData();
}

class SettingsRoute extends GoRouteData with $SettingsRoute {
  final String? category;
  const SettingsRoute({this.category});

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      SettingsScreen(initialCategory: category);
}

// --- Sub-routes of Settings ---

class PlayerSettingsRoute extends GoRouteData with $PlayerSettingsRoute {
  const PlayerSettingsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const PlayerSettingsScreen();

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

class AccountSettingsRoute extends GoRouteData with $AccountSettingsRoute {
  const AccountSettingsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const AccountSettingsScreen();

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

class ExtensionsRoute extends GoRouteData with $ExtensionsRoute {
  const ExtensionsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const ExtensionsScreen();
}

class NuvioPluginsRoute extends GoRouteData with $NuvioPluginsRoute {
  const NuvioPluginsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const NuvioPluginsScreen();

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

class CloudStreamRoute extends GoRouteData with $CloudStreamRoute {
  const CloudStreamRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const CloudStreamScreen();

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

class AddonsRoute extends GoRouteData with $AddonsRoute {
  final int? initialTab;
  const AddonsRoute({this.initialTab});

  @override
  Widget build(BuildContext context, GoRouterState state) =>
      AddonsScreen(initialTab: initialTab ?? 0);

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

class DeveloperOptionsRoute extends GoRouteData with $DeveloperOptionsRoute {
  const DeveloperOptionsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) =>
      const DeveloperOptionsScreen();

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

@TypedGoRoute<AppLogsRoute>(path: '/logs')
class AppLogsRoute extends GoRouteData with $AppLogsRoute {
  const AppLogsRoute();
  @override
  Widget build(BuildContext context, GoRouterState state) {
    return TalkerScreen(
      talker: talker,
      theme: TalkerScreenTheme(
        backgroundColor: Theme.of(context).colorScheme.surface,
        textColor: Theme.of(context).colorScheme.onSurface,
        cardColor: Theme.of(context).colorScheme.surface,
      ),
    );
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

// --- Typed Extras ---

class DetailsRouteExtra {
  const DetailsRouteExtra({required this.item, this.autoPlay = false});
  final MultimediaItem item;
  final bool autoPlay;
}

class PlayerRouteExtra {
  const PlayerRouteExtra({
    required this.item,
    required this.videoUrl,
    this.episode,
    this.preloadedStreams,
  });
  final MultimediaItem item;
  final String videoUrl;
  final Episode? episode;

  /// Cross-plugin stream links aggregated before opening the player. When
  /// present, the player does not call loadStreams again for this item/episode.
  final List<StreamResult>? preloadedStreams;
}

class ViewAllRouteExtra {
  const ViewAllRouteExtra({
    required this.title,
    required this.initialMediaList,
    required this.category,
    this.onTap,
  });
  final String title;
  final List<MultimediaItem> initialMediaList;
  final ViewAllCategory category;
  final void Function(MultimediaItem item)? onTap;
}

// --- Route Extra Codec ---

/// Serializes/deserializes route extras so Android can restore routes after
/// process death without losing the pushed data.
class RouteExtraCodec extends Codec<Object?, Object?> {
  const RouteExtraCodec();

  @override
  Converter<Object?, Object?> get encoder => const _RouteExtraEncoder();

  @override
  Converter<Object?, Object?> get decoder => const _RouteExtraDecoder();
}

class _RouteExtraEncoder extends Converter<Object?, Object?> {
  const _RouteExtraEncoder();

  @override
  Object? convert(Object? input) {
    if (input == null) return null;
    if (input is DetailsRouteExtra) {
      return <String, dynamic>{
        '_type': 'DetailsRouteExtra',
        'item': input.item.toJson(),
        'autoPlay': input.autoPlay,
      };
    }
    if (input is PlayerRouteExtra) {
      return <String, dynamic>{
        '_type': 'PlayerRouteExtra',
        'item': input.item.toJson(),
        'videoUrl': input.videoUrl,
        if (input.episode != null) 'episode': input.episode!.toJson(),
        if (input.preloadedStreams != null)
          'preloadedStreams':
              input.preloadedStreams!.map((s) => s.toJson()).toList(),
      };
    }
    if (input is ViewAllRouteExtra) {
      return <String, dynamic>{
        '_type': 'ViewAllRouteExtra',
        'title': input.title,
        'initialMediaList':
            input.initialMediaList.map((e) => e.toJson()).toList(),
        'category': input.category.name,
        // onTap is a callback — cannot be serialized; will be null on restore.
      };
    }
    return input;
  }
}

class _RouteExtraDecoder extends Converter<Object?, Object?> {
  const _RouteExtraDecoder();

  @override
  Object? convert(Object? input) {
    if (input == null) return null;
    if (input is! Map) return input;
    final map = Map<String, dynamic>.from(input);
    switch (map['_type']) {
      case 'DetailsRouteExtra':
        return DetailsRouteExtra(
          item: MultimediaItem.fromJson(
            Map<String, dynamic>.from(map['item'] as Map),
          ),
          autoPlay: map['autoPlay'] as bool? ?? false,
        );
      case 'PlayerRouteExtra':
        return PlayerRouteExtra(
          item: MultimediaItem.fromJson(
            Map<String, dynamic>.from(map['item'] as Map),
          ),
          videoUrl: map['videoUrl'] as String,
          episode: map['episode'] != null
              ? Episode.fromJson(
                  Map<String, dynamic>.from(map['episode'] as Map),
                )
              : null,
          preloadedStreams: map['preloadedStreams'] != null
              ? (map['preloadedStreams'] as List)
                    .map(
                      (s) => StreamResult.fromJson(
                        Map<String, dynamic>.from(s as Map),
                      ),
                    )
                    .toList()
              : null,
        );
      case 'ViewAllRouteExtra':
        return ViewAllRouteExtra(
          title: map['title'] as String,
          initialMediaList: (map['initialMediaList'] as List)
              .map(
                (e) => MultimediaItem.fromJson(
                  Map<String, dynamic>.from(e as Map),
                ),
              )
              .toList(),
          category: ViewAllCategory.values.firstWhere(
            (c) => c.name == map['category'],
            orElse: () => ViewAllCategory.trending,
          ),
          // onTap cannot be restored — callers must handle null.
        );
      default:
        return input;
    }
  }
}

// --- Full Screen Routes ---

@TypedGoRoute<DetailsRoute>(path: '/details')
class DetailsRoute extends GoRouteData with $DetailsRoute {
  const DetailsRoute({required this.$extra});
  final DetailsRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return DetailsScreen(item: $extra.item, autoPlay: $extra.autoPlay);
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

@TypedGoRoute<TmdbDetailsRoute>(path: '/tmdb-details')
class TmdbDetailsRoute extends GoRouteData with $TmdbDetailsRoute {
  const TmdbDetailsRoute({
    required this.movieId,
    this.mediaType = 'movie',
    this.heroTag,
    this.placeholderPoster,
    this.source,
  });
  final int movieId;
  final String mediaType;
  final String? heroTag;
  final String? placeholderPoster;
  final String? source;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return TmdbMovieDetailsScreen(
      movieId: movieId,
      mediaType: mediaType,
      heroTag: heroTag,
      placeholderPoster: placeholderPoster,
      source: source,
    );
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

@TypedGoRoute<ViewAllRoute>(path: '/view-all')
class ViewAllRoute extends GoRouteData with $ViewAllRoute {
  const ViewAllRoute({required this.$extra});
  final ViewAllRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return ViewAllScreen(
      title: $extra.title,
      initialMediaList: $extra.initialMediaList,
      category: $extra.category,
      onTap: $extra.onTap,
    );
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

/// Location of [PlayerRoute], as a value other layers can compare against.
///
/// The player is a *top-level* route, not a shell child, so the root Navigator
/// builds it underneath everything `MaterialApp.router`'s builder wraps around
/// the router - the global toast overlay included. Anything that has to stand
/// down while a full-screen video is on needs to recognise this location, and
/// `@TypedGoRoute` only accepts a literal, so the literal is mirrored here and
/// pinned to `PlayerRoute.location` by a test rather than left to drift.
const String kPlayerRoutePath = '/player';

/// Whether the route on top of the root Navigator is the player.
///
/// The single copy of that question. The global toast layer stands down over
/// full-screen video and so does the update prompt; two hand-rolled answers
/// would eventually disagree about a transition frame or an empty match list,
/// and only one of them would get fixed.
///
/// Every entry point *pushes* [kPlayerRoutePath]
/// (`PlayerRoute(...).push(context)`), and go_router deliberately leaves
/// `RouteMatchList.uri` on the location that did the pushing - so the pushed
/// location has to be read off the top match's state rather than off the
/// match list.
bool playerRouteIsOnTop(GoRouter router) {
  // `state` reads `currentConfiguration.last`, which throws on the empty match
  // list the delegate starts life with.
  if (router.routerDelegate.currentConfiguration.isEmpty) return false;
  return router.state.uri.path == kPlayerRoutePath;
}

@TypedGoRoute<PlayerRoute>(path: '/player')
class PlayerRoute extends GoRouteData with $PlayerRoute {
  const PlayerRoute({required this.$extra});
  final PlayerRouteExtra $extra;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return MpvPlayerScreen(
      item: $extra.item,
      videoUrl: $extra.videoUrl,
      episode: $extra.episode,
      preloadedStreams: $extra.preloadedStreams,
    );
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

@TypedGoRoute<AddonDetailRoute>(path: '/addon-detail')
class AddonDetailRoute extends GoRouteData with $AddonDetailRoute {
  const AddonDetailRoute({required this.type, required this.id, this.addonUrl});
  final String type;
  final String id;
  final String? addonUrl;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AddonDetailScreen(type: type, id: id, addonUrl: addonUrl);
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

@TypedGoRoute<AddonCatalogRoute>(path: '/addon-catalog')
class AddonCatalogRoute extends GoRouteData with $AddonCatalogRoute {
  const AddonCatalogRoute({
    required this.addonUrl,
    required this.type,
    required this.catalogId,
    required this.title,
  });
  final String addonUrl;
  final String type;
  final String catalogId;
  final String title;

  @override
  Widget build(BuildContext context, GoRouterState state) {
    return AddonCatalogScreen(
      addonUrl: addonUrl,
      type: type,
      catalogId: catalogId,
      title: title,
    );
  }

  // Same smooth slide + fade as every other pushed page (see
  // route_transitions.dart).
  @override
  Page<void> buildPage(BuildContext context, GoRouterState state) =>
      smoothPage(key: state.pageKey, child: build(context, state));
}

// --- GoRouter Definition ---

final rootNavigatorKey = GlobalKey<NavigatorState>();

/// Branch roots the shell can start on. `/stream` no longer exists, so a
/// preference saved by an older build has to be migrated instead of handing
/// GoRouter an unknown initial location. Same for `/explore` (the Explore
/// tab was replaced by Plugins in ZoroX v3) and `/detail` (the Detail tab
/// was replaced by Browse in ZoroX v4).
const List<String> kShellBranchRoutes = [
  '/home',
  '/search',
  '/extensions',
  '/library',
  '/browse',
  '/settings',
];

@Riverpod(keepAlive: true)
GoRouter appRouter(Ref ref) {
  final saved = ref.read(settingsRepositoryProvider).getDefaultHomeScreen();
  final initial = kShellBranchRoutes.contains(saved) ? saved : '/home';

  return GoRouter(
    initialLocation: initial,
    navigatorKey: rootNavigatorKey,
    debugLogDiagnostics: kDebugMode,
    routes: $appRoutes,
    extraCodec: const RouteExtraCodec(),
  );
}

// End of Routes
