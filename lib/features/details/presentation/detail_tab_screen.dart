import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../library/presentation/history_provider.dart';
import 'details_screen.dart';

/// The "Detail" tab of the ZoroX bottom nav (approved design preview:
/// Home / Search / Plugins / Library / Detail, exactly as shown).
///
/// Shows the detail page of the most recently watched item — the same
/// screen a poster tap opens — with the floating pill nav still visible,
/// exactly as the preview shows the Detail screen above the tab bar.
/// (The back button inside DetailsScreen is a no-op here: the tab is
/// the root of its branch, so there is nothing to pop; use the pill
/// nav to leave.)
///
/// If nothing has been watched yet, shows a short empty state that
/// points back to Home.
class DetailTabScreen extends ConsumerWidget {
  const DetailTabScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(watchHistoryProvider);
    final theme = Theme.of(context);

    if (history.isEmpty) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.movie_outlined,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Abhi kuch dekha nahi',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Home ya Search se kuch kholo — uska detail yahan milega.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => context.go('/home'),
                  child: const Text('Home kholo'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Most recently watched first (by timestamp, not storage order).
    final sorted = [...history]
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return DetailsScreen(item: sorted.first.item);
  }
}
