import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/cast/ts_segmenter.dart';

import 'ts_fixture.dart';

void main() {
  group('TsSegmenter', () {
    test('cuts on keyframes and makes every segment self-contained', () {
      final segmenter = TsSegmenter(targetSeconds: 2);
      segmenter.add(TsFixture().seconds(9));

      final segments = segmenter.segments;
      // Keyframes every second, so cuts at 2, 4, 6 and 8; the last is open.
      expect(segments.length, 4);
      for (final s in segments) {
        expect(s.duration, closeTo(2.0, 0.001));
        expect(s.bytes.length % 188, 0);
        expect(TsFixture.pidOf(s.bytes, 0), 0, reason: 'PAT first');
        expect(TsFixture.pidOf(s.bytes, 1), TsFixture.pmtPid, reason: 'then PMT');
        expect(TsFixture.pidOf(s.bytes, 2), TsFixture.videoPid);
        expect(TsFixture.randomAccessAt(s.bytes, 2), isTrue,
            reason: 'and a keyframe');
        expect(s.forced, isFalse);
      }
      expect(segments.map((s) => s.sequence), [0, 1, 2, 3]);
    });

    test('reads the codecs from the PMT, including DVB AC3', () {
      final segmenter = TsSegmenter()..add(TsFixture().seconds(1));
      expect(segmenter.info.videoName, 'H.264');
      expect(segmenter.info.audioNames, 'AAC, AC3');
    });

    test('measures the keyframe interval', () {
      final segmenter = TsSegmenter()..add(TsFixture(gop: 50).seconds(5));
      expect(segmenter.keyframeInterval, closeTo(2.0, 0.001));
    });

    test('gives the same segments however the bytes are chunked', () {
      final stream = TsFixture().seconds(7);
      final whole = TsSegmenter()..add(stream);
      final chunked = TsSegmenter();
      for (var i = 0; i < stream.length; i += 1000) {
        chunked.add(Uint8List.sublistView(
            stream, i, i + 1000 > stream.length ? stream.length : i + 1000));
      }
      expect(chunked.segments.length, whole.segments.length);
      for (var i = 0; i < whole.segments.length; i++) {
        expect(chunked.segments[i].bytes, whole.segments[i].bytes);
      }
    });

    test('resynchronises after garbage', () {
      final fixture = TsFixture();
      final segmenter = TsSegmenter()
        ..add([1, 2, 3, 0x47, 9, 9])
        ..add(fixture.seconds(3))
        ..add(List.filled(77, 0x47))
        ..add(fixture.seconds(4));
      expect(segmenter.resyncs, greaterThan(0));
      expect(segmenter.segments.length, 3);
      for (final s in segmenter.segments) {
        expect(TsFixture.pidOf(s.bytes, 0), 0);
      }
    });

    test('finds keyframes from the NAL type when the flag is missing', () {
      final segmenter = TsSegmenter()
        ..add(TsFixture(randomAccessFlag: false, idrNal: true).seconds(7));
      expect(segmenter.segments.length, 3);
      expect(segmenter.forcedCuts, 0);
      expect(segmenter.segments.first.duration, closeTo(2.0, 0.001));
    });

    test('still plays a stream whose keyframes cannot be found', () {
      final segmenter = TsSegmenter(maxSeconds: 3)
        ..add(TsFixture(randomAccessFlag: false).seconds(12));
      expect(segmenter.segments, isNotEmpty);
      expect(segmenter.forcedCuts, greaterThan(0));
      for (final s in segmenter.segments) {
        expect(s.duration, lessThanOrEqualTo(3.0001));
        expect(TsFixture.pidOf(s.bytes, 0), 0);
      }
    });

    test('forces a cut when keyframes are too far apart', () {
      final segmenter = TsSegmenter(targetSeconds: 2, maxSeconds: 4)
        ..add(TsFixture(gop: 250).seconds(13));
      expect(segmenter.forcedCuts, greaterThan(0));
      for (final s in segmenter.segments) {
        expect(s.duration, lessThanOrEqualTo(4.0001));
      }
    });

    test('keeps only the newest segments', () {
      final segmenter = TsSegmenter(keep: 4)..add(TsFixture().seconds(21));
      expect(segmenter.segments.length, 4);
      expect(segmenter.segments.first.sequence, 6);
    });

    test('also drops the oldest segments past a byte cap', () {
      final stream = TsFixture().seconds(21);
      final uncapped = TsSegmenter(keep: 100)..add(stream);
      final one = uncapped.segments.first.bytes.length;
      final capped = TsSegmenter(keep: 100, maxBytes: one * 3)..add(stream);
      expect(capped.segments.length, 3);
      expect(capped.segments.last.sequence, uncapped.segments.last.sequence);
    });

    test('flags the first segment after a reconnect as a discontinuity', () {
      final segmenter = TsSegmenter(keep: 4);
      segmenter.add(TsFixture().seconds(5));
      segmenter.markDiscontinuity();
      // A new connection: the provider's clock starts somewhere else.
      segmenter.add((TsFixture()..ptsBase = 5000).seconds(5));

      final flagged = segmenter.segments.where((s) => s.discontinuity).toList();
      expect(flagged.length, 1);
      final playlist = segmenter.playlist((n) => 'seg$n.ts');
      expect(playlist, contains('#EXT-X-DISCONTINUITY\n#EXTINF:2.000,\nseg${flagged.first.sequence}.ts'));

      // Once it scrolls off, the discontinuity sequence carries it.
      segmenter.add((TsFixture()..ptsBase = 5000 + 5 * 90000).seconds(12));
      expect(segmenter.segments.any((s) => s.discontinuity), isFalse);
      expect(segmenter.discontinuitySequence, 1);
      expect(segmenter.playlist((n) => 'seg$n.ts'),
          contains('#EXT-X-DISCONTINUITY-SEQUENCE:1'));
    });

    test('writes a live playlist', () {
      final segmenter = TsSegmenter(keep: 3)..add(TsFixture().seconds(11));
      final playlist = segmenter.playlist((n) => 'seg$n.ts');
      expect(
        playlist,
        '#EXTM3U\n'
        '#EXT-X-VERSION:3\n'
        '#EXT-X-TARGETDURATION:2\n'
        '#EXT-X-MEDIA-SEQUENCE:2\n'
        '#EXTINF:2.000,\nseg2.ts\n'
        '#EXTINF:2.000,\nseg3.ts\n'
        '#EXTINF:2.000,\nseg4.ts\n',
      );
      expect(playlist, isNot(contains('ENDLIST')),
          reason: 'a live playlist never ends');
    });
  });
}
