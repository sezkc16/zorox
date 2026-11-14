import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Persistent startup breadcrumb log, added for the +18/+19 loading freeze
/// (v20+20 diagnostic).
///
/// Writes SYNCHRONOUSLY to Documents/zorox_boot.log — readable in
/// Files → ZoroX (UIFileSharingEnabled is on) — so the last line shows
/// exactly where a stuck launch stopped, even if the app is force-closed
/// afterwards. Every call is try/catch-guarded: logging must never break
/// startup. Lines also go to stderr (and debugPrint, which is a no-op in
/// release) so they show up in any attached console too.
class BootTrace {
  static File? _file;
  static int _sequence = 0;
  static final Set<String> _onceKeys = <String>{};
  static Timer? _heartbeat;

  /// Resolves the Documents directory and opens the log. Never throws.
  static Future<void> init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _file = File('${dir.path}/zorox_boot.log');
      mark('=== NEW LAUNCH ${DateTime.now().toIso8601String()} ===');
      mark('BOOT TRACE INIT: ${dir.path}/zorox_boot.log');
    } catch (e) {
      // No file: stderr-only mode. Startup must go on.
      try {
        stderr.writeln('[BootTrace] init failed: $e');
      } catch (_) {}
    }
  }

  /// One breadcrumb line, written synchronously (flush: true) so it lands
  /// on disk even if the isolate blocks right after this call. Never throws.
  static void mark(String message) {
    try {
      final line =
          '${++_sequence} ${DateTime.now().toIso8601String()} $message';
      try {
        stderr.writeln('[BootTrace] $line');
      } catch (_) {}
      try {
        debugPrint('[BootTrace] $line');
      } catch (_) {}
      final file = _file;
      if (file != null) {
        file.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
      }
    } catch (_) {
      // Logging must never break startup.
    }
  }

  /// [mark] once per [key] for the life of the process (build() markers).
  static void markOnce(String key, String message) {
    if (_onceKeys.add(key)) {
      mark(message);
    }
  }

  /// A 1s heartbeat. If the lines stop while the screen is frozen, the Dart
  /// main isolate is blocked; if they keep coming, the isolate is alive and
  /// the stall is in rendering / first-frame construction.
  static void startHeartbeat() {
    try {
      _heartbeat?.cancel();
      _heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
        mark('HEARTBEAT');
      });
    } catch (_) {}
  }
}
