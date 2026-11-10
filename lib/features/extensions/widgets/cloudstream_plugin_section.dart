import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/cloudstream/cloudstream_models.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/utils/layout_constants.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../shared/widgets/loading_indicator.dart';

/// The CloudStream part of the Plugins (Extensions) screen.
///
/// SkyStream's own extension system and CloudStream are two separate stores,
/// and the Extensions screen only reads the SkyStream one — so a CloudStream
/// repository seeded at launch never showed up here, and the screen looked
/// empty on a fresh install. These widgets list the CloudStream repositories
/// (and the installed CloudStream plugins) beside SkyStream's own, with
/// install / update / uninstall wired to [CloudStreamRepository].
///
/// The two seeded repositories are the two options the user asked for:
/// "SkyStream" is the owner's own repo (TojiX — the repository for this
/// app), "CloudStream" is the official CloudStream providers repository.
/// The labels come from [CloudStreamRepository.displayNameFor], computed
/// from the URL at display time (a manifest's own name is what a refresh
/// stores, so a stored rename would not survive one).
///
/// The full CloudStream screen (Settings → CloudStream Extensions) still has
/// the switch, the add-repository dialog and each plugin's settings / support
/// buttons; this section is only the repositories and their plugins.

/// The CloudStream repositories, grouped as the two options the Plugins
/// screen offers — "SkyStream" (the owner's TojiX repo) and "CloudStream"
/// (the official repository, plus any other CloudStream-format repository
/// the user added). Nothing when there are none yet (the screen's own empty
/// state covers that); a spinner while the first load is still running.
class CloudStreamRepositoriesSection extends ConsumerWidget {
  const CloudStreamRepositoriesSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    if (state.isLoading && state.repositories.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(LayoutConstants.spacingMd),
        child: Center(child: AppLoadingIndicator()),
      );
    }
    if (state.repositories.isEmpty) return const SizedBox.shrink();
    final skyStream = [
      for (final repo in state.repositories)
        if (CloudStreamRepository.isSkyStreamRepository(repo.url)) repo,
    ];
    final cloudStream = [
      for (final repo in state.repositories)
        if (!CloudStreamRepository.isSkyStreamRepository(repo.url)) repo,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (skyStream.isNotEmpty) ...[
          const _GroupHeader(
            icon: Icons.extension_rounded,
            label: 'SkyStream',
          ),
          for (final repo in skyStream)
            _CloudStreamRepositoryCard(repo: repo),
        ],
        if (cloudStream.isNotEmpty) ...[
          const _GroupHeader(icon: Icons.cloud_rounded, label: 'CloudStream'),
          for (final repo in cloudStream)
            _CloudStreamRepositoryCard(repo: repo),
        ],
      ],
    );
  }
}

/// A section header for one of the two repository options, in the same
/// style as the screen's other section titles.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingMd,
        LayoutConstants.spacingXs,
      ),
      child: Row(
        children: [
          Icon(
            icon,
            color: Theme.of(context).colorScheme.primary,
            size: 22,
          ),
          const SizedBox(width: LayoutConstants.spacingSm),
          Text(
            label,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

/// The installed CloudStream plugins, for the Installed tab, grouped the
/// same way as the repositories — "SkyStream" (from the owner's TojiX repo)
/// and "CloudStream" (from the official repository and any other). Nothing
/// when there are none.
class CloudStreamInstalledSection extends ConsumerWidget {
  const CloudStreamInstalledSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    if (state.installed.isEmpty) return const SizedBox.shrink();
    final skyStream = [
      for (final plugin in state.installed)
        if (CloudStreamRepository.isSkyStreamRepository(
          plugin.info.repositoryUrl,
        ))
          plugin,
    ];
    final cloudStream = [
      for (final plugin in state.installed)
        if (!CloudStreamRepository.isSkyStreamRepository(
          plugin.info.repositoryUrl,
        ))
          plugin,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (skyStream.isNotEmpty)
          _InstalledGroupCard(
            icon: Icons.extension_rounded,
            label: 'SkyStream',
            plugins: skyStream,
          ),
        if (cloudStream.isNotEmpty)
          _InstalledGroupCard(
            icon: Icons.cloud_rounded,
            label: 'CloudStream',
            plugins: cloudStream,
          ),
      ],
    );
  }
}

class _InstalledGroupCard extends StatelessWidget {
  const _InstalledGroupCard({
    required this.icon,
    required this.label,
    required this.plugins,
  });

  final IconData icon;
  final String label;
  final List<CsInstalledPlugin> plugins;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingMd,
              vertical: LayoutConstants.spacingSm + 4,
            ),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary, size: 22),
                const SizedBox(width: LayoutConstants.spacingSm),
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final plugin in plugins)
            _CloudStreamPluginTile(info: plugin.info, installed: plugin),
        ],
      ),
    );
  }
}

class _CloudStreamRepositoryCard extends ConsumerWidget {
  const _CloudStreamRepositoryCard({required this.repo});

  final CsRepository repo;

  Future<void> _confirmRemove(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    // The option's label, not the manifest's own name.
    final displayName = CloudStreamRepository.displayNameFor(repo);
    final remove = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.removeRepoConfirm(displayName)),
        content: Text(l10n.removeRepoWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.cloudStreamRemove),
          ),
        ],
      ),
    );
    if (remove != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(cloudStreamRepositoryProvider.notifier)
          .removeRepository(repo.url);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.cloudStreamCouldNotRemove(
              displayName,
              CloudStreamRepository.errorMessage(error),
            ),
          ),
        ),
      );
    }
  }

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    // The option's label, not the manifest's own name.
    final displayName = CloudStreamRepository.displayNameFor(repo);
    final failure = await ref
        .read(cloudStreamRepositoryProvider.notifier)
        .refreshRepository(repo.url);
    if (failure != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.cloudStreamCouldNotCheckRepository(displayName, failure),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(cloudStreamRepositoryProvider);
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final installedCount = repo.plugins
        .where((p) => state.installedFor(p) != null)
        .length;
    final l10n = AppLocalizations.of(context)!;

    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: LayoutConstants.spacingMd,
        vertical: LayoutConstants.spacingXs,
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        key: PageStorageKey('cs3_repo_${repo.url}'),
        shape: const Border(),
        collapsedShape: const Border(),
        initiallyExpanded: repo.plugins.length <= 12,
        title: Text(
          // The option's label, not the manifest's own name: "SkyStream"
          // for the owner's repo, "CloudStream" for the official one.
          CloudStreamRepository.displayNameFor(repo),
          style: theme.textTheme.titleMedium?.copyWith(
            color: cs.primary,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          [
            l10n.cloudStreamRepositorySummary(
              repo.plugins.length,
              installedCount,
            ),
            if (repo.error != null) l10n.cloudStreamLastCheckFailed,
          ].join(' · '),
          style: theme.textTheme.bodySmall?.copyWith(
            color: repo.error != null ? cs.error : cs.onSurfaceVariant,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LayoutConstants.spacingSm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    repo.url,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: l10n.cloudStreamRefreshRepository,
                  icon: const Icon(Icons.refresh_rounded),
                  onPressed: () => unawaited(_refresh(context, ref)),
                ),
                IconButton(
                  tooltip: l10n.removeRepository,
                  icon: Icon(Icons.delete_outline, color: cs.error),
                  onPressed: () => unawaited(_confirmRemove(context, ref)),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          for (final plugin in repo.plugins)
            _CloudStreamPluginTile(
              info: plugin,
              installed: state.installedFor(plugin),
            ),
        ],
      ),
    );
  }
}

class _CloudStreamPluginTile extends ConsumerWidget {
  const _CloudStreamPluginTile({required this.info, required this.installed});

  final CsPluginInfo info;
  final CsInstalledPlugin? installed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final installed = this.installed;
    final key = CloudStreamRepository.keyOf(info);
    // Only what this tile shows: a repository's tiles otherwise all rebuild on every change.
    final busy = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.busy.contains(key)),
    );
    final applying = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.applying.contains(key)),
    );
    final newer = installed == null
        ? null
        : ref.watch(
            cloudStreamRepositoryProvider.select(
              (s) => s.updateFor(installed),
            ),
          );
    // Switched off, CloudStream loads no extension: what would load one waits for the switch (Uninstall doesn't).
    final on = ref.watch(
      cloudStreamRepositoryProvider.select((s) => s.enabled),
    );
    final notifier = ref.read(cloudStreamRepositoryProvider.notifier);
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final status = switch (info.status) {
      0 => l10n.cloudStreamStatusDown,
      2 => l10n.cloudStreamStatusSlow,
      3 => l10n.cloudStreamStatusBeta,
      _ => null,
    };

    final details = [
      if (info.tvTypes.isNotEmpty) info.tvTypes.take(3).join(' / '),
      if (info.language != null && info.language!.isNotEmpty)
        info.language!.toUpperCase(),
      if (info.authors.isNotEmpty) info.authors.take(2).join(', '),
      if (info.fileSize case final size? when size > 0) _size(size),
    ].join(' · ');

    final providers = installed?.providers.map((p) => p.name).join(', ');

    return ListTile(
      key: ValueKey('cs3_plugin_${CloudStreamRepository.keyOf(info)}'),
      leading: _PluginIcon(url: info.iconUrl, name: info.name),
      title: Row(
        children: [
          Flexible(
            child: Text(
              info.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          _Chip(
            text: newer != null
                ? 'v${installed?.info.version} → v${newer.version}'
                : 'v${installed?.info.version ?? info.version}',
            color: newer != null ? cs.tertiary : cs.outline,
          ),
          if (status != null) ...[
            const SizedBox(width: 4),
            _Chip(text: status, color: info.isDown ? cs.error : cs.outline),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (details.isNotEmpty)
            Text(details, maxLines: 1, overflow: TextOverflow.ellipsis),
          if (providers != null && providers.isNotEmpty)
            Text(
              l10n.cloudStreamProviders(providers),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (installed?.loadError != null)
            Text(
              l10n.cloudStreamCouldNotLoad(installed!.loadError!),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: cs.error),
            ),
          if (applying)
            Text(
              l10n.cloudStreamSettingsApplying,
              style: TextStyle(color: cs.primary),
            ),
        ],
      ),
      trailing: busy
          ? const SizedBox(
              width: 24,
              height: 24,
              child: AppLoadingIndicator(
                constraints: BoxConstraints(maxWidth: 24, maxHeight: 24),
              ),
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (installed == null)
                  IconButton(
                    key: ValueKey('cs3_install_${info.internalName}'),
                    tooltip: l10n.install,
                    icon: const Icon(Icons.download_rounded),
                    onPressed: on
                        ? () => unawaited(
                            _install(
                              context,
                              () => notifier.install(info),
                              info,
                              l10n.cloudStreamInstalled,
                            ),
                          )
                        : null,
                  )
                else ...[
                  if (newer != null)
                    IconButton(
                      tooltip: l10n.cloudStreamUpdate,
                      icon: Icon(
                        Icons.system_update_alt_rounded,
                        color: cs.tertiary,
                      ),
                      onPressed: on
                          ? () => unawaited(
                              _install(
                                context,
                                () => notifier.install(newer),
                                info,
                                l10n.cloudStreamUpdated,
                              ),
                            )
                          : null,
                    ),
                  IconButton(
                    key: ValueKey('cs3_uninstall_${info.internalName}'),
                    tooltip: l10n.cloudStreamUninstall,
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    onPressed: () => unawaited(
                      _run(
                        context,
                        () => notifier.uninstall(installed),
                        l10n.cloudStreamUninstalled(info.name),
                      ),
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  static Future<void> _run(
    BuildContext context,
    Future<Object?> Function() action,
    String done,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      await action();
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)),
          ),
        ),
      );
    }
  }

  /// Installs or updates ([done] says which); one that downloads but does not load says so.
  static Future<void> _install(
    BuildContext context,
    Future<CsInstalledPlugin> Function() action,
    CsPluginInfo info,
    String Function(String name) done,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context)!;
    try {
      final installed = await action();
      final error = installed.loadError;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error == null
                ? done(info.name)
                : l10n.cloudStreamInstalledNotLoading(info.name, error),
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l10n.cloudStreamFailed(CloudStreamRepository.errorMessage(error)),
          ),
        ),
      );
    }
  }

  static String _size(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} KB';
}

class _PluginIcon extends StatelessWidget {
  const _PluginIcon({required this.url, required this.name});

  final String? url;
  final String name;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fallback = Container(
      width: 40,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(color: cs.primary, fontWeight: FontWeight.bold),
      ),
    );
    final icon = url;
    if (icon == null || icon.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        icon,
        width: 40,
        height: 40,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
        loadingBuilder: (context, child, progress) =>
            progress == null ? child : fallback,
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: color,
        fontSize: 10,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
