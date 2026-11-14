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

  group('mergeSubtitleRows — [auto] renditions and (source) files', () {
    test(
      'the Attack on Titan case: five [auto] rows merge into five (source) rows',
      () {
        final embedded = <SubtitleTrack>[
          const SubtitleTrack('1', 'English', 'auto'),
          const SubtitleTrack('2', 'English 2', 'auto'),
          const SubtitleTrack('3', 'English (- (Crunchyroll))', 'auto'),
          const SubtitleTrack('4', 'Portuguese', 'auto'),
          const SubtitleTrack('5', 'Spanish', 'auto'),
        ];
        final external = <SubtitleFile>[
          SubtitleFile(
            url: 'https://cdn.test/eng.srt',
            label: 'English',
            lang: 'eng',
          ),
          SubtitleFile(
            url: 'https://cdn.test/eng2.srt',
            label: 'English 2',
            lang: 'eng',
          ),
          SubtitleFile(
            url: 'https://cdn.test/crunchy.srt',
            label: 'English - (Crunchyroll)',
            lang: 'eng',
          ),
          SubtitleFile(
            url: 'https://cdn.test/por.srt',
            label: 'Portuguese',
            lang: 'por',
          ),
          SubtitleFile(
            url: 'https://cdn.test/spa.srt',
            label: 'Spanish',
            lang: 'spa',
          ),
        ];
        final rows = mergeSubtitleRows(
          embedded: embedded,
          external: external,
        );
        expect(rows, hasLength(5));
        expect(rows.map((r) => r.id), [1000, 1001, 1002, 1003, 1004]);
        expect(rows.map((r) => r.name), [
          'English (source)',
          'English 2 (source)',
          'English - (Crunchyroll) (source)',
          'Portuguese (source)',
          'Spanish (source)',
        ]);
        // Every row keeps its embedded twin, so the active-track
        // read-back can light the (source) row while mpv plays the
        // streamed track.
        expect(
          rows.map((r) => r.embedded?.id),
          ['1', '2', '3', '4', '5'],
        );
      },
    );

    test('embedded-only tracks keep their sid and [auto] name', () {
      final rows = mergeSubtitleRows(
        embedded: const [SubtitleTrack('7', 'French', 'auto')],
        external: const [],
      );
      expect(rows, hasLength(1));
      expect(rows.first.id, 7);
      expect(rows.first.name, 'French - [auto]');
      expect(rows.first.external, isNull);
    });

    test('more renditions discovered later still merge to the same rows', () {
      // mpv discovers renditions over time: first one English rendition,
      // then the same content again under a second language spelling.
      // The rendered list must not grow on scroll/rebuild.
      final external = <SubtitleFile>[
        SubtitleFile(
          url: 'https://cdn.test/eng.srt',
          label: 'English',
          lang: 'eng',
        ),
      ];
      final first = mergeSubtitleRows(
        embedded: const [SubtitleTrack('1', 'English', 'auto')],
        external: external,
      );
      final later = mergeSubtitleRows(
        embedded: const [
          SubtitleTrack('1', 'English', 'auto'),
          SubtitleTrack('2', 'English', 'eng'),
        ],
        external: external,
      );
      expect(first.map((r) => r.id), [1000]);
      expect(later.map((r) => r.id), [1000]);
    });

    test('English, English 2 and English (SDH) stay three rows', () {
      final rows = mergeSubtitleRows(
        embedded: const [
          SubtitleTrack('1', 'English', 'auto'),
          SubtitleTrack('2', 'English 2', 'auto'),
          SubtitleTrack('3', 'English (SDH)', 'auto'),
        ],
        external: const [],
      );
      expect(rows.map((r) => r.name), [
        'English - [auto]',
        'English 2 - [auto]',
        'English (SDH) - [auto]',
      ]);
    });
  });

  group('subtitleMergeKey', () {
    test('decoration-only differences share a key', () {
      expect(
        subtitleMergeKey(
          language: 'auto',
          title: 'English (- (Crunchyroll))',
        ),
        subtitleMergeKey(
          language: 'eng',
          title: 'English - (Crunchyroll)',
        ),
      );
    });

    test('a number in the title is a different track', () {
      expect(
        subtitleMergeKey(language: 'auto', title: 'English 2'),
        isNot(subtitleMergeKey(language: 'auto', title: 'English')),
      );
    });

    test('a code, a name and a title all read as one language', () {
      expect(
        subtitleMergeKey(language: 'eng', title: 'English'),
        ('en', ''),
      );
      expect(
        subtitleMergeKey(language: 'en', title: 'English'),
        ('en', ''),
      );
      expect(
        subtitleMergeKey(language: 'auto', title: 'English'),
        ('en', ''),
      );
    });
  });
}
