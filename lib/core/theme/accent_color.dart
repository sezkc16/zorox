import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';

part 'accent_color.g.dart';

/// The 10 accent presets (ZoroX v7, 2.9.6 — White + Black added v20+12,
/// M M 2026-11-14: White for the dark theme, Black for the light theme).
/// Gold is the default — the app's Gold & Black identity (see
/// ZOROX_DESIGN_SPEC.md). The shades are picked to stay readable on the
/// obsidian background (#0A0A0B): saturated enough to read as an accent,
/// light enough that the active nav icon, section underlines and buttons
/// stay legible. Only the accent changes; the background stays black and
/// the layout is untouched.
///
/// White (0xFFFFFFFF) and Black (0xFF000000) are the monochrome pair:
/// White reads clean on the dark theme, Black on the light theme. The
/// theme layer guards the two invisible combinations (see
/// [AppTheme.createLightTheme]): a near-white accent gets dark `onPrimary`
/// text in the light theme, and the picker gives the Black swatch a light
/// ring so it stays visible on the dark Settings background.
enum ZoroxAccent {
  gold('Gold', Color(0xFFD4AF37)),
  red('Red', Color(0xFFE53935)),
  blue('Blue', Color(0xFF42A5F5)),
  green('Green', Color(0xFF66BB6A)),
  purple('Purple', Color(0xFFAB47BC)),
  orange('Orange', Color(0xFFFF9800)),
  pink('Pink', Color(0xFFEC407A)),
  cyan('Cyan', Color(0xFF26C6DA)),
  white('White', Color(0xFFFFFFFF)),
  black('Black', Color(0xFF000000));

  const ZoroxAccent(this.label, this.color);

  /// Display name shown under the swatches in Settings.
  final String label;

  /// The accent color itself.
  final Color color;

  /// The saved preset name, or Gold for anything this release never wrote.
  /// Storage outlives downgrades and hand-editing, so an unrecognised value
  /// is reachable; it says no more than an absent one does, and lands in
  /// the same place.
  static ZoroxAccent fromName(String? name) {
    if (name == null) return ZoroxAccent.gold;
    for (final accent in ZoroxAccent.values) {
      if (accent.name == name) return accent;
    }
    return ZoroxAccent.gold;
  }
}

/// The user's chosen accent color, persisted across restarts.
///
/// Everything that wears the accent reads it through
/// `Theme.of(context).colorScheme.primary`, which is seeded from this
/// value in `AppTheme`, so changing it rebuilds the whole app at once —
/// no restart, no re-login.
@Riverpod(keepAlive: true)
class AccentColor extends _$AccentColor {
  late SettingsRepository _repository;

  @override
  ZoroxAccent build() {
    _repository = ref.watch(settingsRepositoryProvider);
    return ZoroxAccent.fromName(_repository.getAccentColor());
  }

  /// Whether the user has ever picked an accent in Settings (any preset,
  /// Gold included). Until then the saved value is absent — and on Android
  /// the OS dynamic colour is used instead, so Material You keeps working.
  /// Picking Gold explicitly IS a choice, not the default: Gold is both
  /// the fallback and a preset, so the accent state alone cannot tell
  /// "never chose" from "chose Gold" — only the stored value can.
  bool get hasExplicitChoice => _repository.getAccentColor() != null;

  Future<void> setAccent(ZoroxAccent accent) async {
    if (state == accent) return;
    state = accent;
    await _repository.saveAccentColor(accent.name);
  }
}
