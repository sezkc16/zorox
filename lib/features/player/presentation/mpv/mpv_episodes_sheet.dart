/// The mpv player's Episodes bottom sheet: a season dropdown at the top,
/// then the season's episodes. Each row has a thumbnail, "E3 · Title",
/// duration, and a small progress bar. The episode playing now has a gold
/// border and a "Now playing" tag; watched episodes are dimmed. Tapping a
/// row switches to that episode.
///
/// Progress and watched state come from the same history repository the
/// player writes to, so a row's bar is the position Continue Watching
/// would resume from. The episode list is the dub-filtered one the
/// navigator uses, so subbed and dubbed copies of an episode never sit
/// side by side here.
library;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../../core/storage/history_repository.dart';
import '../../domain/episode_navigator.dart';
import '../../domain/playback_progress.dart' show kCompletedFraction;

const _gold = Color(0xffd4af37);
const _dark = Color(0xff1b1b1b);
const _sheetBackground = Color(0xff181818);

/// Shows the Episodes sheet and returns the episode the viewer picked, or
/// null when the sheet was dismissed.
Future<Episode?> showMpvEpisodesSheet({
  required BuildContext context,
  required MultimediaItem item,
  required Episode? current,
  required String videoUrl,
}) {
  return showModalBottomSheet<Episode?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: _sheetBackground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.6,
    ),
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: _MpvEpisodesSheet(
        item: item,
        current: current,
        videoUrl: videoUrl,
      ),
    ),
  );
}

class _MpvEpisodesSheet extends ConsumerStatefulWidget {
  const _MpvEpisodesSheet({
    required this.item,
    required this.current,
    required this.videoUrl,
  });

  final MultimediaItem item;
  final Episode? current;
  final String videoUrl;

  @override
  ConsumerState<_MpvEpisodesSheet> createState() => _MpvEpisodesSheetState();
}

class _MpvEpisodesSheetState extends ConsumerState<_MpvEpisodesSheet> {
  late final List<Episode> _episodes;
  late int _season;

  @override
  void initState() {
    super.initState();
    _episodes = effectiveEpisodes(widget.item, widget.current);
    final seasons = _seasons;
    _season = widget.current != null && seasons.contains(widget.current!.season)
        ? widget.current!.season
        : (seasons.isEmpty ? 0 : seasons.first);
  }

  List<int> get _seasons {
    final seasons = <int>{for (final e in _episodes) e.season};
    final sorted = seasons.toList()..sort();
    return sorted;
  }

  List<Episode> get _seasonEpisodes =>
      _episodes.where((e) => e.season == _season).toList();

  @override
  Widget build(BuildContext context) {
    final seasons = _seasons;
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              const Text(
                'Episodes',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (seasons.length > 1)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: DropdownButton<int>(
                    value: _season,
                    dropdownColor: _sheetBackground,
                    underline: const SizedBox.shrink(),
                    icon: const Icon(
                      Icons.arrow_drop_down,
                      color: Colors.white,
                      size: 18,
                    ),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    items: [
                      for (final season in seasons)
                        DropdownMenuItem<int>(
                          value: season,
                          child: Text('Season $season'),
                        ),
                    ],
                    onChanged: (season) {
                      if (season == null) return;
                      setState(() => _season = season);
                    },
                  ),
                )
              else if (seasons.isNotEmpty)
                Text(
                  'Season ${seasons.first}',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
            ],
          ),
        ),
        const Divider(color: Colors.white12, height: 1),
        Expanded(
          child: ListView(
            children: [
              for (final episode in _seasonEpisodes)
                _EpisodeRow(
                  item: widget.item,
                  episode: episode,
                  isCurrent: episode.url == widget.current?.url,
                  onTap: () => Navigator.of(context).pop(episode),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EpisodeRow extends ConsumerWidget {
  const _EpisodeRow({
    required this.item,
    required this.episode,
    required this.isCurrent,
    required this.onTap,
  });

  final MultimediaItem item;
  final Episode episode;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(historyRepositoryProvider);
    final positionMs = repo.getEpisodePosition(
      episode.url,
      mainUrl: item.url,
      season: episode.season,
      episode: episode.episode,
    );
    final durationMs = repo.getEpisodeDuration(
      episode.url,
      mainUrl: item.url,
      season: episode.season,
      episode: episode.episode,
    );
    final fraction = durationMs > 0
        ? (positionMs / durationMs).clamp(0.0, 1.0)
        : 0.0;
    final watched = fraction >= kCompletedFraction;
    final durationLabel = _durationLabel(episode, durationMs);

    final row = Container(
      decoration: BoxDecoration(
        border: isCurrent
            ? Border.all(color: _gold, width: 1.5)
            : Border.all(color: Colors.transparent, width: 1.5),
        borderRadius: BorderRadius.circular(8),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                _thumbnail(context),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'E${episode.episode} · ${episode.name}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          if (isCurrent)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: _gold,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'Now playing',
                                style: TextStyle(
                                  color: _dark,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (durationLabel != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          durationLabel,
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ],
                      if (fraction > 0) ...[
                        const SizedBox(height: 6),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: fraction,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              _gold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    // Watched episodes are dimmed; the one playing now never is.
    if (watched && !isCurrent) {
      return Opacity(opacity: 0.5, child: row);
    }
    return row;
  }

  Widget _thumbnail(BuildContext context) {
    final url = episode.posterUrl ?? item.posterUrl;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 96,
        height: 54,
        child: url.isEmpty
            ? Container(
                color: Colors.white12,
                child: const Icon(
                  Icons.movie,
                  color: Colors.white38,
                  size: 20,
                ),
              )
            : CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    Container(color: Colors.white12),
                errorWidget: (_, _, _) => Container(
                  color: Colors.white12,
                  child: const Icon(
                    Icons.movie,
                    color: Colors.white38,
                    size: 20,
                  ),
                ),
              ),
      ),
    );
  }

  /// The episode's own runtime first (minutes, as the plugin reported it),
  /// else the duration this device has stored for it.
  String? _durationLabel(Episode episode, int durationMs) {
    if (episode.runtime != null && episode.runtime! > 0) {
      return '${episode.runtime} min';
    }
    if (durationMs > 0) {
      final totalSeconds = durationMs ~/ 1000;
      final minutes = totalSeconds ~/ 60;
      final seconds = totalSeconds % 60;
      if (minutes >= 60) {
        final hours = minutes ~/ 60;
        final rest = minutes % 60;
        return '$hours:${rest.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
      }
      return '$minutes:${seconds.toString().padLeft(2, '0')}';
    }
    return null;
  }
}
