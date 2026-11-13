/// How long an episode is, for the Episodes drawer.
///
/// The history stores the duration in MILLISECONDS
/// (`storage_service.dart` saves `'duration': durationMillis`), so the
/// value read back here is milliseconds — never seconds. An earlier
/// version of the mpv screen read it as seconds, which made every
/// duration 1000x too long: a 3-hour film read as 10,860,000 seconds,
/// and `goldenFormatTime` clamps at 99 days, so the drawer showed
/// "2376:00:00" for Avengers Endgame.
///
/// A stored value is only believed when it is a plausible episode
/// length (over zero, at most 24 hours): a corrupt or legacy row must
/// never print as a giant number. Otherwise the plugin's runtime in
/// minutes is used, and when neither exists there is no duration to
/// show — the drawer then omits the line rather than guessing.
library;

/// The longest duration a stored history value may claim before it is
/// treated as corrupt and ignored: no episode or film is 24 hours.
const int kMaxPlausibleEpisodeDurationMs = 24 * 60 * 60 * 1000;

/// The episode's length from its stored history duration
/// ([durationMs], milliseconds) or, failing that, the plugin's
/// [runtimeMinutes]. Null when neither gives a plausible length.
Duration? episodeDurationFromHistoryMs(
  int durationMs, {
  int? runtimeMinutes,
}) {
  if (durationMs > 0 &&
      durationMs <= kMaxPlausibleEpisodeDurationMs) {
    return Duration(milliseconds: durationMs);
  }
  if (runtimeMinutes != null && runtimeMinutes > 0) {
    return Duration(minutes: runtimeMinutes);
  }
  return null;
}
