import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/player/stream_quality.dart';

/// Most of these cases are drawn from how real IPTV playlists are actually
/// named, and the ones that matter most are the *negative* cases. A missed
/// sibling leaves the stream stuttering, which is what was already happening;
/// a false match silently switches the user to a different channel - a
/// different language, a different sport, a different blackout region. So the
/// bar here is "never group two things that are not variants", and the tests
/// are weighted accordingly.
QualityCandidate candidate(
  String id,
  String name, {
  String? url,
  String? tvgId,
  String? category,
}) {
  return QualityCandidate(
    id: id,
    name: name,
    url: url ?? 'http://host/live/u/p/$id.ts',
    tvgId: tvgId,
    category: category,
  );
}

void main() {
  group('qualityRank', () {
    test('ranks the standard tier words', () {
      expect(qualityRank('ESPN 4K'), greaterThan(qualityRank('ESPN FHD')!));
      expect(qualityRank('ESPN FHD'), greaterThan(qualityRank('ESPN HD')!));
      expect(qualityRank('ESPN HD'), greaterThan(qualityRank('ESPN SD')!));
      expect(qualityRank('ESPN SD'), greaterThan(qualityRank('ESPN LQ')!));
    });

    test('reads resolutions, with or without a scan suffix', () {
      expect(qualityRank('ESPN 1080'), qualityRank('ESPN FHD'));
      expect(qualityRank('ESPN 1080p'), qualityRank('ESPN FHD'));
      expect(qualityRank('ESPN 720i'), qualityRank('ESPN HD'));
      expect(qualityRank('ESPN 2160p'), qualityRank('ESPN UHD'));
    });

    test('only matches whole words, so tier letters inside a name survive', () {
      // A substring replace would eat the middle of every one of these.
      expect(qualityRank('HDNet'), isNull);
      expect(qualityRank('SDTV'), isNull);
      expect(qualityRank('MTV 80s'), isNull);
      expect(qualityRank('Nick HD+'), isNotNull, reason: 'HD is its own word');
    });

    test('does not treat 360 as a tier', () {
      // `CNN 360`, `Sky Sport 360` and `Ligue 1 360` are channel names. Ranking
      // 360 would make each of them look like a downgrade of its own family.
      expect(qualityRank('CNN 360'), isNull);
      expect(qualityRank('Sky Sport 360'), isNull);
    });

    test('does not rank codecs, containers or backup origins', () {
      // HEVC is a lower bitrate but a much heavier decode, and this app
      // force-disables hardware acceleration - so it is not a downgrade.
      expect(qualityRank('ESPN HEVC'), isNull);
      expect(qualityRank('ESPN H265'), isNull);
      // A container, not a quality.
      expect(qualityRank('ESPN RAW'), isNull);
      // A different origin at the same quality - alternateUrl's job, not ours.
      expect(qualityRank('ESPN (Backup)'), isNull);
      expect(qualityRank('ESPN ALT'), isNull);
    });

    test('an untagged name has no rank at all', () {
      expect(qualityRank('ESPN'), isNull);
      expect(qualityRank('Eurosport 1'), isNull);
    });
  });

  group('analyzeName', () {
    test('strips the tier word and keeps the rest', () {
      expect(analyzeName('ESPN HD').base, 'espn');
      expect(analyzeName('ESPN (HD)').base, 'espn');
      expect(analyzeName('ESPN - HD').base, 'espn');
    });

    test('keeps the country or bouquet prefix in the base name', () {
      // The whole point: |US| ESPN and |AR| ESPN are different languages, and
      // |US|/|UK| Sky Sports carry different rights. Stripping the prefix would
      // make "lower quality" silently mean "different feed".
      expect(analyzeName('|US| ESPN HD').base, '|us| espn');
      expect(analyzeName('|AR| ESPN HD').base, '|ar| espn');
      expect(
        analyzeName('|US| ESPN HD').base,
        isNot(analyzeName('|AR| ESPN HD').base),
      );
    });

    test('records where the tier word sat', () {
      expect(analyzeName('Movies HD').wordsAfterTier, 0);
      expect(analyzeName('UHD Movies').wordsAfterTier, 1);
      // Untagged names count as a trailing tag so they still group with one.
      expect(analyzeName('Movies').wordsAfterTier, 0);
    });

    test('takes the last tier word when a name carries two', () {
      expect(analyzeName('HD Sports SD').rank, qualityRank('x SD'));
    });
  });

  group('qualityGroupKey', () {
    test('lets a shared tvg-id bridge categories the name path would not', () {
      // Same channel, same base name, filed in two different categories. The
      // name path requires the category to match; the tvg-id path does not,
      // which is the whole reason it exists.
      final withTvg = [
        candidate('1', 'ESPN HD', tvgId: 'espn.us', category: 'Sports'),
        candidate('2', 'ESPN SD', tvgId: 'espn.us', category: 'Sports SD'),
      ];
      expect(
        qualityGroupKey(withTvg[0]),
        qualityGroupKey(withTvg[1]),
        reason: 'a shared tvg-id should bridge the two categories',
      );

      final withoutTvg = [
        candidate('1', 'ESPN HD', category: 'Sports'),
        candidate('2', 'ESPN SD', category: 'Sports SD'),
      ];
      expect(
        qualityGroupKey(withoutTvg[0]),
        isNot(qualityGroupKey(withoutTvg[1])),
        reason: 'without one, differing categories must stay apart',
      );
    });

    test('a bad tvg-id partitions the group rather than poisoning it', () {
      // Real case from a 53k-channel playlist: `US: TNT HD`, `US: TNT SD` and
      // `US: TNT WEST 4K` share an id. WEST is a different feed, but HD/SD are
      // a genuine pair - so the odd one out must be dropped, not the pair.
      final index = QualityIndex.build([
        candidate('a', 'US: TNT HD', tvgId: 'tnt.us'),
        candidate('b', 'US: TNT SD', tvgId: 'tnt.us'),
        candidate('c', 'US: TNT WEST 4K', tvgId: 'tnt.us'),
      ]);
      expect(index.groupCount, 1);

      final options = index.optionsFor(
        channelId: 'a',
        sourceLabel: 'US: TNT HD',
        currentUrl: 'http://host/live/u/p/a.ts',
      );
      expect(
        options.where((o) => o.kind == QualityKind.sibling).map((o) => o.label),
        ['US: TNT SD'],
        reason: 'the WEST feed must not be offered as a downgrade',
      );
    });

    test('treats an empty tvg-id as absent', () {
      // Providers return "" at least as often as null.
      expect(qualityGroupKey(candidate('1', 'ESPN HD', tvgId: '')),
          qualityGroupKey(candidate('2', 'ESPN HD')));
      expect(qualityGroupKey(candidate('1', 'ESPN HD', tvgId: '  ')),
          qualityGroupKey(candidate('2', 'ESPN HD')));
    });

    test('rejects a bare tier word used as a section header', () {
      // These are real entries in dumped playlists. Stripping the tier leaves
      // nothing, and without this guard every one of them lands in one group.
      expect(qualityGroupKey(candidate('1', 'HD')), isNull);
      expect(qualityGroupKey(candidate('2', '4K')), isNull);
      expect(qualityGroupKey(candidate('3', '[SD]')), isNull);
      expect(qualityGroupKey(candidate('4', '--- FHD ---')), isNull);
    });

    test('separates identical names in different categories', () {
      expect(
        qualityGroupKey(candidate('1', 'ESPN HD', category: 'Sports')),
        isNot(qualityGroupKey(candidate('2', 'ESPN HD', category: 'Latino'))),
      );
    });
  });

  group('QualityIndex - grouping', () {
    test('finds a genuine FHD/HD/SD ladder', () {
      final index = QualityIndex.build([
        candidate('a', 'ESPN FHD'),
        candidate('b', 'ESPN HD'),
        candidate('c', 'ESPN SD'),
      ]);

      final options = index.optionsFor(
        channelId: 'a',
        sourceLabel: 'ESPN FHD',
        currentUrl: 'http://host/live/u/p/a.ts',
      );

      final siblings =
          options.where((o) => o.kind == QualityKind.sibling).toList();
      expect(siblings.map((o) => o.label), ['ESPN HD', 'ESPN SD']);
    });

    test('offers nothing below an untagged entry', () {
      // `ESPN` next to `ESPN SD` gives no evidence about which is better, so
      // the untagged one is a valid source but never an automatic downgrade.
      final index = QualityIndex.build([
        candidate('a', 'ESPN'),
        candidate('b', 'ESPN HD'),
        candidate('c', 'ESPN SD'),
      ]);

      final options = index.optionsFor(
        channelId: 'a',
        sourceLabel: 'ESPN',
        currentUrl: 'http://host/live/u/p/a.ts',
      );

      expect(options.where((o) => o.kind == QualityKind.sibling), isEmpty);
    });

    test('does not group different countries of the same channel', () {
      final index = QualityIndex.build([
        candidate('a', '|US| ESPN HD'),
        candidate('b', '|AR| ESPN SD'),
      ]);
      expect(index.groupCount, 0);
    });

    test('does not group a genre channel with a same-word neighbour', () {
      // Both reduce to the base `movies`; only the tier position separates them.
      final index = QualityIndex.build([
        candidate('a', 'UHD Movies'),
        candidate('b', 'Movies HD'),
      ]);
      expect(index.groupCount, 0);
    });

    test('does not group a UHD feed with a differently-named sibling', () {
      // These carry different schedules, not different bitrates of one feed.
      expect(
        QualityIndex.build([
          candidate('a', 'Eurosport 4K'),
          candidate('b', 'Eurosport 1'),
        ]).groupCount,
        0,
      );
      expect(
        QualityIndex.build([
          candidate('a', 'NASA 4K'),
          candidate('b', 'NASA TV'),
        ]).groupCount,
        0,
      );
    });

    test('does not treat a backup or HEVC feed as a lower tier', () {
      expect(
        QualityIndex.build([
          candidate('a', 'ESPN HD'),
          candidate('b', 'ESPN HD (Backup)'),
        ]).groupCount,
        0,
      );
      expect(
        QualityIndex.build([
          candidate('a', 'ESPN HD'),
          candidate('b', 'ESPN HD HEVC'),
        ]).groupCount,
        0,
      );
    });

    test('groups on a shared tvg-id across different categories', () {
      // What the tvg-id path still buys: variants filed under different
      // categories, which the name path would refuse.
      final index = QualityIndex.build([
        candidate('a', 'ESPN HD', tvgId: 'espn.us', category: 'Sports'),
        candidate('b', 'ESPN SD', tvgId: 'espn.us', category: 'Sports SD'),
      ]);
      expect(index.groupCount, 1);
    });

    test('refuses a shared tvg-id when the names disagree', () {
      // Measured against a real 53k-channel playlist, this is where tvg-id
      // grouping goes wrong: `TS` is used as a placeholder id on 444 unrelated
      // channels, `01TV.fr` on 18, and even credible-looking ids put
      // `BUNDESLIGA 2` with `BUNDESLIGA 3` and `beIN SPORTS 2` with its FRANCE
      // feed. A provider claiming two entries are the same channel is not worth
      // much unless the names agree too.
      expect(
        QualityIndex.build([
          candidate('a', 'SKY SPORT BUNDESLIGA 2 HD', tvgId: 'sky.de'),
          candidate('b', 'SKY SPORT BUNDESLIGA 3 SD', tvgId: 'sky.de'),
        ]).groupCount,
        0,
      );
      expect(
        QualityIndex.build([
          candidate('a', 'beIN SPORTS 2 HD', tvgId: 'bein2'),
          candidate('b', 'beIN SPORTS 2 FRANCE SD', tvgId: 'bein2'),
        ]).groupCount,
        0,
      );
    });

    test('does not rank a bouquet label as a tier', () {
      // This subscription prefixes 154 channels `4K:` or `8K:` - the provider
      // is called "World 8K". Read as a tier, every one of them looked like a
      // 4K/8K rendition of whatever followed, and `8K: beIN SPORTS 2 SD`
      // outranked `beIN SPORTS 2 HD`.
      expect(qualityRank('8K: beIN SPORTS 2 SD'), qualityRank('x SD'));
      expect(qualityRank('4K: LA 1'), isNull);
      expect(analyzeName('IT: SKY UNO HD').base, 'it: sky uno');
    });

    test('never treats a timeshift channel as a quality variant', () {
      // `ITV 2+1` is an hour behind `ITV 2`, not a smaller version of it.
      // Switching someone mid-programme is worse than the stutter it fixes.
      expect(
        QualityIndex.build([
          candidate('a', 'UK: ITV 2 HD'),
          candidate('b', 'UK: ITV 2+1'),
        ]).groupCount,
        0,
      );
      expect(qualityGroupKey(candidate('1', 'UK: HGTV +1')), isNull);
    });

    test('reads tiers written in superscript letters', () {
      // Widespread in real playlists: `SKY SPORTS NEWS ᴴᴰ`, `LA 1 ᵁᴴᴰ ³⁸⁴⁰ᴾ`.
      // Unfolded these are invisible to a [A-Za-z0-9]+ tokeniser.
      expect(qualityRank('VIP: SKY SPORTS NEWS \u1D34\u1D30'),
          qualityRank('x HD'));
      expect(qualityRank('4K: LA 1 \u1D41\u1D34\u1D30'), qualityRank('x UHD'));
      // A folded codec marker is still not a tier, and still keeps the two
      // names apart.
      expect(
        QualityIndex.build([
          candidate('a', 'VIP: SKY SPORTS MIX \u1D34\u1D30'),
          candidate('b', 'VIP: SKY SPORTS MIX \u02B0\u1D49\u1D5B\u1D9C'),
        ]).groupCount,
        0,
      );
    });

    test('a shared tvg-id with no tier difference yields no downgrade', () {
      // Sloppy providers put one tvg-id on genuinely different feeds. Requiring
      // two distinct known tiers is what makes that harmless.
      final index = QualityIndex.build([
        candidate('a', '|US| ESPN', tvgId: 'espn.us'),
        candidate('b', '|AR| ESPN', tvgId: 'espn.us'),
      ]);
      expect(index.groupCount, 0);
    });

    test('ignores duplicate entries pointing at one URL', () {
      // Endemic in dumped playlists. Left in, they would burn a recovery rung
      // "switching" to the stream already playing.
      final index = QualityIndex.build([
        candidate('a', 'ESPN HD', url: 'http://host/same.ts'),
        candidate('b', 'ESPN SD', url: 'http://host/same.ts'),
      ]);
      expect(index.groupCount, 0);
    });

    test('refuses an implausibly large group', () {
      final index = QualityIndex.build([
        candidate('a', 'Sport 8K'),
        candidate('b', 'Sport 4K'),
        candidate('c', 'Sport FHD'),
        candidate('d', 'Sport HD'),
        candidate('e', 'Sport HQ'),
        candidate('f', 'Sport SD'),
        candidate('g', 'Sport LQ'),
      ]);
      expect(index.groupCount, 0,
          reason: 'a 7-member group is a normalisation failure, not a ladder');
    });
  });

  group('QualityIndex - options', () {
    const tsUrl = 'http://host/live/u/p/a.ts';
    const hlsUrl = 'http://host/live/u/p/a.m3u8';

    test('always leads with the source', () {
      final options = const QualityIndex.empty().optionsFor(
        channelId: 'a',
        sourceLabel: 'ESPN HD',
        currentUrl: tsUrl,
      );
      expect(options.first.kind, QualityKind.source);
      expect(options.first.label, 'ESPN HD');
    });

    test('always offers audio only, but never for automatic selection', () {
      // On a muxed transport stream this saves no bandwidth at all - the
      // demuxer still reads every byte and throws the video away - and a black
      // frame with sound is indistinguishable from the freeze it would be
      // fixing. It is a deliberate user choice or nothing.
      final options = const QualityIndex.empty().optionsFor(
        channelId: 'a',
        sourceLabel: 'ESPN HD',
        currentUrl: tsUrl,
      );
      final audio = options.firstWhere((o) => o.kind == QualityKind.audioOnly);
      expect(audio.videoDisabled, isTrue);
      expect(audio.autoSelectable, isFalse);
    });

    test('offers an HLS bitrate cap only on a playlist URL', () {
      expect(
        const QualityIndex.empty()
            .optionsFor(
                channelId: 'a', sourceLabel: 'ESPN', currentUrl: hlsUrl)
            .any((o) => o.kind == QualityKind.hlsCap),
        isTrue,
      );
      // `hls-bitrate` means nothing for a raw transport stream. Such a stream
      // can still reach the option later, once the alternate-format recovery
      // rung has flipped the container.
      expect(
        const QualityIndex.empty()
            .optionsFor(channelId: 'a', sourceLabel: 'ESPN', currentUrl: tsUrl)
            .any((o) => o.kind == QualityKind.hlsCap),
        isFalse,
      );
    });

    test('skips a sibling that is already what is playing', () {
      final index = QualityIndex.build([
        candidate('a', 'ESPN FHD', url: 'http://host/a.ts'),
        candidate('b', 'ESPN HD', url: 'http://host/b.ts'),
        candidate('c', 'ESPN SD', url: 'http://host/c.ts'),
      ]);

      final options = index.optionsFor(
        channelId: 'a',
        sourceLabel: 'ESPN FHD',
        currentUrl: 'http://host/b.ts',
      );

      expect(
        options.where((o) => o.kind == QualityKind.sibling).map((o) => o.label),
        ['ESPN SD'],
      );
    });

    test('never ties two distinct resolutions', () {
      // These tied at first, which let a real ladder in the playlist come out
      // ordered 720 -> 480 -> 576 - a "downgrade" that steps back up.
      expect(qualityRank('x 576'), greaterThan(qualityRank('x 480')!));
      expect(qualityRank('x 720'), greaterThan(qualityRank('x 576')!));
      expect(qualityRank('x SD'), greaterThan(qualityRank('x 576')!));
    });

    test('collapses siblings that share a name', () {
      // Real case: `US: FOX NEWS HD` is listed three times at distinct URLs, so
      // the build-time URL de-duplication does not catch it. Three identical
      // rows in the picker are unusable.
      final index = QualityIndex.build([
        candidate('a', 'US: FOX NEWS UHD', url: 'http://host/a.ts'),
        candidate('b', 'US: FOX NEWS HD', url: 'http://host/b.ts'),
        candidate('c', 'US: FOX NEWS HD', url: 'http://host/c.ts'),
        candidate('d', 'US: FOX NEWS HD', url: 'http://host/d.ts'),
      ]);

      final siblings = index
          .optionsFor(
            channelId: 'a',
            sourceLabel: 'US: FOX NEWS UHD',
            currentUrl: 'http://host/a.ts',
          )
          .where((o) => o.kind == QualityKind.sibling)
          .toList();

      expect(siblings.map((o) => o.label), ['US: FOX NEWS HD']);
    });

    test('is descending, so walking it only ever lowers quality', () {
      final index = QualityIndex.build([
        candidate('a', 'ESPN FHD'),
        candidate('b', 'ESPN HD'),
        candidate('c', 'ESPN SD'),
      ]);

      final ranks = index
          .optionsFor(
            channelId: 'a',
            sourceLabel: 'ESPN FHD',
            currentUrl: 'http://host/live/u/p/a.ts',
          )
          .map((o) => o.rank)
          .whereType<int>()
          .toList();

      // The property, not the numbers: the tier values are spaced so new tiers
      // can be inserted, so asserting literals here would break on every
      // renumbering without catching anything real.
      expect(ranks.length, 3);
      for (var i = 1; i < ranks.length; i++) {
        expect(ranks[i], lessThan(ranks[i - 1]),
            reason: 'option $i must be lower quality than the one before it');
      }
    });
  });
}
