import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/accent_color.dart';
import '../../../../core/utils/layout_constants.dart';

/// Accent color picker (ZoroX v7, 2.9.6) — the swatches row under the
/// "Theme" tile in Settings > General.
///
/// Tapping a swatch sets the accent immediately across the whole app
/// (the theme is seeded from the accent, so the MaterialApp rebuilds —
/// no restart, no re-login). Gold is the default; the background stays
/// black and the layout is untouched, only the accent changes.
class AccentColorPicker extends ConsumerWidget {
  const AccentColorPicker({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = ref.watch(accentColorProvider);
    final primary = Theme.of(context).colorScheme.primary;

    return Column(
      children: [
        ListTile(
          leading: Container(
            padding: const EdgeInsets.all(LayoutConstants.spacingXs),
            decoration: BoxDecoration(
              color: primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.palette_rounded, color: primary, size: 20),
          ),
          title: const Text(
            'Accent color',
            style: TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            accent.label,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(56, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final option in ZoroxAccent.values)
                  _Swatch(
                    option: option,
                    selected: option == accent,
                    onTap: () => ref
                        .read(accentColorProvider.notifier)
                        .setAccent(option),
                  ),
              ],
            ),
          ),
        ),
        Divider(
          height: 1,
          indent: 56,
          endIndent: 16,
          color: Theme.of(context).dividerColor.withValues(alpha: 0.8),
        ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final ZoroxAccent option;
  final bool selected;
  final VoidCallback onTap;

  const _Swatch({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // A dark check on the light accents (Gold, Orange, Green, Cyan),
    // a white check on the dark ones (Red, Blue, Purple, Pink).
    final checkColor = option.color.computeLuminance() > 0.5
        ? Colors.black
        : Colors.white;
    return Semantics(
      button: true,
      selected: selected,
      label: option.label,
      child: Tooltip(
        message: option.label,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: option.color,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? Theme.of(context).colorScheme.onSurface
                    : option.color.withValues(alpha: 0.4),
                width: selected ? 2.5 : 1.5,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: option.color.withValues(alpha: 0.5),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: selected
                ? Icon(Icons.check_rounded, color: checkColor, size: 20)
                : null,
          ),
        ),
      ),
    );
  }
}
