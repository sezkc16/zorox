/// The golden "Audio & Sources" drawer: a right-side sliding panel with
/// the audio track list and the source list.
///
/// Audio tracks come from the engine (embedded + the plugin's files, via
/// the controller), the sources from the screen's [PanelData] — the same
/// candidates, in the same order, as the pre-play list. A tap switches the
/// track or the source at once; a failed source is marked and stays
/// tappable (a retry). No Quality section: mpv's ABR picks the rendition,
/// so there is no ladder to offer.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../domain/source_row_status.dart';
import '../vlc/panel/player_panel_data.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';

class GoldenAudioSourcesDrawer extends StatefulWidget {
  const GoldenAudioSourcesDrawer({
    required this.controller,
    required this.panelData,
    required this.onClose,
    this.onAudioPicked,
    this.onPickSource,
    super.key,
  });

  /// The engine, for the audio track list.
  final VlcPlayerController controller;

  /// The screen's published data (sources + current index + failures).
  final ValueListenable<PanelData> panelData;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  /// Remembered across failover by the screen: the audio id the viewer
  /// picked, so the next source re-applies it.
  final ValueChanged<VlcTrackDescription>? onAudioPicked;

  /// Opens a source from where the viewer was.
  final ValueChanged<int>? onPickSource;

  @override
  State<GoldenAudioSourcesDrawer> createState() =>
      _GoldenAudioSourcesDrawerState();
}

class _GoldenAudioSourcesDrawerState
    extends State<GoldenAudioSourcesDrawer> {
  List<VlcTrackDescription> _audioTracks = const <VlcTrackDescription>[];
  int _trackRevision = -1;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _refreshTracks();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    final revision = widget.controller.value.trackRevision;
    if (revision != _trackRevision) {
      _refreshTracks();
    } else if (mounted) {
      // The track list is the same but the ACTIVE track changed (a pick):
      // repaint so the selected radio follows the pick at once instead of
      // staying on the stale row.
      setState(() {});
    }
  }

  Future<void> _refreshTracks() async {
    final revision = widget.controller.value.trackRevision;
    final tracks = await widget.controller.getAudioTracks();
    if (!mounted) return;
    setState(() {
      _trackRevision = revision;
      _audioTracks = tracks;
    });
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = width * 0.85 > 400 ? 400.0 : width * 0.85;
    return GoldenDrawer(
      title: 'Audio & Sources',
      width: drawerWidth,
      onClose: widget.onClose,
      child: ValueListenableBuilder<PanelData>(
        valueListenable: widget.panelData,
        builder: (context, data, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              const GoldenSectionLabel('Audio'),
              if (_audioTracks.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No audio tracks on this source.',
                    style: TextStyle(
                      color: GoldenPlayerColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                for (final track in _audioTracks)
                  _OptionTile(
                    // The adapter already folds the language into the name
                    // ('MoviesDrives.bid - [English]'), so it is used as-is
                    // — folding it again here would read it twice.
                    label: track.name,
                    detail: _channelName(track.channels),
                    selected:
                        track.id ==
                        widget.controller.value.activeAudioTrackId,
                    onTap: () => _pickAudio(track),
                  ),
              const GoldenSectionLabel('Sources'),
              if (data.sources.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'No sources resolved yet.',
                    style: TextStyle(
                      color: GoldenPlayerColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                )
              else
                for (var i = 0; i < data.sources.length; i++)
                  _OptionTile(
                    label: _sourceLabel(data.sources[i], i),
                    detail: data.failedSources.contains(i)
                        ? 'Failed'
                        : (data.playedSources.contains(i)
                              ? 'Playing'
                              : null),
                    detailIsError: data.failedSources.contains(i),
                    selected: i == data.currentSourceIndex,
                    onTap: () => widget.onPickSource?.call(i),
                  ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickAudio(VlcTrackDescription track) async {
    await widget.controller.setAudioTrack(track.id);
    widget.onAudioPicked?.call(track);
  }

  /// The channel count as the original shows it ("5.1", "Stereo", "Mono").
  String? _channelName(int? channels) => switch (channels) {
    null || <= 0 => null,
    1 => 'Mono',
    2 => 'Stereo',
    6 => '5.1',
    8 => '7.1',
    final int other => '$other ch',
  };

  /// The plugin's own label for the source, led by its provider, with the
  /// quality after it — "HubCloud · 1080p". A source the plugin did not
  /// name at all still gets a row ("Source 3"), never an empty box.
  String _sourceLabel(StreamResult stream, int index) {
    final base = sourceRowLabel(stream);
    final label = base.trim().isEmpty
        ? 'Source ${index + 1}'
        : base;
    final quality = stream.quality;
    return quality != null && quality > 0 ? '$label · ${quality}p' : label;
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
    this.detailIsError = false,
  });

  final String label;
  final String? detail;
  final bool detailIsError;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 11,
            ),
            decoration: BoxDecoration(
              color: selected
                  ? GoldenPlayerColors.gold.withValues(alpha: 0.12)
                  : GoldenPlayerColors.surface.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(GoldenPlayerRadii.card),
              border: Border.all(
                color: selected
                    ? GoldenPlayerColors.gold
                    : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected
                      ? GoldenPlayerColors.gold
                      : GoldenPlayerColors.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: selected
                              ? GoldenPlayerColors.goldHighlight
                              : GoldenPlayerColors.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      if (detail != null) ...<Widget>[
                        const SizedBox(height: 2),
                        Text(
                          detail!,
                          style: TextStyle(
                            color: detailIsError
                                ? const Color(0xFFEF5350)
                                : GoldenPlayerColors.textSecondary,
                            fontSize: 12,
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
  }
}
