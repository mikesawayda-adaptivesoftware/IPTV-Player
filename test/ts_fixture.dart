import 'dart:typed_data';

/// Builds synthetic MPEG-TS for the segmenter and relay tests: a PAT, a PMT
/// with H.264 video, AAC audio and DVB-style AC3, and 25fps video with a
/// keyframe every [gop] frames.
class TsFixture {
  static const pmtPid = 0x1000;
  static const videoPid = 0x100;
  static const aacPid = 0x101;
  static const ac3Pid = 0x102;

  /// Frames between keyframes.
  final int gop;

  /// Mark keyframes with the adaptation-field random-access flag.
  final bool randomAccessFlag;

  /// Put an IDR NAL unit at the start of each keyframe's payload.
  final bool idrNal;

  TsFixture({this.gop = 25, this.randomAccessFlag = true, this.idrNal = false});

  int _frame = 0;
  int ptsBase = 900000;

  /// [seconds] of stream at 25fps, starting where the last call stopped.
  Uint8List seconds(double seconds) {
    final b = BytesBuilder();
    final frames = (seconds * 25).round();
    for (var n = 0; n < frames; n++, _frame++) {
      if (_frame % 12 == 0) {
        b
          ..add(pat())
          ..add(pmt());
      }
      final pts = ptsBase + _frame * 3600;
      final key = _frame % gop == 0;
      b.add(videoStart(pts, keyframe: key));
      for (var k = 0; k < 3; k++) {
        b.add(packet(videoPid, Uint8List(150)));
      }
      b.add(packet(aacPid, Uint8List.fromList(pes(0xC0, pts)), pusi: true));
    }
    return b.takeBytes();
  }

  Uint8List videoStart(int pts, {required bool keyframe}) {
    final es = keyframe && idrNal
        ? [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x65]
        : [0, 0, 0, 1, 0x09, 0xF0, 0, 0, 0, 1, 0x41, 0x9A];
    return packet(
      videoPid,
      Uint8List.fromList([...pes(0xE0, pts), ...es]),
      pusi: true,
      randomAccess: keyframe && randomAccessFlag,
    );
  }

  static Uint8List pat() {
    final section = [
      0x00, 0xB0, 13, 0x00, 0x01, 0xC1, 0x00, 0x00, //
      0x00, 0x01, 0xE0 | (pmtPid >> 8), pmtPid & 0xFF,
      0, 0, 0, 0, // CRC, unchecked
    ];
    return packet(0, Uint8List.fromList([0x00, ...section]), pusi: true);
  }

  static Uint8List pmt() {
    final streams = [
      0x1B, 0xE0 | (videoPid >> 8), videoPid & 0xFF, 0xF0, 0x00, //
      0x0F, 0xE0 | (aacPid >> 8), aacPid & 0xFF, 0xF0, 0x00,
      0x06, 0xE0 | (ac3Pid >> 8), ac3Pid & 0xFF, 0xF0, 0x02, 0x6A, 0x00,
    ];
    final length = 9 + streams.length + 4;
    final section = [
      0x02, 0xB0, length, 0x00, 0x01, 0xC1, 0x00, 0x00, //
      0xE0 | (videoPid >> 8), videoPid & 0xFF, 0xF0, 0x00,
      ...streams,
      0, 0, 0, 0,
    ];
    return packet(pmtPid, Uint8List.fromList([0x00, ...section]), pusi: true);
  }

  static List<int> pes(int streamId, int pts) => [
        0, 0, 1, streamId, 0, 0, 0x80, 0x80, 5, //
        0x21 | ((pts >> 29) & 0x0E),
        (pts >> 22) & 0xFF,
        ((pts >> 14) & 0xFE) | 1,
        (pts >> 7) & 0xFF,
        ((pts << 1) & 0xFE) | 1,
      ];

  /// One 188-byte packet, padded with adaptation-field stuffing.
  static Uint8List packet(int pid, Uint8List payload,
      {bool pusi = false, bool randomAccess = false}) {
    assert(payload.length <= 182);
    final p = Uint8List(188);
    p[0] = 0x47;
    p[1] = (pusi ? 0x40 : 0) | ((pid >> 8) & 0x1F);
    p[2] = pid & 0xFF;
    p[3] = 0x30; // adaptation field + payload
    final afLength = 188 - 5 - payload.length;
    p[4] = afLength;
    p[5] = randomAccess ? 0x40 : 0x00;
    for (var i = 6; i < 5 + afLength; i++) {
      p[i] = 0xFF;
    }
    p.setAll(5 + afLength, payload);
    return p;
  }

  static int pidOf(Uint8List bytes, int packetIndex) {
    final o = packetIndex * 188;
    return ((bytes[o + 1] & 0x1F) << 8) | bytes[o + 2];
  }

  static bool randomAccessAt(Uint8List bytes, int packetIndex) {
    final o = packetIndex * 188;
    return (bytes[o + 3] & 0x20) != 0 && bytes[o + 4] > 0 && (bytes[o + 5] & 0x40) != 0;
  }
}
