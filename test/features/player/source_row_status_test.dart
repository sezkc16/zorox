import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/domain/source_row_status.dart';
import 'package:skystream/features/player/domain/stream_resolver.dart';

/// Two facts about each source row, kept apart on purpose: what the
/// reachability check found, and what happened when the source was played.
///
/// They used to be merged into one status, with playing winning - so the row
/// being opened stopped saying it was reachable, and read as less proven than
/// the rows below it that had passed the same check.
void main() {
  const http = StreamResult(url: 'https://cdn.example/film.m3u8', source: 'A');

  group('reachability', () {
    SourceReachability reach(
      ProbeOutcome? probe, {
      StreamResult stream = http,
    }) => sourceReachabilityOf(stream, probe);

    test('a source nobody has checked is not checked', () {
      expect(reach(null), SourceReachability.notChecked);
    });

    test('is what the check found', () {
      expect(reach(ProbeOutcome.trying), SourceReachability.checking);
      expect(reach(ProbeOutcome.healthy), SourceReachability.reachable);
      expect(reach(ProbeOutcome.unhealthy), SourceReachability.unreachable);
    });

    // Both answered, so neither is "reachable" and nothing more: one plays only
    // from its start, and the other is a web page rather than a video.
    test('says when a source cannot be sought in, or is not a video', () {
      expect(reach(ProbeOutcome.unseekable), SourceReachability.unseekable);
      expect(reach(ProbeOutcome.notVideo), SourceReachability.notVideo);
    });

    // The check answers these without looking, so "reachable" would be a claim
    // nobody made: a magnet with no seeders passes it.
    test(
      'torrents and local files are not checked even when the check passed',
      () {
        for (final url in <String>[
          'magnet:?xt=urn:btih:abc',
          'https://tracker.example/pack.torrent',
          '/downloads/film.mkv',
        ]) {
          expect(
            reach(
              ProbeOutcome.healthy,
              stream: StreamResult(url: url, source: 'Torrent'),
            ),
            SourceReachability.notChecked,
            reason: url,
          );
        }
      },
    );
  });

  // Playing a source is stronger evidence than any request about it: a row
  // that has shown a picture reads reachable, whatever the probe said - or
  // could not say, for a torrent.
  group('reachability once a source has played', () {
    test('is reachable, even where the probe got no answer', () {
      expect(
        sourceReachabilityOf(http, ProbeOutcome.unhealthy, hasPlayed: true),
        SourceReachability.reachable,
      );
    });

    test('is reachable for a torrent the probe cannot look at', () {
      expect(
        sourceReachabilityOf(
          const StreamResult(url: 'magnet:?xt=urn:btih:abc', source: 'T'),
          null,
          hasPlayed: true,
        ),
        SourceReachability.reachable,
      );
    });

    // Playing it proves it answers, not that its server will seek - which is
    // exactly what a viewer wonders about while it plays.
    test('still cannot be sought in when its server ignores ranges', () {
      expect(
        sourceReachabilityOf(http, ProbeOutcome.unseekable, hasPlayed: true),
        SourceReachability.unseekable,
      );
    });
  });

  // "Unknown" is StreamResult's placeholder for a source whose plugin named no
  // provider - which every JS plugin's stream is. Printed, it put "Unknown ·"
  // in front of every row.
  group('the provider a row names', () {
    test('is none for the placeholder or a blank', () {
      expect(sourceProvider(const StreamResult(url: 'u', source: 's')), isNull);
      expect(
        sourceProvider(
          const StreamResult(url: 'u', source: 's', providerName: '  '),
        ),
        isNull,
      );
    });

    test('is the provider when one was named', () {
      expect(
        sourceProvider(
          const StreamResult(url: 'u', source: 's', providerName: 'Torrentio'),
        ),
        'Torrentio',
      );
    });
  });

  group('the row label', () {
    test('is the source alone when no provider was named', () {
      expect(
        sourceRowLabel(const StreamResult(url: 'u', source: 'HubCloud 1080p')),
        'HubCloud 1080p',
      );
    });

    test('leads with the provider when there is one', () {
      expect(
        sourceRowLabel(
          const StreamResult(
            url: 'u',
            source: '1080p',
            providerName: 'Torrentio',
          ),
        ),
        'Torrentio · 1080p',
      );
    });
  });

  // The size the plugin's own label carries ("[16.74 GB]", "850MB",
  // "1080p - 3.45GB"): shown as a chip, so the viewer can pick by size.
  // A label with no size shows no chip — never a guess.
  group('the file size a row names', () {
    String? size(String source) =>
        sourceSizeLabel(StreamResult(url: 'u', source: source));

    test('reads a bracketed size', () {
      expect(size('HubCloud 2160p DV HDR [16.74 GB]'), '16.74 GB');
      expect(size('HQ 1080p (SOURCE) [32.8GB]'), '32.8 GB');
    });

    test('reads a bare size, and a size after a dash', () {
      expect(size('1080p [330MB]'), '330 MB');
      expect(size('Download 1080p - 3.45GB'), '3.45 GB');
    });

    test('reads TB and normalises a comma decimal', () {
      expect(size('Season Pack [1.2 TB]'), '1.2 TB');
      expect(size('1080p [1,5 GB]'), '1.5 GB');
    });

    test('is none when the label names no size', () {
      expect(size('HubCloud 1080p'), isNull);
      expect(size('G-Direct 720p'), isNull);
    });

    test('is not a server name or a bitrate', () {
      expect(size('[Server: 10G] 1080p'), isNull);
      expect(size('8000 kbps 1080p'), isNull);
    });
  });

  // The server a row names: the most specific one wins. A bracketed
  // "[… Server …]" first, then a known server anywhere in the label, then
  // the resolved stream URL's host — the plugin stamps "HubCloud …" on
  // every link it resolves through that chain, even when the file itself
  // is served by PixelDrain. A leading "Download" or "1080p" is no server.
  group('the server a row names', () {
    const r2 = 'https://abc123.r2.cloudflarestorage.com/hub/file.mkv';
    const pd = 'https://pixeldrain.dev/api/file/abc123';

    String? server({required String source, String url = r2}) =>
        sourceServer(StreamResult(url: url, source: source));

    test('reads a bracketed server', () {
      expect(server(source: '[FSLv2 Server] 1080p [3.6GB]'), 'FSLv2');
      expect(server(source: '[FSL Server] 1080p [3.6GB]'), 'FSL');
      expect(server(source: '[Server: 10G] 1080p [3.6GB]'), '10G');
    });

    test('reads a server buried mid-label', () {
      expect(server(source: '1080p [6.7GB] HubCloud'), 'HubCloud');
      expect(server(source: 'PixelDrain 1080p [2.1GB]'), 'PixelDrain');
      expect(server(source: 'G-Direct 1080p [6.6GB]'), 'G-Direct');
      expect(server(source: 'Watch Online (Videasy)'), 'Videasy');
    });

    test('tells FSLv2 apart from FSL', () {
      expect(server(source: 'FSLv2 1080p [3.6GB]'), 'FSLv2');
      expect(server(source: 'FSL 1080p [3.6GB]'), 'FSL');
    });

    test('the stream URL beats the HubCloud chain name in the label', () {
      expect(
        server(source: 'HubCloud 1080p [4.6GB]', url: pd),
        'PixelDrain',
        reason: 'the file is served by PixelDrain, whatever the chain',
      );
      expect(
        server(source: 'HubCloud 2160p DV HDR [16.74 GB]', url: r2),
        'HubCloud',
      );
    });

    test('a leading download word or quality is no server', () {
      expect(
        server(source: 'Download (Ep 08) 1080p - 1.34GB', url: r2),
        'HubCloud',
        reason: 'the URL still says where the file is',
      );
      expect(
        server(source: '1080p', url: 'https://cdn.example/film.m3u8'),
        isNull,
      );
    });

    test('a hostless URL contributes no server', () {
      expect(
        server(source: 'Torrent', url: 'magnet:?xt=urn:btih:abc'),
        'Torrent',
        reason: 'the leading word is all there is — unchanged from before',
      );
      expect(
        server(source: '1080p', url: 'magnet:?xt=urn:btih:abc'),
        isNull,
        reason: 'a quality is no server, and a magnet has no host',
      );
    });
  });

  group('play state', () {
    SourcePlayState play({
      bool isCurrent = false,
      bool hasPicture = false,
      bool failed = false,
    }) => sourcePlayStateOf(
      isCurrent: isCurrent,
      hasPicture: hasPicture,
      failed: failed,
    );

    test('a source nobody has opened is untried', () {
      expect(play(), SourcePlayState.untried);
    });

    test('the source being opened is opening until it has a picture', () {
      expect(play(isCurrent: true), SourcePlayState.opening);
      expect(play(isCurrent: true, hasPicture: true), SourcePlayState.playing);
    });

    test('a source that would not play has failed', () {
      expect(play(failed: true), SourcePlayState.failed);
    });

    // A viewer re-picking a source that failed earlier is trying it again.
    test('a failed source picked again is opening, not failed', () {
      expect(play(isCurrent: true, failed: true), SourcePlayState.opening);
    });
  });

  // The stall recovery gives 4K a bigger buffer and a longer start
  // cushion than 1080p, so the two have to be told apart — and told
  // apart only by the stream's own quality, never by its name.
  group('high-bitrate stream', () {
    StreamResult stream({int? quality, String source = 'A'}) =>
        StreamResult(
          url: 'https://cdn.example/film.m3u8',
          source: source,
          quality: quality,
        );

    test('a 4K stream is high-bitrate', () {
      expect(isHighBitrateStream(stream(quality: 2160)), isTrue);
      expect(isHighBitrateStream(stream(quality: 4320)), isTrue);
    });

    test('1080p and below are not', () {
      expect(isHighBitrateStream(stream(quality: 1080)), isFalse);
      expect(isHighBitrateStream(stream(quality: 720)), isFalse);
      expect(isHighBitrateStream(stream(quality: 480)), isFalse);
    });

    test('the label says so when the quality is missing', () {
      expect(
        isHighBitrateStream(stream(source: 'HubCloud 4K [16.74 GB]')),
        isTrue,
      );
      expect(
        isHighBitrateStream(stream(source: '2160p HEVC')),
        isTrue,
        reason: 'a 2160p label is 4K by another name',
      );
      expect(
        isHighBitrateStream(stream(source: 'UHD BluRay')),
        isTrue,
      );
    });

    test('a 1080p label is not 4K, even on a 4K-named provider', () {
      expect(
        isHighBitrateStream(stream(source: '4KHDHub 1080p')),
        isFalse,
        reason: 'the provider name is not a quality',
      );
    });

    test('a stream that reports no quality is not assumed to be 4K', () {
      expect(
        isHighBitrateStream(stream(source: 'HubCloud 1080p')),
        isFalse,
      );
    });
  });
}
