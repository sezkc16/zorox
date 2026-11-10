import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/notification_service.dart';
import '../../settings/presentation/widgets/settings_widgets.dart';
import '../data/zorox_account_notifier.dart';
import '../data/zorox_sync_client.dart';

/// The "ZoroX Account" group on the Accounts settings screen.
///
/// Gold & Black comes from the theme itself (primary is Zoro gold), so
/// nothing here sets its own colours. All strings are plain English, like
/// the rest of the app since v4.
class ZoroxAccountSection extends ConsumerWidget {
  const ZoroxAccountSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(zoroxAccountProvider);
    return SettingsGroup(
      title: 'ZoroX Account',
      children: [
        SettingsTile(
          icon: Icons.account_circle_rounded,
          title: 'ZoroX Account',
          subtitle: account.loggedIn
              ? 'Logged in as ${account.email}'
              : 'Back up watch history, plugins & library',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const ZoroxAccountDialog(),
          ),
        ),
        if (account.loggedIn)
          SettingsTile(
            icon: Icons.cloud_upload_rounded,
            title: 'Sync now',
            subtitle: account.cloudConfigured
                ? (account.lastSyncedAt == null
                      ? 'Never synced'
                      : 'Last synced ${_formatLastSynced(account.lastSyncedAt!)}')
                : 'Cloud sync not set up yet',
            onTap: () => _syncNow(context, ref),
          ),
        SettingsTile(
          icon: Icons.dns_rounded,
          title: 'Sync server',
          subtitle: account.cloudConfigured
              ? account.workerUrl
              : 'Not set up — cloud sync off',
          onTap: () => showDialog<void>(
            context: context,
            builder: (_) => const ZoroxWorkerUrlDialog(),
          ),
        ),
        SettingsTile(
          icon: Icons.file_download_rounded,
          title: 'Export backup',
          subtitle: 'Save watch history, plugins & library to a file',
          onTap: () => _exportBackup(context, ref),
        ),
        SettingsTile(
          icon: Icons.file_upload_rounded,
          title: 'Import backup',
          subtitle: 'Restore from a backup file',
          isLast: true,
          onTap: () => _importBackup(context, ref),
        ),
      ],
    );
  }

  Future<void> _syncNow(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(zoroxAccountProvider.notifier);
    final ok = await notifier.uploadBackup();
    if (!context.mounted) return;
    final notifications = ref.read(notificationServiceProvider);
    if (ok) {
      notifications.showSuccess(
        'Backed up to the cloud.',
        title: 'ZoroX Account',
        icon: Icons.cloud_done_rounded,
      );
    } else {
      notifications.showError(
        ref.read(zoroxAccountProvider).error ??
            'Could not sync. Try again.',
        title: 'ZoroX Account',
        icon: Icons.cloud_off_rounded,
      );
    }
  }

  Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref
          .read(zoroxAccountProvider.notifier)
          .exportBackupFile();
      if (!context.mounted) return;
      if (result == null) return; // User cancelled the save dialog.
      ref
          .read(notificationServiceProvider)
          .showSuccess(
            result.openedShareSheet
                ? 'Backup ready — save it from the share sheet to keep it.'
                : 'Backup exported.',
            title: 'ZoroX Account',
            icon: Icons.file_download_rounded,
          );
    } catch (e) {
      if (!context.mounted) return;
      ref
          .read(notificationServiceProvider)
          .showError(
            'Could not export the backup: $e',
            title: 'ZoroX Account',
            icon: Icons.error_outline_rounded,
          );
    }
  }

  Future<void> _importBackup(BuildContext context, WidgetRef ref) async {
    try {
      final report = await ref
          .read(zoroxAccountProvider.notifier)
          .importBackupFile();
      if (!context.mounted) return;
      if (report == null) return; // User cancelled the picker.
      final notifications = ref.read(notificationServiceProvider);
      notifications.showSuccess(
        report.summary,
        title: 'ZoroX Account',
        icon: Icons.restore_rounded,
      );
      if (report.errors.isNotEmpty) {
        notifications.showError(
          report.errors.first,
          title: 'Some items were not restored',
          icon: Icons.warning_amber_rounded,
        );
      }
    } on ZoroxSyncException catch (e) {
      if (!context.mounted) return;
      ref
          .read(notificationServiceProvider)
          .showError(
            e.message,
            title: 'ZoroX Account',
            icon: Icons.error_outline_rounded,
          );
    } on PlatformException catch (e) {
      // file_picker's `multiple_request`: a pick was started while another
      // pick was still open. Never show the raw exception — the user just
      // needs to tap Import again (the guard is already reset by then).
      if (!context.mounted) return;
      ref
          .read(notificationServiceProvider)
          .showError(
            e.code == 'multiple_request'
                ? 'The file picker was already open — please tap Import again.'
                : 'Could not import the backup: ${e.message ?? e.code}',
            title: 'ZoroX Account',
            icon: Icons.error_outline_rounded,
          );
    } catch (e) {
      if (!context.mounted) return;
      ref
          .read(notificationServiceProvider)
          .showError(
            'Could not import the backup: $e',
            title: 'ZoroX Account',
            icon: Icons.error_outline_rounded,
          );
    }
  }
}

/// "Last synced" in the user's words — no date library needed for this.
String _formatLastSynced(DateTime at) {
  final ago = DateTime.now().difference(at);
  if (ago.inSeconds < 60) return 'just now';
  if (ago.inMinutes < 60) {
    final m = ago.inMinutes;
    return '$m min ago';
  }
  if (ago.inHours < 24) {
    final h = ago.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${at.day} ${months[at.month - 1]} ${at.year}';
}

/// The login / register / logout dialog.
///
/// Logged out: email + password, Log in and Create account. Logged in: the
/// account, last sync, Sync now and Log out. The password field never keeps
/// its text after the dialog closes, and the password is never stored — only
/// the session token, in the keychain/keystore.
class ZoroxAccountDialog extends ConsumerStatefulWidget {
  const ZoroxAccountDialog({super.key});

  @override
  ConsumerState<ZoroxAccountDialog> createState() =>
      _ZoroxAccountDialogState();
}

class _ZoroxAccountDialogState extends ConsumerState<ZoroxAccountDialog> {
  late final TextEditingController _emailController = TextEditingController();
  late final TextEditingController _passwordController =
      TextEditingController();
  var _passwordVisible = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(zoroxAccountProvider);
    final primary = Theme.of(context).colorScheme.primary;
    return AlertDialog(
      title: const Text('ZoroX Account'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (account.loggedIn) ...[
              Row(
                children: [
                  Icon(Icons.account_circle_rounded, color: primary, size: 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          account.email ?? '',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          account.lastSyncedAt == null
                              ? 'Never synced'
                              : 'Last synced ${_formatLastSynced(account.lastSyncedAt!)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Your watch history, installed plugins and library are '
                'backed up to your sync server, and restored when you log '
                'in on a new install.',
              ),
              if (!account.cloudConfigured) ...[
                const SizedBox(height: 12),
                const Text(
                  'Cloud sync is not set up yet — set the sync server URL '
                  'to turn it on. Export/Import below always works without it.',
                ),
              ],
            ] else ...[
              const Text(
                'Backs up your watch history, installed plugins and '
                'library, and restores them after an uninstall or on '
                'another device.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passwordController,
                obscureText: !_passwordVisible,
                enableSuggestions: false,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Password',
                  helperText: 'At least 8 characters.',
                  prefixIcon: const Icon(Icons.lock_rounded),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _passwordVisible
                          ? Icons.visibility_off_rounded
                          : Icons.visibility_rounded,
                    ),
                    onPressed: () => setState(
                      () => _passwordVisible = !_passwordVisible,
                    ),
                  ),
                ),
                onSubmitted: (_) => _login(),
              ),
              if (!account.cloudConfigured) ...[
                const SizedBox(height: 12),
                const Text(
                  'Cloud sync is not set up yet — set the sync server URL '
                  'first (Sync server, on the previous screen), or use '
                  'Export/Import, which needs no server.',
                ),
              ],
            ],
            if (account.error != null) ...[
              const SizedBox(height: 12),
              Text(
                account.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: account.busy ? null : () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (account.loggedIn) ...[
          TextButton(
            onPressed: account.busy ? null : _logout,
            child: const Text('Log out'),
          ),
          FilledButton(
            onPressed: account.busy ? null : _syncNow,
            child: account.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Sync now'),
          ),
        ] else ...[
          TextButton(
            onPressed: account.busy ? null : _register,
            child: const Text('Create account'),
          ),
          FilledButton(
            onPressed: account.busy ? null : _login,
            child: account.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Log in'),
          ),
        ],
      ],
    );
  }

  Future<void> _login() async {
    final ok = await ref
        .read(zoroxAccountProvider.notifier)
        .login(
          email: _emailController.text,
          password: _passwordController.text,
        );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _register() async {
    final ok = await ref
        .read(zoroxAccountProvider.notifier)
        .register(
          email: _emailController.text,
          password: _passwordController.text,
        );
    if (ok && mounted) Navigator.pop(context);
  }

  Future<void> _logout() async {
    await ref.read(zoroxAccountProvider.notifier).logout();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _syncNow() async {
    final ok = await ref.read(zoroxAccountProvider.notifier).uploadBackup();
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      ref
          .read(notificationServiceProvider)
          .showSuccess(
            'Backed up to the cloud.',
            title: 'ZoroX Account',
            icon: Icons.cloud_done_rounded,
          );
    }
  }
}

/// The sync server URL editor: paste the deployed Worker URL
/// (`https://zorox-sync.<subdomain>.workers.dev`). Empty clears it.
class ZoroxWorkerUrlDialog extends ConsumerStatefulWidget {
  const ZoroxWorkerUrlDialog({super.key});

  @override
  ConsumerState<ZoroxWorkerUrlDialog> createState() =>
      _ZoroxWorkerUrlDialogState();
}

class _ZoroxWorkerUrlDialogState extends ConsumerState<ZoroxWorkerUrlDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: ref.read(zoroxAccountProvider).workerUrl,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sync server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Paste the URL of your deployed zorox-sync Worker. '
            'It must start with https://. Leave it empty to turn cloud '
            'sync off — Export/Import still works.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Worker URL',
              hintText: 'https://zorox-sync.<subdomain>.workers.dev',
              prefixIcon: Icon(Icons.cloud_rounded),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            final ok = await ref
                .read(zoroxAccountProvider.notifier)
                .setWorkerUrl(_controller.text);
            if (ok && context.mounted) Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
