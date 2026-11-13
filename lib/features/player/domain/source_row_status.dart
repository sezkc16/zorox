/// What one row of a source list says about its source: two facts, shown
/// side by side and never merged.
///
/// [SourceReachability] is what the reachability check found before anything
/// was opened. [SourcePlayState] is what happened when the source was played.
/// Merging them - playing winning - made the row being opened stop saying it
/// was reachable, so it read as less proven than the rows beneath it that had
/// passed the same check.
///
/// The startup screen and the in-player Sources panel both render rows from
/// these, so the same source can never read two ways in two places.
library;

import '../../../core/domain/entity/multimedia_item.dart';
import 'stream_resolver.dart';

enum SourceReachability {
  /// The reachability check is out for it.
  checking,

  /// The check got an answer from it.
  reachable,

  /// The check got an answer, from a server that ignores byte ranges: it
  /// plays, but only from its start.
  unseekable,

  /// The check got no answer from it.
  unreachable,

  /// The check got an answer, and it was a web page rather than anything to
  /// play.
  notVideo,

  /// Nobody has asked: the check only looks at the top few sources, and
  /// cannot look at a torrent or a local file at all. Not "unknown", which
  /// would read as a verdict.
  notChecked,
}

enum SourcePlayState {
  /// Not opened this resolve.
  untried,

  /// Handed to the engine, no picture yet.
  opening,

  /// On screen now.
  playing,

  /// Opened this resolve and would not play, or stopped.
  failed,
}

/// The provider [stream] names, or null when it names none.
///
/// `Unknown` is [StreamResult]'s placeholder for a source whose plugin named
/// no provider - every JS plugin's stream is one - and not a provider's name.
/// Shown, it put "Unknown ·" in front of every startup row and an "Unknown"
/// line under every Sources row.
String? sourceProvider(StreamResult stream) {
  final provider = stream.providerName.trim();
  if (provider.isEmpty || provider == 'Unknown') return null;
  return provider;
}

/// The name a source row gives [stream]: the plugin's own label for it, led
/// by the provider when one was named.
String sourceRowLabel(StreamResult stream) {
  final provider = sourceProvider(stream);
  return provider == null ? stream.source : '$provider · ${stream.source}';
}

/// The server a source is on ("FSLv2", "FSL", "PixelDrain", "10G"), for the
/// source list: the viewer picks by server, and the label truncates the
/// server away — it sits at the end of a long plugin label ("HubCloud Other
/// Mommy (1080p WEB-DL H26… [FSLv2 Server]"), past where the row's single
/// line ellipsises. The most specific server wins, in this order:
///
/// 1. A bracketed "[… Server …]" in the label ("[FSLv2 Server]" → "FSLv2").
/// 2. A known server name anywhere in the label ("1080p [6.7GB] HubCloud"
///    → "HubCloud"; a "PixelDrain" buried mid-label still reads) — except
///    the HubCloud-chain names, which the plugin stamps on every link it
///    resolves through that chain (see 3).
/// 3. The resolved stream URL's host: the plugin names every HubCloud-chain
///    link "HubCloud …" even when the file itself is served by PixelDrain
///    (pixeldrain.dev/api/file/…) or HubCloud's own R2 storage
///    (*.r2.cloudflarestorage.com). The URL is the truth about where the
///    file comes from; the label is only the chain it came through.
/// 4. A HubCloud-chain name in the label ("HubCloud", "HubCdn").
/// 5. The label's leading host word ("G-Direct") — unless it reads as a
///    quality, a size or a generic word ("Download", "1080p"), which is no
///    server at all.
///
/// Null when nothing names a server.
String? sourceServer(StreamResult stream) {
  final source = stream.source.trim();
  if (source.isNotEmpty) {
    final bracketed = RegExp(
      r'\[([^\]]*server[^\]]*)\]',
      caseSensitive: false,
    ).allMatches(source).map((m) => m.group(1)!.trim()).toList();
    if (bracketed.isNotEmpty) {
      final name = bracketed.last
          .replaceAll(RegExp(r'server', caseSensitive: false), '')
          .replaceAll(RegExp(r'[:·•|/-]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (name.isNotEmpty) return name;
    }
    for (final entry in _specificServers.entries) {
      if (entry.value.hasMatch(source)) return entry.key;
    }
    final fromUrl = _serverFromUrl(stream.url);
    if (fromUrl != null) return fromUrl;
    for (final entry in _chainServers.entries) {
      if (entry.value.hasMatch(source)) return entry.key;
    }
    final first = source.split(RegExp(r'\s+')).first;
    if (first.isNotEmpty &&
        !_qualityInLabel.hasMatch(first) &&
        _sizeInLabel.firstMatch(first) == null &&
        !_genericFirstWord.hasMatch(first)) {
      return first;
    }
  } else {
    final fromUrl = _serverFromUrl(stream.url);
    if (fromUrl != null) return fromUrl;
  }
  return null;
}

/// Server names a plugin label can carry, in the order they are recognised:
/// the longer name first, so "FSLv2" is never read as "FSL", and a name
/// buried mid-label ("1080p [6.7GB] HubCloud") still reads. The
/// HubCloud-chain names live apart ([_chainServers]): the plugin stamps
/// them on every link it resolves through that chain, so they only count
/// once the stream URL has had its say.
final Map<String, RegExp> _specificServers = <String, RegExp>{
  'FSLv2': RegExp(r'\bfslv2\b', caseSensitive: false),
  'FSL': RegExp(r'\bfsl\b', caseSensitive: false),
  'PixelDrain': RegExp(r'pixeldrain', caseSensitive: false),
  '10G': RegExp(r'\b10g\b', caseSensitive: false),
  'G-Direct': RegExp(r'g-direct', caseSensitive: false),
  'Videasy': RegExp(r'videasy', caseSensitive: false),
  'FilePress': RegExp(r'filepress', caseSensitive: false),
  'GDFlix': RegExp(r'gdflix', caseSensitive: false),
  'MultiLinks': RegExp(r'multilinks', caseSensitive: false),
  'Indishare': RegExp(r'indishare', caseSensitive: false),
};

/// The HubCloud chain's own names: the plugin writes one of these on every
/// link it resolves through the chain, whatever host the file itself ends
/// up on — so they are checked only after the stream URL.
final Map<String, RegExp> _chainServers = <String, RegExp>{
  'HubCloud': RegExp(r'hubcloud', caseSensitive: false),
  'HubCdn': RegExp(r'hubcdn', caseSensitive: false),
  'HubDrive': RegExp(r'hubdrive', caseSensitive: false),
};

/// The server the resolved stream URL is actually served from. The plugin
/// names every HubCloud-chain link "HubCloud …" even when the file itself
/// comes from PixelDrain (pixeldrain.dev/api/file/…) or HubCloud's own R2
/// storage (*.r2.cloudflarestorage.com) — the label cannot say that, but
/// the URL can. Null for a URL with no host (a magnet, a local file).
String? _serverFromUrl(String url) {
  final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
  if (host.isEmpty) return null;
  if (host.contains('pixeldrain')) return 'PixelDrain';
  if (host.contains('r2.cloudflarestorage.com')) return 'HubCloud';
  if (host.contains('hubcdn')) return 'HubCdn';
  if (host.contains('hubdrive')) return 'HubDrive';
  if (host.contains('hubcloud')) return 'HubCloud';
  if (host.contains('fslv2')) return 'FSLv2';
  if (host.contains('fsl')) return 'FSL';
  if (host.contains('gdflix')) return 'GDFlix';
  if (host.contains('filepress')) return 'FilePress';
  if (host.contains('multilinks')) return 'MultiLinks';
  if (host.contains('indishare')) return 'Indishare';
  return null;
}

/// Words a label can lead with that are no server: a download verb, a file
/// or episode word. The leading-word fallback must not turn one of these
/// into a server chip ("Download (Ep 08) 1080p - 1.34GB" is no server).
final RegExp _genericFirstWord = RegExp(
  r'^(download|watch|episode|season|file|video|movie|pack)$',
  caseSensitive: false,
);

/// The quality a source row shows as a chip ("4K", "1080p", "720p"): the
/// plugin's parsed height first, else the label's own "1080p" / "4K" —
/// the label truncates it away just like the server, and the viewer picks
/// by quality too. Null when neither names one — no chip, never a guess.
/// Adaptive (0) offers several heights, so it names none either.
String? sourceQualityLabel(StreamResult stream) {
  final height = stream.quality;
  if (height != null && height > 0) {
    return height >= 2160 ? '4K' : '${height}p';
  }
  final match = _qualityInLabel.firstMatch(stream.source);
  if (match == null) return null;
  final found = match
      .group(1)!
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '');
  return switch (found) {
    '2160p' || '4k' || 'uhd' => '4K',
    '1440p' || '2k' => '1440p',
    _ => found, // 1080p, 720p, 480p, 360p
  };
}

/// A quality written in a source label: "1080p" in a filename, "4K" on
/// its own. The word boundary keeps "4KHDHub" (a provider name) from
/// reading as a 4K stream.
final RegExp _qualityInLabel = RegExp(
  r'\b(2160\s*p|4k|uhd|1440\s*p|2k|1080\s*p|720\s*p|480\s*p|360\s*p)\b',
  caseSensitive: false,
);

/// The file size a source row shows as a chip ("16.74 GB", "850 MB"): the
/// plugin's own label carries it ("HubCloud 2160p DV HDR [16.74 GB]"),
/// and the viewer picks by size too. Null when the label names no size —
/// no chip, never a guess. No network call: a HEAD on the stream URL
/// would be slow and unreliable for HLS.
String? sourceSizeLabel(StreamResult stream) {
  final match = _sizeInLabel.firstMatch(stream.source);
  if (match == null) return null;
  var number = match.group(1)!;
  if (number.contains(',')) {
    // A comma is a decimal mark ("1,5 GB") — unless three digits follow,
    // when it is a thousands separator ("1,024 MB").
    final parts = number.split(',');
    number = parts.length == 2 && parts[1].length == 3
        ? parts.join()
        : number.replaceAll(',', '.');
  }
  return '$number ${match.group(2)!.toUpperCase()}';
}

/// A file size written in a source label: "16.74 GB" in brackets, "850MB"
/// bare, "3.45GB" after a dash. The word boundary keeps "10G" (a server
/// name) and "kbps" (a bitrate) from reading as a size.
final RegExp _sizeInLabel = RegExp(
  r'\b(\d+(?:[.,]\d+)?)\s*(GB|MB|TB|KB)\b',
  caseSensitive: false,
);

/// What is known about reaching [stream]: the [probe] outcome the check
/// reported, unless [hasPlayed] - it has shown a picture this resolve, which
/// is stronger evidence than any request about it.
SourceReachability sourceReachabilityOf(
  StreamResult stream,
  ProbeOutcome? probe, {
  bool hasPlayed = false,
}) {
  // A source on screen was reached, whatever the probe said - or could not
  // say. Otherwise a playing torrent read "not checked", and a slow host the
  // probe gave up on read "unreachable" under its own picture. Reaching it
  // proves nothing about seeking, though, which is what a viewer wonders
  // about while it plays.
  if (hasPlayed) {
    return probe == ProbeOutcome.unseekable
        ? SourceReachability.unseekable
        : SourceReachability.reachable;
  }
  // The probe passes these without asking, so its pass says nothing.
  if (isUncheckableSource(stream)) return SourceReachability.notChecked;
  return switch (probe) {
    null => SourceReachability.notChecked,
    ProbeOutcome.trying => SourceReachability.checking,
    ProbeOutcome.healthy => SourceReachability.reachable,
    ProbeOutcome.unseekable => SourceReachability.unseekable,
    ProbeOutcome.unhealthy => SourceReachability.unreachable,
    ProbeOutcome.notVideo => SourceReachability.notVideo,
  };
}

/// What playing a source has come to.
///
/// [isCurrent] names the source the player is on, and [hasPicture] whether
/// that attempt has produced a frame. Pass false for [isCurrent] when nothing
/// is being played, such as once every source has failed. [failed] is this
/// session's record of the source not playing.
SourcePlayState sourcePlayStateOf({
  required bool isCurrent,
  required bool hasPicture,
  required bool failed,
}) {
  // Ahead of [failed]: a source picked again is being tried again.
  if (isCurrent) {
    return hasPicture ? SourcePlayState.playing : SourcePlayState.opening;
  }
  return failed ? SourcePlayState.failed : SourcePlayState.untried;
}
