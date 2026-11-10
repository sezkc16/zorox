import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/cloudstream/cloudstream_models.dart';
import '../../../core/cloudstream/cloudstream_repository.dart';
import '../../../core/extensions/models/extension_plugin.dart';
import '../../../core/logger/app_logger.dart';
import '../../../core/storage/library_repository.dart';
import '../../../core/storage/secure_token_storage.dart';
import '../../../core/storage/storage_service.dart';
import '../../extensions/providers/extensions_controller.dart';
import '../../library/presentation/history_provider.dart';
import 'zorox_backup.dart';
import 'zorox_sync_client.dart';

/// The ZoroX account: login + cloud sync, and Export/Import backup.
///
/// Plain Riverpod ([NotifierProvider]) — no codegen, so no `build_runner`.
///
/// What is stored where:
///   - Session token + email: platform keychain/keystore
///     ([SecureTokenStorage], never Hive, never plain text).
///   - The password is NEVER stored anywhere on the device.
///   - Sync server URL + last-synced time: the settings box
///     ([StorageService.setString]).
///   - The backup itself: history box + library box + the two plugin
///     systems' own stores; this feature only reads them and restores into
///     them through their public APIs.
class ZoroxAccountState {
  const ZoroxAccountState({
    this.email,
    this.loggedIn = false,
    this.busy = false,
    this.error,
    this.lastSyncedAt,
    this.cloudConfigured = false,
    this.workerUrl = '',
  });

  final String? email;
  final bool loggedIn;
  final bool busy;

  /// The last failure, in the user's words; cleared on the next attempt.
  final String? error;
  final DateTime? lastSyncedAt;

  /// True when a sync server URL is set (cloud sync is possible).
  final bool cloudConfigured;
  final String workerUrl;

  ZoroxAccountState copyWith({
    String? email,
    bool? loggedIn,
    bool? busy,
    String? error,
    bool clearError = false,
    DateTime? lastSyncedAt,
    bool? cloudConfigured,
    String? workerUrl,
  }) => ZoroxAccountState(
    email: email ?? this.email,
    loggedIn: loggedIn ?? this.loggedIn,
    busy: busy ?? this.busy,
    error: clearError ? null : (error ?? this.error),
    lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    cloudConfigured: cloudConfigured ?? this.cloudConfigured,
    workerUrl: workerUrl ?? this.workerUrl,
  );
}

final zoroxAccountProvider =
    NotifierProvider<ZoroxAccountNotifier, ZoroxAccountState>(
      ZoroxAccountNotifier.new,
    );

class ZoroxAccountNotifier extends Notifier<ZoroxAccountState> {
  static const String _kTokenKey = 'zorox_account_token';
  static const String _kEmailKey = 'zorox_account_email';
  static const String _kWorkerUrlKey = 'zorox_sync_worker_url';
  static const String _kLastSyncedKey = 'zorox_last_synced_at';

  /// How long after a change the auto-upload waits, so ten history saves in
  /// a row become one upload instead of ten.
  static const Duration _autoSyncDebounce = Duration(seconds: 10);

  final _client = ZoroxSyncClient();
  Timer? _autoSyncTimer;
  bool _restored = false;

  @override
  ZoroxAccountState build() {
    ref.onDispose(() => _autoSyncTimer?.cancel());
    if (!_restored) {
      _restored = true;
      unawaited(_restoreSession());
    }
    // Auto-upload (debounced) when anything the backup covers changes while
    // logged in: a watch-history save, a SkyStream plugin install/remove, or
    // a CloudStream repo/plugin change. requestAutoSync() no-ops when logged
    // out or unconfigured, and debounces 10s, so frequent saves collapse
    // into one upload. The listeners are set up once here — the provider is
    // keep-alive once built — so they fire for the whole session, including
    // changes made from the player, which never opens the Account screen.
    ref.listen(watchHistoryProvider, (_, _) => requestAutoSync());
    ref.listen(extensionsControllerProvider, (_, _) => requestAutoSync());
    ref.listen(cloudStreamRepositoryProvider, (_, _) => requestAutoSync());
    return const ZoroxAccountState();
  }

  // --- session ---------------------------------------------------------------

  Future<void> _restoreSession() async {
    try {
      final tokens = ref.read(secureTokenStorageProvider);
      final token = await tokens.read(_kTokenKey);
      final email = await tokens.read(_kEmailKey);
      final storage = ref.read(storageServiceProvider);
      final workerUrl = _workerUrl(storage);
      final lastSynced = _lastSynced(storage);
      if (!ref.mounted) return;
      state = state.copyWith(
        email: email,
        loggedIn: token != null && token.isNotEmpty && email != null,
        workerUrl: workerUrl,
        cloudConfigured: workerUrl.isNotEmpty,
        lastSyncedAt: lastSynced,
      );
    } catch (e) {
      talker.warning('[ZoroX Account] restoring the session failed: $e');
    }
  }

  String _workerUrl(StorageService storage) {
    final stored = storage.getString(_kWorkerUrlKey)?.trim() ?? '';
    if (stored.isNotEmpty) return stored.replaceAll(RegExp(r'/+$'), '');
    return kZoroxSyncWorkerUrl.replaceAll(RegExp(r'/+$'), '');
  }

  DateTime? _lastSynced(StorageService storage) {
    final raw = storage.getString(_kLastSyncedKey);
    final millis = raw == null ? null : int.tryParse(raw);
    if (millis == null || millis <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<String> _requireWorkerUrl() async {
    final url = _workerUrl(ref.read(storageServiceProvider));
    ZoroxSyncClient.checkBaseUrl(url);
    return url;
  }

  Future<String?> _token() =>
      ref.read(secureTokenStorageProvider).read(_kTokenKey);

  Future<void> _markSynced() async {
    final now = DateTime.now();
    await ref
        .read(storageServiceProvider)
        .setString(_kLastSyncedKey, '${now.millisecondsSinceEpoch}');
    if (ref.mounted) state = state.copyWith(lastSyncedAt: now);
  }

  // --- auth ------------------------------------------------------------------

  static final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

  static String? validateCredentials(String email, String password) {
    if (!_emailPattern.hasMatch(email.trim())) {
      return 'Enter a valid email address.';
    }
    if (password.length < 8) {
      return 'Password must be at least 8 characters.';
    }
    return null;
  }

  /// Creates the account, then uploads the local backup so the account
  /// starts with everything already on this device.
  Future<bool> register({
    required String email,
    required String password,
  }) async {
    final problem = validateCredentials(email, password);
    if (problem != null) {
      state = state.copyWith(error: problem);
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _client.register(
        baseUrl,
        email.trim().toLowerCase(),
        password,
      );
      await _saveSession(email.trim().toLowerCase(), token);
      // A fresh account has no cloud backup to download; upload local.
      await uploadBackup();
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(busy: false, error: '$e');
      }
      return false;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  /// Logs in, downloads the cloud backup and restores it (newest wins per
  /// item), then uploads the merged result so the server holds the union.
  Future<bool> login({
    required String email,
    required String password,
  }) async {
    final problem = validateCredentials(email, password);
    if (problem != null) {
      state = state.copyWith(error: problem);
      return false;
    }
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _client.login(
        baseUrl,
        email.trim().toLowerCase(),
        password,
      );
      await _saveSession(email.trim().toLowerCase(), token);
      await downloadAndRestore();
      await uploadBackup();
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(busy: false, error: e.message);
      return false;
    } catch (e) {
      if (ref.mounted) {
        state = state.copyWith(busy: false, error: '$e');
      }
      return false;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  Future<void> _saveSession(String email, String token) async {
    final tokens = ref.read(secureTokenStorageProvider);
    await tokens.write(_kTokenKey, token);
    await tokens.write(_kEmailKey, email);
    if (ref.mounted) {
      state = state.copyWith(email: email, loggedIn: true);
    }
  }

  /// Logs out on the server (best effort) and deletes the local session.
  /// Backups and local data stay on the device.
  Future<void> logout() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final token = await _token();
      final baseUrl = _workerUrl(ref.read(storageServiceProvider));
      if (token != null && baseUrl.isNotEmpty) {
        await _client.logout(baseUrl, token);
      }
    } finally {
      final tokens = ref.read(secureTokenStorageProvider);
      await tokens.delete(_kTokenKey);
      await tokens.delete(_kEmailKey);
      if (ref.mounted) {
        state = state.copyWith(
          email: null,
          loggedIn: false,
          busy: false,
          lastSyncedAt: null,
        );
      }
    }
  }

  // --- sync server URL --------------------------------------------------------

  /// Saves the Worker URL (empty clears it). Only `https://` is accepted.
  Future<bool> setWorkerUrl(String rawUrl) async {
    final url = rawUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (url.isNotEmpty && !url.startsWith('https://')) {
      state = state.copyWith(
        error: 'The sync server URL must start with https://',
      );
      return false;
    }
    await ref.read(storageServiceProvider).setString(
      _kWorkerUrlKey,
      url.isEmpty ? null : url,
    );
    if (ref.mounted) {
      state = state.copyWith(
        workerUrl: url,
        cloudConfigured: url.isNotEmpty,
        clearError: true,
      );
    }
    return true;
  }

  // --- cloud sync ---------------------------------------------------------------

  /// Uploads the current local backup. Returns false (with [state.error])
  /// when not logged in, not configured, or the server refuses.
  Future<bool> uploadBackup() async {
    if (!state.loggedIn) return false;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const ZoroxSyncException('Session expired. Log in again.');
      }
      final backup = await collectBackup();
      await _client.upload(baseUrl, token, backup.toJson());
      await _markSynced();
      return true;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(error: e.message);
      return false;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: '$e');
      return false;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  /// Downloads the cloud backup and restores it. Returns the restore
  /// report, or null when the account has never synced (nothing to restore).
  Future<ZoroxRestoreReport?> downloadAndRestore() async {
    if (!state.loggedIn) return null;
    state = state.copyWith(busy: true, clearError: true);
    try {
      final baseUrl = await _requireWorkerUrl();
      final token = await _token();
      if (token == null || token.isEmpty) {
        throw const ZoroxSyncException('Session expired. Log in again.');
      }
      final remote = await _client.download(baseUrl, token);
      if (remote == null) return null;
      final report = await restoreBackup(ZoroxBackup.fromJson(remote));
      await _markSynced();
      return report;
    } on ZoroxSyncException catch (e) {
      if (ref.mounted) state = state.copyWith(error: e.message);
      return null;
    } catch (e) {
      if (ref.mounted) state = state.copyWith(error: '$e');
      return null;
    } finally {
      if (ref.mounted && state.busy) state = state.copyWith(busy: false);
    }
  }

  /// The debounced auto-upload: call whenever history, plugins or library
  /// change while logged in. Ten saves in a row become one upload, ten
  /// seconds after the last one. A failure is logged, not shown — a
  /// background sync must never pop an error over what the user is doing;
  /// the next manual Sync now reports it.
  void requestAutoSync() {
    if (!state.loggedIn || !state.cloudConfigured) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(_autoSyncDebounce, () async {
      if (!ref.mounted || !state.loggedIn) return;
      try {
        await uploadBackup();
      } catch (e) {
        talker.warning('[ZoroX Account] auto-upload failed: $e');
      }
    });
  }

  // --- backup: collect ---------------------------------------------------------

  /// Reads everything the backup covers. Plugin collection never fails the
  /// backup: a repository that will not load is skipped and the rest still
  /// goes in (the restore step reports what is missing).
  Future<ZoroxBackup> collectBackup() async {
    final storage = ref.read(storageServiceProvider);
    final history = storage.getAllHistoryEntries();
    final library = ref
        .read(libraryRepositoryProvider)
        .getLibraryItems()
        .map((item) => item.toJson())
        .toList();

    var skystreamRepos = <String>[];
    var skystreamPlugins = <Map<String, String>>[];
    try {
      final extensions = ref.read(extensionsControllerProvider.notifier);
      await extensions.ensureInitialized();
      final extensionsState = ref.read(extensionsControllerProvider);
      skystreamRepos = [
        for (final repo in extensionsState.repositories) repo.url,
      ];
      skystreamPlugins = [
        for (final plugin in extensionsState.installedPlugins)
          {
            'packageName': plugin.packageName,
            'repositoryUrl': plugin.repositoryUrl ?? '',
          },
      ];
    } catch (e) {
      talker.warning('[ZoroX Account] SkyStream plugins not backed up: $e');
    }

    var cloudstreamRepos = <String>[];
    var cloudstreamPlugins = <Map<String, String>>[];
    try {
      final cloudstream = ref.read(cloudStreamRepositoryProvider.notifier);
      await cloudstream.load();
      final cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      cloudstreamRepos = [
        for (final repo in cloudstreamState.repositories) repo.url,
      ];
      cloudstreamPlugins = [
        for (final plugin in cloudstreamState.installed)
          {
            'internalName': plugin.info.internalName,
            'name': plugin.info.name,
            'url': plugin.info.url,
            'repositoryUrl': plugin.info.repositoryUrl,
          },
      ];
    } catch (e) {
      talker.warning('[ZoroX Account] CloudStream plugins not backed up: $e');
    }

    return ZoroxBackup(
      exportedAt: DateTime.now().millisecondsSinceEpoch,
      history: history,
      library: library,
      skystreamRepos: skystreamRepos,
      skystreamPlugins: skystreamPlugins,
      cloudstreamRepos: cloudstreamRepos,
      cloudstreamPlugins: cloudstreamPlugins,
    );
  }

  // --- backup: restore ---------------------------------------------------------

  /// Merges [backup] into this device: newest timestamp wins per history
  /// entry, bookmarks are added when missing, repositories are re-added and
  /// their missing plugins re-installed. Never throws for one bad entry;
  /// failures are collected in the report.
  Future<ZoroxRestoreReport> restoreBackup(ZoroxBackup backup) async {
    final errors = <String>[];
    var historyRestored = 0;
    var historySkipped = 0;
    var libraryRestored = 0;
    var skystreamReposRestored = 0;
    var skystreamPluginsRestored = 0;
    var cloudstreamReposRestored = 0;
    var cloudstreamPluginsRestored = 0;

    // History: newest timestamp wins, per box key.
    final storage = ref.read(storageServiceProvider);
    final local = <String, int>{
      for (final raw in storage.getAllHistoryEntries())
        if (raw['key'] is String)
          raw['key'] as String:
              ((raw['entry'] as Map?)?['timestamp'] as int?) ?? 0,
    };
    final toPut = <Map<String, dynamic>>[];
    for (final raw in backup.history) {
      final key = raw['key'];
      final entry = raw['entry'];
      if (key is! String || entry is! Map) continue;
      final timestamp = (entry['timestamp'] as int?) ?? 0;
      if (!local.containsKey(key) || timestamp > (local[key] ?? 0)) {
        toPut.add(raw);
        historyRestored++;
      } else {
        historySkipped++;
      }
    }
    if (toPut.isNotEmpty) {
      await storage.restoreHistoryEntries(toPut);
    }

    // Library: add what is missing.
    final library = ref.read(libraryRepositoryProvider);
    for (final raw in backup.library) {
      final item = libraryItemFromBackup(raw);
      if (item == null) continue;
      try {
        final wasThere = library.isInLibrary(item.url);
        await library.addToLibrary(item);
        if (!wasThere) libraryRestored++;
      } catch (e) {
        errors.add('Could not restore bookmark "${item.title}": $e');
      }
    }

    // SkyStream repositories, then their plugins.
    try {
      final extensions = ref.read(extensionsControllerProvider.notifier);
      await extensions.ensureInitialized();
      var extensionsState = ref.read(extensionsControllerProvider);
      for (final url in backup.skystreamRepos) {
        if (extensionsState.repositories.any((repo) => repo.url == url)) {
          continue;
        }
        try {
          await extensions.addRepository(url);
          skystreamReposRestored++;
        } catch (e) {
          errors.add('Could not add repository $url: $e');
        }
        extensionsState = ref.read(extensionsControllerProvider);
      }
      for (final saved in backup.skystreamPlugins) {
        final packageName = saved['packageName'];
        if (packageName == null || packageName.isEmpty) continue;
        if (extensionsState.installedPlugins.any(
          (plugin) => plugin.packageName == packageName,
        )) {
          continue;
        }
        final found = _findSkyStreamPlugin(extensionsState, packageName);
        if (found == null) {
          errors.add(
            'Plugin $packageName is no longer listed by its repository, so it was not restored.',
          );
          continue;
        }
        try {
          await extensions.installPlugin(found);
          skystreamPluginsRestored++;
        } catch (e) {
          errors.add('Could not install ${found.name}: $e');
        }
        extensionsState = ref.read(extensionsControllerProvider);
      }
    } catch (e) {
      errors.add('SkyStream plugins were not restored: $e');
    }

    // CloudStream repositories, then their plugins.
    try {
      final cloudstream = ref.read(cloudStreamRepositoryProvider.notifier);
      await cloudstream.load();
      var cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      for (final url in backup.cloudstreamRepos) {
        if (cloudstreamState.repositories.any((repo) => repo.url == url)) {
          continue;
        }
        try {
          await cloudstream.addRepository(url);
          cloudstreamReposRestored++;
        } catch (e) {
          errors.add('Could not add repository $url: $e');
        }
        cloudstreamState = ref.read(cloudStreamRepositoryProvider);
      }
      if (!cloudstreamState.enabled) {
        if (backup.cloudstreamPlugins.isNotEmpty) {
          errors.add(
            'CloudStream is switched off, so its ${backup.cloudstreamPlugins.length} plugin(s) were not restored. Switch it on in Settings and import again.',
          );
        }
      } else {
        for (final saved in backup.cloudstreamPlugins) {
          final internalName = saved['internalName'];
          final repositoryUrl = saved['repositoryUrl'];
          if (internalName == null || repositoryUrl == null) continue;
          if (cloudstreamState.installed.any(
            (plugin) =>
                plugin.info.internalName == internalName &&
                plugin.info.repositoryUrl == repositoryUrl,
          )) {
            continue;
          }
          final found = _findCloudStreamPlugin(
            cloudstreamState,
            internalName,
            repositoryUrl,
          );
          if (found == null) {
            errors.add(
              'Plugin ${saved['name'] ?? internalName} is no longer listed by its repository, so it was not restored.',
            );
            continue;
          }
          try {
            await cloudstream.install(found);
            cloudstreamPluginsRestored++;
          } catch (e) {
            errors.add('Could not install ${found.name}: $e');
          }
          cloudstreamState = ref.read(cloudStreamRepositoryProvider);
        }
      }
    } catch (e) {
      errors.add('CloudStream plugins were not restored: $e');
    }

    return ZoroxRestoreReport(
      historyRestored: historyRestored,
      historySkipped: historySkipped,
      libraryRestored: libraryRestored,
      skystreamReposRestored: skystreamReposRestored,
      skystreamPluginsRestored: skystreamPluginsRestored,
      cloudstreamReposRestored: cloudstreamReposRestored,
      cloudstreamPluginsRestored: cloudstreamPluginsRestored,
      errors: errors,
    );
  }

  static ExtensionPlugin? _findSkyStreamPlugin(
    ExtensionsState extensionsState,
    String packageName,
  ) {
    for (final plugins in extensionsState.availablePlugins.values) {
      for (final plugin in plugins) {
        if (plugin.packageName == packageName) return plugin;
      }
    }
    return null;
  }

  static CsPluginInfo? _findCloudStreamPlugin(
    CloudStreamState cloudstreamState,
    String internalName,
    String repositoryUrl,
  ) {
    // The repository it came from first; any repository listing it second
    // (a repository can move, and the plugin is the same file).
    for (final repo in cloudstreamState.repositories) {
      if (repo.url != repositoryUrl) continue;
      for (final plugin in repo.plugins) {
        if (plugin.internalName == internalName) return plugin;
      }
    }
    for (final repo in cloudstreamState.repositories) {
      for (final plugin in repo.plugins) {
        if (plugin.internalName == internalName) return plugin;
      }
    }
    return null;
  }

  // --- export / import (no backend) --------------------------------------------

  /// Writes the backup to a file the user can keep. Returns the path and
  /// whether the share sheet was opened, or null when the user cancels. On
  /// iOS there is no save dialog, so the file goes to a temp file and the
  /// share sheet opens for "Save to Files".
  Future<({String path, bool openedShareSheet})?> exportBackupFile() async {
    final backup = await collectBackup();
    final bytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(backup.toJson()),
    );
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final fileName = 'zorox-backup-$stamp.json';
    try {
      final uri = await FilePicker.saveFile(
        dialogTitle: 'Save ZoroX backup',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );
      if (uri != null) {
        return (path: uri.toFilePath(), openedShareSheet: false);
      }
    } catch (e) {
      talker.warning('[ZoroX Account] save dialog failed: $e');
    }
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$fileName');
    await file.writeAsBytes(bytes, flush: true);
    await OpenFile.open(file.path);
    return (path: file.path, openedShareSheet: true);
  }

  /// Picks a backup file and restores it. Returns the restore report, or
  /// null when the user cancels the picker. Throws [ZoroxSyncException]
  /// when the file is not a ZoroX backup.
  Future<ZoroxRestoreReport?> importBackupFile() async {
    final picked = await FilePicker.pickFile(
      dialogTitle: 'Import ZoroX backup',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (picked == null) return null;
    // On iOS the picked file is a security-scoped URL, not a plain path:
    // XFile reads it either way.
    final bytes = picked.path != null
        ? await File(picked.path!).readAsBytes()
        : await picked.xFile.readAsBytes();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) {
      throw const ZoroxSyncException('That file is not a ZoroX backup.');
    }
    final backup = ZoroxBackup.fromJson(
      Map<String, dynamic>.from(decoded),
    );
    return restoreBackup(backup);
  }
}
