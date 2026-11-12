/// The mpv player's subtitle (CC) bottom sheet: two tabs, Subtitles and
/// Style.
///
/// Subtitles picks the track — Off, the plugin's own files, the embedded
/// tracks, or a local file the viewer adds. Style restyles the caption live:
/// size, text colour, background, edge, and position (a slider plus the
/// +5/+10/−5/−10 nudge buttons, original-SkyStream style), and resets.
///
/// Style writes go straight to the saved [PlayerSettings], so the on-video
/// caption restyles at once and the choice persists between sessions; only
/// a track pick closes the sheet, returning the track to play.
///
/// One honest limit, shown in the sheet rather than hidden: the mpv engine
/// (media_kit 1.2.6) exposes no subtitle-delay API — no `setSubtitleDelay`,
/// no property setter — so the delay stepper is present but disabled, with
/// the reason beside it. libVLC has the delay; mpv does not, and a stepper
/// that moved a number without moving the captions would be a lie.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';

import '../../../../core/domain/entity/multimedia_item.dart';
import '../../../settings/presentation/player_settings_provider.dart';
import 'mpv_subtitle_style.dart';

const _gold = Color(0xffd4af37);
const _dark = Color(0xff1b1b1b);
const _sheetBackground = Color(0xff181818);

/// Shows the CC sheet and returns the subtitle track the viewer picked, or
/// null when the sheet was dismissed or only the style changed.
Future<SubtitleTrack?> showMpvCcSheet({
  required BuildContext context,
  required List<SubtitleTrack> embedded,
  required List<SubtitleFile> external,
  required SubtitleTrack current,
}) {
  return showModalBottomSheet<SubtitleTrack?>(
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
      child: _MpvCcSheet(
        embedded: embedded,
        external: external,
        current: current,
      ),
    ),
  );
}

class _MpvCcSheet extends ConsumerWidget {
  const _MpvCcSheet({
    required this.embedded,
    required this.external,
    required this.current,
  });

  final List<SubtitleTrack> embedded;
  final List<SubtitleFile> external;
  final SubtitleTrack current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings =
        ref.watch(playerSettingsProvider).asData?.value ??
        const PlayerSettings();
    return DefaultTabController(
      length: 2,
      child: Column(
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
          const TabBar(
            tabs: [
              Tab(text: 'Subtitles'),
              Tab(text: 'Style'),
            ],
            labelColor: _gold,
            unselectedLabelColor: Colors.white70,
            indicatorColor: _gold,
          ),
          Expanded(
            child: TabBarView(
              children: [
                _SubtitlesTab(
                  embedded: embedded,
                  external: external,
                  current: current,
                ),
                _StyleTab(settings: settings),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// -- Subtitles tab ----------------------------------------------------------

class _SubtitlesTab extends StatelessWidget {
  const _SubtitlesTab({
    required this.embedded,
    required this.external,
    required this.current,
  });

  final List<SubtitleTrack> embedded;
  final List<SubtitleFile> external;
  final SubtitleTrack current;

  Future<void> _pickLocalFile(BuildContext context) async {
    final picked = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['srt', 'vtt', 'ass', 'ssa', 'sub'],
    );
    final path = picked?.path;
    if (path == null || path.isEmpty) return;
    if (!context.mounted) return;
    Navigator.of(context).pop(SubtitleTrack.uri(path, title: picked!.name));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _trackRow(
          context,
          label: 'Off',
          selected: current.id == 'no',
          onTap: () => Navigator.of(context).pop(SubtitleTrack.no()),
        ),
        for (final sub in external)
          _trackRow(
            context,
            label: sub.label,
            detail: 'Source',
            selected: current.title == sub.label,
            onTap: () => Navigator.of(context).pop(
              SubtitleTrack.uri(sub.url, title: sub.label),
            ),
          ),
        for (final sub in embedded)
          _trackRow(
            context,
            label: sub.title ?? 'Subtitle ${sub.id}',
            selected: current.id == sub.id,
            onTap: () => Navigator.of(context).pop(sub),
          ),
        ListTile(
          leading: const Icon(Icons.file_upload, color: Colors.white70),
          title: const Text(
            'Add local file',
            style: TextStyle(color: Colors.white),
          ),
          subtitle: const Text(
            '.srt, .vtt, .ass',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
          onTap: () => _pickLocalFile(context),
        ),
        const Divider(color: Colors.white12),
        // Delay: the mpv engine has no delay API, so this is shown disabled
        // with the reason, rather than a stepper that does nothing.
        ListTile(
          title: const Text(
            'Delay',
            style: TextStyle(color: Colors.white54),
          ),
          subtitle: const Text(
            'Not available on the mpv engine',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _stepButton(label: '−', enabled: false, onTap: () {}),
              const SizedBox(width: 8),
              const Text(
                '0.0s',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
              const SizedBox(width: 8),
              _stepButton(label: '+', enabled: false, onTap: () {}),
            ],
          ),
        ),
      ],
    );
  }

  Widget _trackRow(
    BuildContext context, {
    required String label,
    String? detail,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return ListTile(
      title: Text(label, style: const TextStyle(color: Colors.white)),
      subtitle: detail == null
          ? null
          : Text(detail, style: const TextStyle(color: Colors.white54)),
      trailing: selected
          ? const Icon(Icons.check, color: _gold)
          : null,
      onTap: onTap,
    );
  }
}

Widget _stepButton({
  required String label,
  required bool enabled,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: enabled ? onTap : null,
    child: Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: enabled ? Colors.white : Colors.white38,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
}

// -- Style tab --------------------------------------------------------------

class _StyleTab extends ConsumerWidget {
  const _StyleTab({required this.settings});

  final PlayerSettings settings;

  PlayerSettingsNotifier _notifier(WidgetRef ref) =>
      ref.read(playerSettingsProvider.notifier);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = _notifier(ref);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        // Live preview line at the top, drawn with the saved style and
        // lifted by the saved raise, so a change shows here at once.
        Container(
          height: 72,
          alignment: Alignment.bottomCenter,
          padding: EdgeInsets.only(
            bottom: 10 + settings.subtitleRaise * 120,
            left: 12,
            right: 12,
          ),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white12),
          ),
          child: Text(
            'This is how subtitles will look',
            textAlign: TextAlign.center,
            style: mpvSubtitleTextStyle(settings),
          ),
        ),
        const SizedBox(height: 16),
        _sectionLabel('Size'),
        Wrap(
          spacing: 8,
          children: [
            for (final entry in kMpvSubtitleSizes.entries)
              _choiceChip(
                label: entry.key,
                selected: mpvSizeStepFor(settings.subtitleSize) == entry.key,
                onTap: () => notifier.setSubtitleSize(entry.value),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel('Text colour'),
        Wrap(
          spacing: 12,
          children: [
            for (final color in kMpvSubtitleColors)
              _colorSwatch(
                color: Color(color.$2),
                selected: settings.subtitleColor == color.$2,
                onTap: () => notifier.setSubtitleColor(color.$2),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel('Background'),
        Wrap(
          spacing: 8,
          children: [
            for (final background in kMpvSubtitleBackgrounds)
              _choiceChip(
                label: background.$1,
                selected:
                    mpvBackgroundFor(settings.subtitleBackgroundOpacity) ==
                    background.$1,
                onTap: () => notifier.setSubtitleBackground(
                  0xFF000000,
                  background.$2,
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel('Edge'),
        Wrap(
          spacing: 8,
          children: [
            for (final edge in kMpvSubtitleEdges)
              _choiceChip(
                label: edge,
                selected: mpvEdgeFor(settings) == edge,
                onTap: () {
                  switch (edge) {
                    case 'None':
                      notifier.setSubtitleShadow(false);
                      notifier.setSubtitleOutline(SubtitleOutline.none);
                    case 'Outline':
                      notifier.setSubtitleShadow(false);
                      notifier.setSubtitleOutline(SubtitleOutline.thin);
                    case 'Shadow':
                      notifier.setSubtitleOutline(SubtitleOutline.none);
                      notifier.setSubtitleShadow(true);
                  }
                },
              ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionLabel('Position'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: settings.subtitleRaise.clamp(0.0, 0.2),
                min: 0,
                max: 0.2,
                divisions: 20,
                activeColor: _gold,
                inactiveColor: Colors.white24,
                onChanged: (value) => notifier.setSubtitleRaise(value),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                settings.subtitleRaise.toStringAsFixed(2),
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ],
        ),
        // Fine up/down nudge, original-SkyStream style: +5/+10 lifts the
        // caption, −5/−10 lowers it, by one stock raise step at a time.
        Row(
          children: [
            const Text(
              'Nudge',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(width: 8),
            _nudgeButton(
              label: '−10',
              onTap: () => notifier.setSubtitleRaise(
                settings.subtitleRaise - kMpvRaiseNudgeLarge,
              ),
            ),
            const SizedBox(width: 6),
            _nudgeButton(
              label: '−5',
              onTap: () => notifier.setSubtitleRaise(
                settings.subtitleRaise - kMpvRaiseNudgeSmall,
              ),
            ),
            const SizedBox(width: 6),
            _nudgeButton(
              label: '+5',
              onTap: () => notifier.setSubtitleRaise(
                settings.subtitleRaise + kMpvRaiseNudgeSmall,
              ),
            ),
            const SizedBox(width: 6),
            _nudgeButton(
              label: '+10',
              onTap: () => notifier.setSubtitleRaise(
                settings.subtitleRaise + kMpvRaiseNudgeLarge,
              ),
            ),
            const Spacer(),
            const Text(
              'up (+) / down (−)',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: () => notifier.resetSubtitleSettings(),
            child: const Text(
              'Reset subtitle style',
              style: TextStyle(color: _gold),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _choiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _gold : Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? _dark : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _colorSwatch({
    required Color color,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? _gold : Colors.white24,
            width: selected ? 2 : 1,
          ),
        ),
      ),
    );
  }

  Widget _nudgeButton({
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
