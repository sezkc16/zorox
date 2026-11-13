import 'package:flutter/material.dart';

/// The app-wide SnackBar: a floating rounded pill that sits ABOVE the
/// bottom navigation instead of a full-width black bar at the very bottom
/// covering the liquid-glass nav pill.
///
/// Every `SnackBar` in the app is built with this helper (not the raw
/// constructor): the margin lifts the pill clear of the 68pt nav pill +
/// 8pt inset + system bottom inset, the shape matches the M3 toast cards,
/// and the theme (`AppTheme.snackBarThemeFor`) carries the same floating
/// behaviour + shape as a safety net for any SnackBar built elsewhere.
///
/// [duration] defaults to Flutter's 4s; plugin install/uninstall messages
/// pass 1500ms so they show for 1–2s and dismiss on their own.
SnackBar appSnackBar({
  required Widget content,
  SnackBarAction? action,
  Duration duration = const Duration(seconds: 4),
}) {
  return SnackBar(
    content: content,
    action: action,
    duration: duration,
    behavior: SnackBarBehavior.floating,
    margin: const EdgeInsets.only(left: 16, right: 16, bottom: 128),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    elevation: 6,
  );
}
