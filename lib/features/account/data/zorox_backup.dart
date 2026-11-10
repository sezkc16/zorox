import '../../../core/domain/entity/multimedia_item.dart';

/// One ZoroX backup: everything an account (or a backup file) carries
/// across an uninstall/reinstall.
///
/// Format version 1. The `format` marker is what the Worker checks before
/// it stores an upload, and what import checks before it restores a file,
/// so a random JSON file can never be mistaken for a backup.
///
/// History entries are the raw maps from the history box, each with its box
/// key (`{'key': ..., 'entry': {...}}`) — including the per-episode `EP_`
/// entries — so a restore keeps the original timestamps and per-episode
/// positions instead of stamping everything with "now".
///
/// Plugins are backed up as identities, not files: a repository URL plus a
/// plugin's package name (SkyStream) or internal name (CloudStream). On
/// restore the app re-adds the repository and re-installs the plugin from
/// it, so the restored plugins are the current versions, not stale files.
class ZoroxBackup {
  static const String format = 'zorox-backup';
  static const int currentVersion = 1;

  const ZoroxBackup({
    this.version = currentVersion,
    required this.exportedAt,
    this.history = const [],
    this.library = const [],
    this.skystreamRepos = const [],
    this.skystreamPlugins = const [],
    this.cloudstreamRepos = const [],
    this.cloudstreamPlugins = const [],
  });

  final int version;

  /// Unix milliseconds when the backup was made.
  final int exportedAt;

  /// Raw history entries: `{'key': String, 'entry': Map}`.
  final List<Map<String, dynamic>> history;

  /// Library items as [MultimediaItem.toJson] maps.
  final List<Map<String, dynamic>> library;

  /// SkyStream repository URLs (SharedPreferences `extension_repo_urls`).
  final List<String> skystreamRepos;

  /// Installed SkyStream plugins: `{'packageName', 'repositoryUrl'}`.
  final List<Map<String, String>> skystreamPlugins;

  /// CloudStream repository URLs.
  final List<String> cloudstreamRepos;

  /// Installed CloudStream plugins:
  /// `{'internalName', 'name', 'url', 'repositoryUrl'}`.
  final List<Map<String, String>> cloudstreamPlugins;

  Map<String, dynamic> toJson() => {
    'format': format,
    'version': version,
    'exportedAt': exportedAt,
    'history': history,
    'library': library,
    'skystreamRepos': skystreamRepos,
    'skystreamPlugins': skystreamPlugins,
    'cloudstreamRepos': cloudstreamRepos,
    'cloudstreamPlugins': cloudstreamPlugins,
  };

  factory ZoroxBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != format) {
      throw const FormatException('That file is not a ZoroX backup.');
    }
    final version = (json['version'] as num?)?.toInt() ?? 0;
    if (version != currentVersion) {
      throw FormatException(
        'Backup version $version is not supported (this app reads version $currentVersion).',
      );
    }
    return ZoroxBackup(
      version: version,
      exportedAt: (json['exportedAt'] as num?)?.toInt() ?? 0,
      history: [
        for (final e in (json['history'] as List?) ?? const [])
          if (e is Map) Map<String, dynamic>.from(e),
      ],
      library: [
        for (final e in (json['library'] as List?) ?? const [])
          if (e is Map) Map<String, dynamic>.from(e),
      ],
      skystreamRepos: [
        for (final e in (json['skystreamRepos'] as List?) ?? const [])
          if (e is String) e,
      ],
      skystreamPlugins: [
        for (final e in (json['skystreamPlugins'] as List?) ?? const [])
          if (e is Map)
            {for (final kv in e.entries) '${kv.key}': '${kv.value}'},
      ],
      cloudstreamRepos: [
        for (final e in (json['cloudstreamRepos'] as List?) ?? const [])
          if (e is String) e,
      ],
      cloudstreamPlugins: [
        for (final e in (json['cloudstreamPlugins'] as List?) ?? const [])
          if (e is Map)
            {for (final kv in e.entries) '${kv.key}': '${kv.value}'},
      ],
    );
  }
}

/// What a restore did, for the confirmation toast: counts of what came
/// back, and one line per thing that could not be restored (a plugin its
/// repository no longer lists, a repository that would not load).
class ZoroxRestoreReport {
  const ZoroxRestoreReport({
    this.historyRestored = 0,
    this.historySkipped = 0,
    this.libraryRestored = 0,
    this.skystreamReposRestored = 0,
    this.skystreamPluginsRestored = 0,
    this.cloudstreamReposRestored = 0,
    this.cloudstreamPluginsRestored = 0,
    this.errors = const [],
  });

  final int historyRestored;

  /// Entries the local copy already had newer than the backup.
  final int historySkipped;
  final int libraryRestored;
  final int skystreamReposRestored;
  final int skystreamPluginsRestored;
  final int cloudstreamReposRestored;
  final int cloudstreamPluginsRestored;
  final List<String> errors;

  /// True when nothing at all came back (an empty or foreign backup).
  bool get isEmpty =>
      historyRestored == 0 &&
      libraryRestored == 0 &&
      skystreamPluginsRestored == 0 &&
      cloudstreamPluginsRestored == 0;

  String get summary {
    final parts = <String>[
      if (historyRestored > 0)
        '$historyRestored history item${historyRestored == 1 ? '' : 's'}',
      if (libraryRestored > 0)
        '$libraryRestored bookmark${libraryRestored == 1 ? '' : 's'}',
      if (skystreamPluginsRestored > 0 || cloudstreamPluginsRestored > 0)
        '${skystreamPluginsRestored + cloudstreamPluginsRestored} plugin${skystreamPluginsRestored + cloudstreamPluginsRestored == 1 ? '' : 's'}',
    ];
    if (parts.isEmpty) return 'Nothing new to restore.';
    return 'Restored ${parts.join(', ')}.';
  }
}

/// A [MultimediaItem] rebuilt from a backup's library map, or null when the
/// map does not describe a usable item (no URL to key it by).
MultimediaItem? libraryItemFromBackup(Map<String, dynamic> map) {
  try {
    final item = MultimediaItem.fromJson(map);
    if (item.url.isEmpty) return null;
    return item;
  } catch (_) {
    return null;
  }
}
