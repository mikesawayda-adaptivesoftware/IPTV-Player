import 'dart:math' as math;
import 'dart:typed_data';

/// One finished HLS chunk: a run of whole MPEG-TS packets that starts with the
/// stream's PAT and PMT and, when the stream has video, on a keyframe.
class TsSegment {
  final int sequence;
  final Uint8List bytes;

  /// Seconds, from the presentation timestamps either side of the cut.
  final double duration;

  /// The first segment after the provider connection was re-opened. The
  /// timestamps restart there, so the playlist must say so or the receiver
  /// stalls waiting for a continuation that never comes.
  final bool discontinuity;

  /// Cut at [TsSegmenter.maxSeconds] because no keyframe was seen in time.
  final bool forced;

  const TsSegment({
    required this.sequence,
    required this.bytes,
    required this.duration,
    required this.discontinuity,
    required this.forced,
  });
}

/// What the PMT says the stream carries. Shown on the cast test screen,
/// because whether the Chromecast can decode these is the main thing the test
/// has to find out.
class TsStreamInfo {
  final int? videoPid;
  final int? videoType;
  final Map<int, String> audio;

  const TsStreamInfo({this.videoPid, this.videoType, this.audio = const {}});

  String get videoName => videoType == null ? 'none' : streamTypeName(videoType!);

  String get audioNames => audio.isEmpty ? 'none' : audio.values.join(', ');

  static String streamTypeName(int type) {
    switch (type) {
      case 0x01:
        return 'MPEG-1';
      case 0x02:
        return 'MPEG-2';
      case 0x1B:
        return 'H.264';
      case 0x24:
        return 'HEVC';
      case 0x03:
      case 0x04:
        return 'MP2';
      case 0x0F:
        return 'AAC';
      case 0x11:
        return 'AAC (LATM)';
      case 0x81:
        return 'AC3';
      case 0x87:
        return 'E-AC3';
      default:
        return '0x${type.toRadixString(16)}';
    }
  }
}

/// Cuts a live MPEG-TS byte stream into HLS segments without re-encoding.
///
/// HLS accepts MPEG-TS segments as they are, so all this has to do is find
/// places where a segment can start - a video keyframe - and make each segment
/// self-contained by putting the PAT and PMT at its head. The picture and sound
/// are passed through untouched.
///
/// Pure and synchronous so it can be fed recorded streams in tests.
class TsSegmenter {
  static const int packetSize = 188;
  static const int _sync = 0x47;
  static const int _ptsMask = (1 << 33) - 1;

  /// Cut at the first keyframe at least this far into a segment.
  final double targetSeconds;

  /// Cut regardless of keyframes past this, so a stream whose keyframes cannot
  /// be detected still produces segments rather than one that grows forever.
  final double maxSeconds;

  /// Segments kept for the playlist; older ones are dropped.
  final int keep;

  TsSegmenter({
    this.targetSeconds = 2.0,
    this.maxSeconds = 8.0,
    this.keep = 10,
  });

  final List<TsSegment> _segments = [];
  List<TsSegment> get segments => List.unmodifiable(_segments);

  /// Discontinuities that have scrolled off the front of [segments]; the
  /// playlist's EXT-X-DISCONTINUITY-SEQUENCE.
  int get discontinuitySequence => _discontinuitySequence;
  int _discontinuitySequence = 0;

  int _nextSequence = 0;

  Uint8List _leftover = Uint8List(0);

  Uint8List? _pat;
  Uint8List? _pmt;
  int? _pmtPid;

  TsStreamInfo _info = const TsStreamInfo();
  TsStreamInfo get info => _info;

  BytesBuilder? _current;
  int? _segmentStartPts;
  bool _nextIsDiscontinuity = false;

  /// When the segmenter started waiting for a first keyframe.
  int? _waitingSincePts;

  /// Stats for the test screen.
  int bytesIn = 0;
  int resyncs = 0;
  int forcedCuts = 0;
  int keyframes = 0;
  int? _lastKeyframePts;
  double? keyframeInterval;

  /// Feeds raw bytes from the provider, in chunks of any size.
  void add(List<int> chunk) {
    bytesIn += chunk.length;
    final Uint8List data;
    if (_leftover.isEmpty) {
      data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    } else {
      data = Uint8List(_leftover.length + chunk.length)
        ..setAll(0, _leftover)
        ..setAll(_leftover.length, chunk);
    }

    var i = 0;
    while (i + packetSize <= data.length) {
      if (data[i] != _sync || !_alignedAt(data, i)) {
        final next = _findSync(data, i + 1);
        if (next < 0) {
          // Keep the tail; the next chunk may complete a packet.
          i = math.max(i, data.length - packetSize + 1);
          break;
        }
        resyncs++;
        i = next;
        continue;
      }
      _packet(Uint8List.sublistView(data, i, i + packetSize));
      i += packetSize;
    }
    _leftover = Uint8List.fromList(Uint8List.sublistView(data, i));
  }

  /// Called after the provider connection was re-opened. The partial segment
  /// is thrown away - its tail is gone - and the next one is flagged.
  void markDiscontinuity() {
    _current = null;
    _segmentStartPts = null;
    _waitingSincePts = null;
    _lastKeyframePts = null;
    _leftover = Uint8List(0);
    _nextIsDiscontinuity = true;
  }

  /// The live HLS playlist for the kept segments. [uriFor] names a segment.
  String playlist(String Function(int sequence) uriFor) {
    final b = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:3')
      ..writeln('#EXT-X-TARGETDURATION:$_targetDuration');
    if (_segments.isNotEmpty) {
      b.writeln('#EXT-X-MEDIA-SEQUENCE:${_segments.first.sequence}');
    }
    if (_discontinuitySequence > 0) {
      b.writeln('#EXT-X-DISCONTINUITY-SEQUENCE:$_discontinuitySequence');
    }
    for (final s in _segments) {
      if (s.discontinuity) b.writeln('#EXT-X-DISCONTINUITY');
      b
        ..writeln('#EXTINF:${s.duration.toStringAsFixed(3)},')
        ..writeln(uriFor(s.sequence));
    }
    return b.toString();
  }

  TsSegment? segment(int sequence) {
    for (final s in _segments) {
      if (s.sequence == sequence) return s;
    }
    return null;
  }

  /// Never allowed to shrink: HLS clients size their reload timer from it.
  int _targetDuration = 0;

  // ==========================================================================

  bool _alignedAt(Uint8List data, int i) {
    // A lone 0x47 inside a payload is common; one 188 bytes on agrees.
    final next = i + packetSize;
    return next >= data.length || data[next] == _sync;
  }

  int _findSync(Uint8List data, int from) {
    for (var j = from; j + packetSize <= data.length; j++) {
      if (data[j] == _sync && _alignedAt(data, j)) return j;
    }
    return -1;
  }

  void _packet(Uint8List p) {
    final pid = ((p[1] & 0x1F) << 8) | p[2];
    final pusi = (p[1] & 0x40) != 0;
    final afc = (p[3] >> 4) & 0x03;
    var payload = 4;
    var randomAccess = false;
    if ((afc & 0x02) != 0) {
      final afLength = p[4];
      if (afLength > 0) randomAccess = (p[5] & 0x40) != 0;
      payload = 5 + afLength;
    }
    final hasPayload = (afc & 0x01) != 0 && payload < packetSize;

    if (pid == 0 && pusi && hasPayload) {
      _parsePat(p, payload);
    } else if (pid == _pmtPid && pusi && hasPayload) {
      _parsePmt(p, payload);
    }

    final clockPid = _info.videoPid ?? _firstAudioPid;
    if (clockPid != null && pid == clockPid && pusi && hasPayload) {
      final pts = _readPts(p, payload);
      if (pts != null) {
        final isVideo = _info.videoPid != null;
        final keyframe =
            !isVideo || randomAccess || _hasKeyframeNal(p, payload, _info.videoType);
        if (isVideo && keyframe) _noteKeyframe(pts);
        _maybeCut(pts, keyframe);
      }
    }

    _current?.add(p);
  }

  int? get _firstAudioPid => _info.audio.isEmpty ? null : _info.audio.keys.first;

  void _noteKeyframe(int pts) {
    keyframes++;
    final last = _lastKeyframePts;
    if (last != null) {
      final gap = ((pts - last) & _ptsMask) / 90000.0;
      if (gap > 0 && gap < 30) keyframeInterval = gap;
    }
    _lastKeyframePts = pts;
  }

  /// Starts a segment, or ends one and starts the next, at this PES start.
  void _maybeCut(int pts, bool keyframe) {
    if (_pat == null || _pmt == null) return;

    final start = _segmentStartPts;
    if (_current == null || start == null) {
      final waiting = _waitingSincePts ??= pts;
      if (keyframe) {
        _begin(pts);
      } else if (((pts - waiting) & _ptsMask) / 90000.0 >= maxSeconds) {
        // No keyframe we can recognise. Start anyway: the receiver shows a
        // smeared picture until the next real one, which beats never playing.
        forcedCuts++;
        _begin(pts);
      }
      return;
    }

    final elapsed = ((pts - start) & _ptsMask) / 90000.0;
    if (elapsed > 60) {
      // A timestamp jump, not a long segment: the provider restarted its
      // clock. Close what we have at a nominal length and flag the break.
      _finish(targetSeconds, forced: false);
      _nextIsDiscontinuity = true;
      _segmentStartPts = null;
      if (keyframe) _begin(pts);
      return;
    }
    if ((keyframe && elapsed >= targetSeconds) || elapsed >= maxSeconds) {
      final forced = !keyframe;
      if (forced) forcedCuts++;
      _finish(elapsed, forced: forced);
      _begin(pts);
    }
  }

  void _begin(int pts) {
    _waitingSincePts = null;
    _current = BytesBuilder(copy: true)
      ..add(_pat!)
      ..add(_pmt!);
    _segmentStartPts = pts;
  }

  void _finish(double duration, {required bool forced}) {
    final builder = _current;
    if (builder == null) return;
    _segments.add(TsSegment(
      sequence: _nextSequence++,
      bytes: builder.takeBytes(),
      duration: duration,
      discontinuity: _nextIsDiscontinuity,
      forced: forced,
    ));
    _nextIsDiscontinuity = false;
    _current = null;
    _targetDuration = math.max(_targetDuration, duration.ceil());
    while (_segments.length > keep) {
      if (_segments.first.discontinuity) _discontinuitySequence++;
      _segments.removeAt(0);
    }
  }

  // ==========================================================================
  // Table and PES parsing. Bounds-checked throughout: this reads whatever a
  // provider sends, and a malformed packet must cost one packet, not a crash.
  // ==========================================================================

  void _parsePat(Uint8List p, int payload) {
    final table = payload + 1 + p[payload];
    if (table + 8 > packetSize || p[table] != 0x00) return;
    final sectionLength = ((p[table + 1] & 0x0F) << 8) | p[table + 2];
    final end = math.min(table + 3 + sectionLength - 4, packetSize);
    for (var j = table + 8; j + 4 <= end; j += 4) {
      final program = (p[j] << 8) | p[j + 1];
      if (program == 0) continue; // network PID, not a programme
      _pmtPid = ((p[j + 2] & 0x1F) << 8) | p[j + 3];
      _pat = Uint8List.fromList(p);
      return;
    }
  }

  void _parsePmt(Uint8List p, int payload) {
    final table = payload + 1 + p[payload];
    if (table + 12 > packetSize || p[table] != 0x02) return;
    final sectionLength = ((p[table + 1] & 0x0F) << 8) | p[table + 2];
    final end = math.min(table + 3 + sectionLength - 4, packetSize);
    final programInfo = ((p[table + 10] & 0x0F) << 8) | p[table + 11];

    int? videoPid;
    int? videoType;
    final audio = <int, String>{};
    var j = table + 12 + programInfo;
    while (j + 5 <= end) {
      final type = p[j];
      final pid = ((p[j + 1] & 0x1F) << 8) | p[j + 2];
      final infoLength = ((p[j + 3] & 0x0F) << 8) | p[j + 4];
      final descriptors = j + 5;
      j = descriptors + infoLength;

      switch (type) {
        case 0x01:
        case 0x02:
        case 0x1B:
        case 0x24:
          if (videoPid == null) {
            videoPid = pid;
            videoType = type;
          }
        case 0x03:
        case 0x04:
        case 0x0F:
        case 0x11:
        case 0x81:
        case 0x87:
          audio[pid] = TsStreamInfo.streamTypeName(type);
        case 0x06:
          // DVB carries AC3/E-AC3 as private data, named by a descriptor.
          final name = _privateAudioName(p, descriptors, math.min(j, end));
          if (name != null) audio[pid] = name;
      }
    }

    _pmt = Uint8List.fromList(p);
    _info = TsStreamInfo(videoPid: videoPid, videoType: videoType, audio: audio);
  }

  String? _privateAudioName(Uint8List p, int from, int to) {
    var k = from;
    while (k + 2 <= to) {
      final tag = p[k];
      if (tag == 0x6A) return 'AC3';
      if (tag == 0x7A) return 'E-AC3';
      if (tag == 0x7C) return 'AAC';
      k += 2 + p[k + 1];
    }
    return null;
  }

  int? _readPts(Uint8List p, int payload) {
    if (payload + 14 > packetSize) return null;
    if (p[payload] != 0 || p[payload + 1] != 0 || p[payload + 2] != 1) return null;
    if ((p[payload + 7] & 0x80) == 0) return null;
    final b = payload + 9;
    return (((p[b] >> 1) & 0x07) << 30) |
        (p[b + 1] << 22) |
        ((p[b + 2] >> 1) << 15) |
        (p[b + 3] << 7) |
        (p[b + 4] >> 1);
  }

  /// Fallback for providers that do not set the random-access flag: look for
  /// an IDR or parameter set in the first packet of the access unit.
  bool _hasKeyframeNal(Uint8List p, int payload, int? videoType) {
    if (payload + 9 > packetSize) return false;
    final es = payload + 9 + p[payload + 8];
    for (var k = es; k + 3 < packetSize; k++) {
      if (p[k] != 0 || p[k + 1] != 0 || p[k + 2] != 1) continue;
      final b = p[k + 3];
      switch (videoType) {
        case 0x1B:
          final avc = b & 0x1F;
          if (avc == 5 || avc == 7) return true;
        case 0x24:
          final hevc = (b >> 1) & 0x3F;
          if ((hevc >= 16 && hevc <= 21) || hevc == 32 || hevc == 33) return true;
        case 0x01:
        case 0x02:
          if (b == 0xB3 || b == 0xB8) return true;
      }
    }
    return false;
  }
}
