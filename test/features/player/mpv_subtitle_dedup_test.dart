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

  group('resolveActiveSubtitleRowId — a tap stays selected', () {
    // The Attack on Titan drawer, in the video's row order: the user taps
    // "English (source)" (id 1001) and a second later the drawer re-lit
    // "English (- (Crunchyroll)) (source)" (id 1002) with no further tap.
    late List<SubtitleTrack> embedded;
    late List<SubtitleFile> external;
    late List<SubtitleRow> rows;

    setUp(() {
      embedded = const <SubtitleTrack>[
        SubtitleTrack('1', 'English', 'auto'),
        SubtitleTrack('2', 'English 2', 'auto'),
        SubtitleTrack('3', 'English (- (Crunchyroll))', 'auto'),
        SubtitleTrack('4', 'Portuguese', 'auto'),
        SubtitleTrack('5', 'Spanish', 'auto'),
      ];
      external = <SubtitleFile>[
        SubtitleFile(
          url: 'https://cdn.test/eng2.srt',
          label: 'English 2',
          lang: 'eng',
        ),
        SubtitleFile(
          url: 'https://cdn.test/eng.srt',
          label: 'English',
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
      rows = mergeSubtitleRows(embedded: embedded, external: external);
      expect(rows.map((r) => r.id), [1001, 1000, 1002, 1003, 1004]);
      expect(rows[0].name, 'English (source)');
      expect(rows[2].name, 'English - (Crunchyroll) (source)');
    });

    int? resolve({
      (String, String)? pick,
      required SubtitleTrack current,
      List<SubtitleRow>? snapshot,
    }) => resolveActiveSubtitleRowId(
      pickedMergeKey: pick,
      current: current,
      rows: snapshot ?? rows,
      external: external,
      embedded: embedded,
    );

    test('the reported bug: tap English, engine re-reports Crunchyroll', () {
      // The tap anchors the pick; the engine's word — the auto-selected
      // Crunchyroll file — must not re-light its row afterwards.
      expect(
        resolve(
          pick: rows[0].mergeKey,
          current: SubtitleTrack.uri(
            'https://cdn.test/crunchy.srt',
            title: 'English - (Crunchyroll)',
          ),
        ),
        1001,
      );
    });

    test('the tap holds while the engine reports auto after a re-open', () {
      // A re-open resets the engine's track to 'auto' until the
      // remembered pick is re-applied; the drawer must keep showing the
      // tapped row, not the auto-selected default.
      expect(
        resolve(
          pick: rows[0].mergeKey,
          current: SubtitleTrack.auto(),
        ),
        1001,
      );
    });

    test('the tap holds while the engine reports the merged twin sid', () {
      // The HLS list settles and mpv momentarily reports the embedded
      // twin of the auto-selected file; the anchor still wins.
      expect(
        resolve(
          pick: rows[0].mergeKey,
          current: const SubtitleTrack(
            '3',
            'English (- (Crunchyroll))',
            'auto',
          ),
        ),
        1001,
      );
    });

    test('with no pick the engine governs: auto-select lights Crunchyroll', () {
      expect(
        resolve(
          current: SubtitleTrack.uri(
            'https://cdn.test/crunchy.srt',
            title: 'English - (Crunchyroll)',
          ),
        ),
        1002,
      );
    });

    test('with no pick and current auto, the default track lights its row', () {
      final withDefault = const <SubtitleTrack>[
        SubtitleTrack('1', 'English', 'auto'),
        SubtitleTrack('2', 'English 2', 'auto'),
        SubtitleTrack(
          '3',
          'English (- (Crunchyroll))',
          'auto',
          isDefault: true,
        ),
        SubtitleTrack('4', 'Portuguese', 'auto'),
        SubtitleTrack('5', 'Spanish', 'auto'),
      ];
      expect(
        resolveActiveSubtitleRowId(
          pickedMergeKey: null,
          current: SubtitleTrack.auto(),
          rows: mergeSubtitleRows(embedded: withDefault, external: external),
          external: external,
          embedded: withDefault,
        ),
        1002,
      );
    });

    test('Off always reads Off, even with a stale pick', () {
      expect(
        resolve(
          pick: rows[0].mergeKey,
          current: SubtitleTrack.no(),
        ),
        isNull,
      );
    });

    test('a pick gone from this source falls back to the engine', () {
      // The picked subtitle is not in the new source's snapshot: the
      // anchor cannot light a row that does not exist, so the engine's
      // word (Portuguese) is shown.
      expect(
        resolve(
          pick: subtitleMergeKey(language: 'deu', title: 'German'),
          current: SubtitleTrack.uri(
            'https://cdn.test/por.srt',
            title: 'Portuguese',
          ),
        ),
        1003,
      );
    });

    test('merged-row identity is stable across a refresh', () {
      // The HLS list settles with duplicate renditions of the same
      // content; the merged rows keep the same ids in the same order,
      // so the drawer's row keys never change under a tap.
      final refreshed = mergeSubtitleRows(
        embedded: const <SubtitleTrack>[
          SubtitleTrack('1', 'English', 'auto'),
          SubtitleTrack('2', 'English 2', 'auto'),
          SubtitleTrack('3', 'English (- (Crunchyroll))', 'auto'),
          SubtitleTrack('4', 'Portuguese', 'auto'),
          SubtitleTrack('5', 'Spanish', 'auto'),
          SubtitleTrack('6', 'English', 'eng'),
          SubtitleTrack('7', 'English 2', 'eng'),
        ],
        external: external,
      );
      expect(refreshed.map((r) => r.id), rows.map((r) => r.id));
      expect(refreshed.map((r) => r.name), rows.map((r) => r.name));
    });
  });
}
