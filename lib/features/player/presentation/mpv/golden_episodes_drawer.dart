/// The golden Episodes drawer: a right-side sliding panel with the season
/// selector and the episode list.
///
/// Real episode data only — the same `effectiveEpisodes` list the next arrow
/// walks, so what this offers and what the arrows do can never disagree.
/// The playing episode is highlighted in gold with an equalizer mark; a
/// part-watched episode carries a gold progress bar on its still; a watched
/// one is dimmed. Tap a row to play it. Movies never open this drawer (the
/// screen only offers the button on a series).
library;

import 'package:flutter/material.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../vlc/panel/player_panel_data.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';

/// How the drawer learns an episode's length: the history's exact seconds
/// first (mm:ss), else the plugin's runtime in minutes ("54 min").
typedef GoldenEpisodeDuration = Duration? Function(Episode episode);

class GoldenEpisodesDrawer extends StatefulWidget {
  const GoldenEpisodesDrawer({
    required this.episodes,
    required this.currentEpisode,
    required this.onPick,
    required this.onClose,
    this.episodeProgress,
    this.episodeDuration,
    super.key,
  });

  final List<Episode> episodes;
  final Episode? currentEpisode;
  final ValueChanged<Episode> onPick;

  /// Closes the drawer. The drawer is an overlay, not a route, so this is
  /// the controls' own close — never a Navigator pop.
  final VoidCallback onClose;
  final EpisodeProgressLookup? episodeProgress;
  final GoldenEpisodeDuration? episodeDuration;

  @override
  State<GoldenEpisodesDrawer> createState() => _GoldenEpisodesDrawerState();
}

class _GoldenEpisodesDrawerState extends State<GoldenEpisodesDrawer> {
  late int _season;

  @override
  void initState() {
    super.initState();
    // Open on the season that is playing, else the first season there is.
    _season = widget.currentEpisode?.season ?? _seasons.firstOrNull ?? 0;
    if (!_seasons.contains(_season)) _season = _seasons.firstOrNull ?? 0;
  }

  List<int> get _seasons {
    final seasons = <int>{
      for (final e in widget.episodes) e.season,
    }.toList()
      ..sort();
    return seasons;
  }

  List<Episode> get _visible =>
      _seasons.length <= 1
          ? widget.episodes
          : widget.episodes.where((e) => e.season == _season).toList();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = width * 0.85 > 400 ? 400.0 : width * 0.85;
    final seasons = _seasons;
    final visible = _visible;
    final current = widget.currentEpisode;

    return GoldenDrawer(
      title: 'Episodes',
      width: drawerWidth,
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (seasons.length > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _SeasonPill(
                  seasons: seasons,
                  selected: _season,
                  onSelected: (season) =>
                      setState(() => _season = season),
                ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              itemCount: visible.length,
              itemBuilder: (context, index) {
                final episode = visible[index];
                final isCurrent = episode == current;
                final progress =
                    widget.episodeProgress?.call(episode) ??
                    EpisodeProgress.none;
                return _EpisodeRow(
                  episode: episode,
                  isCurrent: isCurrent,
                  progress: progress,
                  duration: widget.episodeDuration?.call(episode),
                  onTap: () => widget.onPick(episode),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The season picker: a gold-outlined pill that opens a menu of seasons.
class _SeasonPill extends StatelessWidget {
  const _SeasonPill({
    required this.seasons,
    required this.selected,
    required this.onSelected,
  });

  final List<int> seasons;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      initialValue: selected,
      onSelected: onSelected,
      color: GoldenPlayerColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
        side: const BorderSide(color: GoldenPlayerColors.divider),
      ),
      itemBuilder: (context) => <PopupMenuEntry<int>>[
        for (final season in seasons)
          PopupMenuItem<int>(
            value: season,
            child: Text(
              'Season $season',
              style: TextStyle(
                color: season == selected
                    ? GoldenPlayerColors.goldHighlight
                    : GoldenPlayerColors.textPrimary,
                fontWeight: season == selected
                    ? FontWeight.w700
                    : FontWeight.w500,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(GoldenPlayerRadii.pill),
          border: Border.all(
            color: GoldenPlayerColors.gold.withValues(alpha: 0.6),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Season $selected',
              style: const TextStyle(
                color: GoldenPlayerColors.goldHighlight,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 18,
              color: GoldenPlayerColors.goldHighlight,
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeRow extends StatelessWidget {
  const _EpisodeRow({
    required this.episode,
    required this.isCurrent,
    required this.progress,
    required this.duration,
    required this.onTap,
  });

  final Episode episode;
  final bool isCurrent;
  final EpisodeProgress progress;
  final Duration? duration;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final number = episode.episode > 0 ? 'E${episode.episode}' : '';
    final name = episode.name.trim();
    final title = name.isEmpty
        ? number
        : (number.isEmpty ? name : '$number  $name');
    final durationText = _durationText();

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isCurrent
                  ? GoldenPlayerColors.gold.withValues(alpha: 0.12)
                  : GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              border: Border.all(
                color: isCurrent
                    ? GoldenPlayerColors.gold
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: <Widget>[
                _EpisodeThumb(
                  posterUrl: episode.posterUrl,
                  isCurrent: isCurrent,
                  progress: isCurrent || progress.watched
                      ? 0
                      : progress.fraction,
                  watched: !isCurrent && progress.watched,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? GoldenPlayerColors.goldHighlight
                              : GoldenPlayerColors.textPrimary,
                          fontWeight: isCurrent
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (durationText != null) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(
                          durationText,
                          style: const TextStyle(
                            color: GoldenPlayerColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isCurrent)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: _EqualizerBars(),
                  )
                else if (progress.watched)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle_outline_rounded,
                      size: 20,
                      color: GoldenPlayerColors.gold,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _durationText() {
    final exact = duration;
    if (exact != null && exact > Duration.zero) {
      return goldenFormatTime(exact);
    }
    final runtime = episode.runtime;
    if (runtime != null && runtime > 0) return '$runtime min';
    return null;
  }
}

/// The mockup's equalizer mark on the playing row: three gold bars.
class _EqualizerBars extends StatelessWidget {
  const _EqualizerBars();

  @override
  Widget build(BuildContext context) {
    return const Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        _Bar(height: 8),
        SizedBox(width: 2),
        _Bar(height: 14),
        SizedBox(width: 2),
        _Bar(height: 10),
      ],
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: GoldenPlayerColors.gold,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}

class _EpisodeThumb extends StatelessWidget {
  const _EpisodeThumb({
    required this.posterUrl,
    required this.isCurrent,
    this.progress = 0,
    this.watched = false,
  });

  final String? posterUrl;
  final bool isCurrent;
  final double progress;
  final bool watched;

  @override
  Widget build(BuildContext context) {
    final poster = posterUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 96,
        height: 54,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (poster != null && poster.isNotEmpty)
              Image.network(
                poster,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const _ThumbPlaceholder(),
                loadingBuilder: (context, child, loadingProgress) =>
                    loadingProgress == null
                    ? child
                    : const _ThumbPlaceholder(),
              )
            else
              const _ThumbPlaceholder(),
            if (watched) const ColoredBox(color: Color(0x47000000)),
            if (isCurrent)
              const ColoredBox(
                color: Color(0x66000000),
                child: Center(
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ),
            if (progress > 0.02 && progress < 0.98)
              Align(
                alignment: Alignment.bottomCenter,
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    GoldenPlayerColors.gold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ThumbPlaceholder extends StatelessWidget {
  const _ThumbPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0x14FFFFFF),
      child: Center(
        child: Icon(
          Icons.movie_outlined,
          color: GoldenPlayerColors.textSecondary,
          size: 20,
        ),
      ),
    );
  }
}
