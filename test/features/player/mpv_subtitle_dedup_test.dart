import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:skystream/core/domain/entity/multimedia_item.dart';
import 'package:skystream/features/player/presentation/mpv/mpv_vlc_controller.dart';

/// The subtitle drawer listed the same track many times: mpv reports one
/// subtitle content once per HLS rendition/variant, so "English - [auto]"
/// showed six times over, and a source can ship the same side-car file
/// twice. The drawer cannot tell the copies apart (the row shows only
/// title + language), so the adapter keeps the first occurrence of each
/// visible identity and drops the rest.
void main() {
  group('deduplicateByKey — embedded subtitle tracks', () {
    test('six identical English tracks become one, the first', () {
      final tracks = <SubtitleTrack>[
        for (var i = 0; i < 6; i++)
          SubtitleTrack('sid_$i', 'English', 'auto'),
      ];
      final deduped = deduplicateByKey(
        tracks,
        (t) => (t.title, t.language),
      );
      expect(deduped, hasLength(1));
      expect(deduped.first.id, 'sid_0');
      expect(deduped.first.title, 'English');
    });

    test('different languages are all kept', () {
      final tracks = <SubtitleTrack>[
        const SubtitleTrack('sid_1', 'English', 'auto'),
        const SubtitleTrack('sid_2', 'Spanish (- Español (LA))', 'auto'),
        const SubtitleTrack('sid_3', 'Portuguese', 'por'),
      ];
      final deduped = deduplicateByKey(
        tracks,
        (t) => (t.title, t.language),
      );
      expect(deduped, hasLength(3));
      expect(deduped.map((t) => t.id), ['sid_1', 'sid_2', 'sid_3']);
    });

    test('same title, different language are different tracks', () {
      final tracks = <SubtitleTrack>[
        const SubtitleTrack('sid_1', 'English', 'eng'),
        const SubtitleTrack('sid_2', 'English', 'spa'),
      ];
      final deduped = deduplicateByKey(
        tracks,
        (t) => (t.title, t.language),
      );
      expect(deduped, hasLength(2));
    });

    test('order is first-occurrence order', () {
      final tracks = <SubtitleTrack>[
        const SubtitleTrack('sid_1', 'Spanish', 'spa'),
        const SubtitleTrack('sid_2', 'English', 'eng'),
        const SubtitleTrack('sid_3', 'Spanish', 'spa'),
        const SubtitleTrack('sid_4', 'French', 'fra'),
      ];
      final deduped = deduplicateByKey(
        tracks,
        (t) => (t.title, t.language),
      );
      expect(deduped.map((t) => t.id), ['sid_1', 'sid_2', 'sid_4']);
    });

    test('empty stays empty', () {
      expect(
        deduplicateByKey(<SubtitleTrack>[], (t) => (t.title, t.language)),
        isEmpty,
      );
    });

    test('a tap that discovers more renditions still shows one row', () {
      // The tap-spawn case (2026-11-14): picking a track makes mpv
      // discover more renditions, so the engine list grows on every
      // rebuild — 2 copies, then 4, then 6. Deduped at the source, the
      // rendered list stays at one row throughout, and it is always the
      // first track, so the tap's id keeps selecting the same track.
      for (final count in [2, 4, 6]) {
        final tracks = <SubtitleTrack>[
          for (var i = 0; i < count; i++)
            SubtitleTrack('sid_$i', 'English', 'auto'),
        ];
        final deduped = deduplicateByKey(
          tracks,
          (t) => (t.title, t.language),
        );
        expect(deduped, hasLength(1));
        expect(deduped.first.id, 'sid_0');
      }
    });
  });

  group('deduplicateByKey — external subtitle files', () {
    test('the same file listed twice becomes one, the first', () {
      final files = <SubtitleFile>[
        SubtitleFile(
          url: 'https://cdn.test/subs/por.srt',
          label: 'Portuguese (- Português (Brasil))',
          lang: 'por',
        ),
        SubtitleFile(
          url: 'https://cdn.test/subs/por.srt',
          label: 'Portuguese (- Português (Brasil))',
          lang: 'por',
        ),
      ];
      final deduped = deduplicateByKey(files, (f) => f.url);
      expect(deduped, hasLength(1));
      expect(deduped.first.label, 'Portuguese (- Português (Brasil))');
    });

    test('different files are all kept', () {
      final files = <SubtitleFile>[
        SubtitleFile(
          url: 'https://cdn.test/subs/eng.srt',
          label: 'English',
          lang: 'eng',
        ),
        SubtitleFile(
          url: 'https://cdn.test/subs/por.srt',
          label: 'Portuguese',
          lang: 'por',
        ),
      ];
      final deduped = deduplicateByKey(files, (f) => f.url);
      expect(deduped, hasLength(2));
    });
  });
}
