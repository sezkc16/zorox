/// The golden "Audio" drawer: a right-side sliding panel with the audio
/// track list.
///
/// Audio tracks come from the engine (embedded + the plugin's files, via
/// the controller). A tap switches the track at once. Sources live in
/// their own drawer ([GoldenSourcesDrawer]) — the two were one drawer,
/// and the viewer asked for them apart. No Quality section: mpv's ABR
/// picks the rendition, so there is no ladder to offer.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../../../../../core/domain/entity/multimedia_item.dart';
import '../../domain/source_row_status.dart';
import '../vlc/panel/player_panel_data.dart';
import 'golden_drawer.dart';
import 'golden_player_theme.dart';

class GoldenAudioDrawer extends StatefulWidget {
  const GoldenAudioDrawer({
    required this.controller,
    required this.onClose,
    this.onAudioPicked,
    super.key,
  });

  /// The engine, for the audio track list.
  final VlcPlayerController controller;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  /// Remembered across failover by the screen: the audio id the viewer
  /// picked, so the next source re-applies it.
  final ValueChanged<VlcTrackDescription>? onAudioPicked;

  @override
  State<GoldenAudioDrawer> createState() => _GoldenAudioDrawerState();
}

class _GoldenAudioDrawerState extends State<GoldenAudioDrawer> {
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
      title: 'Audio',
      width: drawerWidth,
      onClose: widget.onClose,
      child: ListView(
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
        ],
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
}

/// The golden "Sources" drawer: a right-side sliding panel with the
/// source list — the same candidates, in the same order, as the pre-play
/// list. A tap switches the source at once; a failed source is marked
/// and stays tappable (a retry).
///
/// Each row shows the label, then the quality chip ("4K", "1080p") and
/// the server chip ("FSLv2", "PixelDrain") — both always visible even
/// when the label truncates — then the probe status: a green checkmark
/// on a probed-healthy row, a spinner on the row being opened. Audio
/// lives in its own drawer ([GoldenAudioDrawer]); the two were one
/// drawer, and the viewer asked for them apart.
class GoldenSourcesDrawer extends StatelessWidget {
  const GoldenSourcesDrawer({
    required this.panelData,
    required this.onClose,
    this.onPickSource,
    super.key,
  });

  /// The screen's published data (sources + current index + probes +
  /// failures).
  final ValueListenable<PanelData> panelData;

  /// Closes the drawer (overlay close, never a Navigator pop).
  final VoidCallback onClose;

  /// Opens a source from where the viewer was.
  final ValueChanged<int>? onPickSource;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final drawerWidth = width * 0.85 > 400 ? 400.0 : width * 0.85;
    return GoldenDrawer(
      title: 'Sources',
      width: drawerWidth,
      onClose: onClose,
      child: ValueListenableBuilder<PanelData>(
        valueListenable: panelData,
        builder: (context, data, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
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
                  _SourceTile(
                    stream: data.sources[i],
                    index: i,
                    reachability: sourceReachabilityOf(
                      data.sources[i],
                      data.probes[i],
                      hasPlayed: data.playedSources.contains(i),
                    ),
                    playState: sourcePlayStateOf(
                      isCurrent: i == data.currentSourceIndex,
                      hasPicture: data.playedSources.contains(i),
                      failed: data.failedSources.contains(i),
                    ),
                    detail: data.failedSources.contains(i)
                        ? 'Failed'
                        : (data.playedSources.contains(i)
                              ? 'Playing'
                              : null),
                    selected: i == data.currentSourceIndex,
                    onTap: () => onPickSource?.call(i),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// One source row: radio + label + quality chip + server chip + probe
/// status. The chips sit outside the label's [Expanded], so they stay
/// visible when the label truncates — the label is what ellipsises,
/// never the chips.
class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.stream,
    required this.index,
    required this.reachability,
    required this.playState,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final StreamResult stream;
  final int index;
  final SourceReachability reachability;
  final SourcePlayState playState;
  final bool selected;
  final VoidCallback onTap;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final base = sourceRowLabel(stream);
    // A source the plugin did not name at all still gets a row
    // ("Source 3"), never an empty box.
    final label = base.trim().isEmpty ? 'Source ${index + 1}' : base;
    final quality = sourceQualityLabel(stream);
    final server = sourceServer(stream);
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
                            color: detail == 'Failed'
                                ? const Color(0xFFEF5350)
                                : GoldenPlayerColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (quality != null) ...<Widget>[
                  const SizedBox(width: 6),
                  _Chip(label: quality, gold: true),
                ],
                if (server != null && server.isNotEmpty) ...<Widget>[
                  const SizedBox(width: 6),
                  _Chip(label: server, gold: false),
                ],
                if (_statusIcon() != null) ...<Widget>[
                  const SizedBox(width: 8),
                  _statusIcon()!,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The probe status: a spinner on the row being opened (or still being
  /// checked), a green checkmark on a probed-healthy row, a red mark on
  /// a failed one — nothing on a row nobody has asked about yet.
  Widget? _statusIcon() {
    if (playState == SourcePlayState.opening) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          color: GoldenPlayerColors.gold,
          strokeWidth: 2,
        ),
      );
    }
    if (reachability == SourceReachability.checking) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          color: GoldenPlayerColors.gold,
          strokeWidth: 2,
        ),
      );
    }
    if (playState == SourcePlayState.failed) {
      return const Icon(
        Icons.error_outline_rounded,
        size: 18,
        color: Color(0xFFEF5350),
      );
    }
    if (reachability == SourceReachability.reachable) {
      return const Icon(
        Icons.check_rounded,
        size: 20,
        color: Color(0xFF81C784),
      );
    }
    return null;
  }
}

/// A small pill for a chip that must stay visible when the label
/// truncates: gold for the quality, plain for the server.
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.gold});

  final String label;
  final bool gold;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 84),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: gold
              ? GoldenPlayerColors.gold.withValues(alpha: 0.14)
              : GoldenPlayerColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: gold
                ? GoldenPlayerColors.gold.withValues(alpha: 0.45)
                : GoldenPlayerColors.divider,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: gold
                ? GoldenPlayerColors.goldHighlight
                : GoldenPlayerColors.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.detail,
  });

  final String label;
  final String? detail;
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
                          style: const TextStyle(
                            color: GoldenPlayerColors.textSecondary,
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
