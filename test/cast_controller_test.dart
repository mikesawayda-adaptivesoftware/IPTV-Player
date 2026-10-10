import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/cast/cast_bridge.dart';
import 'package:iptv_player/core/cast/cast_controller.dart';
import 'package:iptv_player/core/cast/cast_relay.dart';
import 'package:iptv_player/core/cast/ts_segmenter.dart';
import 'package:iptv_player/data/models/channel.dart';

/// Every call to the bridge and relay, in order, so tests can assert on the
/// teardown sequence the one-stream rule depends on.
final List<String> calls = [];

class _FakeBridge extends CastBridge {
  final session_ = StreamController<CastSessionEvent>.broadcast(sync: true);
  final receiver_ = StreamController<ReceiverStatus>.broadcast(sync: true);
  final commands_ = StreamController<CastCommand>.broadcast(sync: true);

  @override
  Stream<CastSessionEvent> get session => session_.stream;
  @override
  Stream<ReceiverStatus> get receiver => receiver_.stream;
  @override
  Stream<CastCommand> get commands => commands_.stream;
  @override
  Stream<double> get volume => const Stream.empty();
  @override
  Stream<CastProgress> get progress => const Stream.empty();

  @override
  Future<void> connect(String deviceId) async => calls.add('connect $deviceId');
  @override
  Future<void> load(String url,
          {required String title,
          bool live = true,
          String contentType = 'application/x-mpegURL',
          Duration position = Duration.zero}) async =>
      calls.add('load $title');
  @override
  Future<void> keepAlive(
          {required String title,
          required String device,
          required bool live,
          bool playing = true}) async =>
      calls.add('keepAlive $title');
  @override
  Future<void> releaseKeepAlive() async => calls.add('releaseKeepAlive');
  @override
  Future<void> disconnect() async => calls.add('disconnect');
  @override
  Future<void> setVolume(double level) async {}
}

class _FakeRelay extends CastRelay {
  int videoType = 0x1B; // H.264

  @override
  Future<Uri> tune(String sourceUrl) async {
    calls.add('tune $sourceUrl');
    return playlistUri;
  }

  @override
  Future<Uri> tuneMovie(String sourceUrl, {required String extension}) async {
    calls.add('tuneMovie $extension');
    return movieUri;
  }

  @override
  Uri get playlistUri => Uri.parse('http://10.0.0.2/x/1/live.m3u8');
  @override
  Uri get movieUri => Uri.parse('http://10.0.0.2/x/1/movie.mp4');

  @override
  Future<void> stop() async => calls.add('relay.stop');

  @override
  RelayStats get stats => RelayStats(
        connected: true,
        providerConnections: 1,
        bytesIn: 0,
        kbpsIn: 0,
        segments: 0,
        lastSegmentSeconds: null,
        backlogSeconds: 0,
        keyframeInterval: null,
        forcedCuts: 0,
        resyncs: 0,
        reconnects: 0,
        lastError: null,
        info: TsStreamInfo(videoPid: 256, videoType: videoType),
        playlistRequests: 0,
        segmentRequests: 0,
        segmentMisses: 0,
        lastReceiverRequest: null,
      );
}

Channel _channel(String id) => Channel(
      id: id,
      name: 'Channel $id',
      streamUrl: 'http://provider/live/u/p/$id.ts',
    );

const _device = CastDevice(id: 'tv', name: 'Living Room');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeBridge bridge;
  late _FakeRelay relay;
  late CastController controller;
  final channels = [_channel('1'), _channel('2'), _channel('3')];

  setUp(() {
    calls.clear();
    bridge = _FakeBridge();
    relay = _FakeRelay();
    controller = CastController(
      bridge: () => bridge,
      relay: () => relay,
      retryDelay: const Duration(milliseconds: 10),
      stepChannel: (current, forward) {
        final i = channels.indexWhere((c) => c.id == current.id) + (forward ? 1 : -1);
        return i < 0 || i >= channels.length ? null : channels[i];
      },
    );
  });

  tearDown(() => controller.dispose());

  Future<void> castAndConnect(Channel channel) async {
    await controller.castChannel(channel, device: _device);
    bridge.session_.add(const CastSessionEvent(CastSessionState.connected, device: 'Living Room'));
    await pumpEventQueue();
  }

  test('joins the device, then tunes and loads once it is connected', () async {
    await controller.castChannel(channels[0], device: _device);
    expect(controller.state.phase, CastPhase.connecting);
    expect(calls, ['connect tv']);

    bridge.session_.add(const CastSessionEvent(CastSessionState.connected, device: 'Living Room'));
    await pumpEventQueue();

    expect(controller.state.phase, CastPhase.casting);
    expect(calls, [
      'connect tv',
      'tune ${channels[0].streamUrl}',
      'load Channel 1',
      'keepAlive Channel 1',
    ]);
  });

  test('stop closes the provider connection before anything else', () async {
    await castAndConnect(channels[0]);
    calls.clear();

    await controller.stop();
    expect(calls, ['relay.stop', 'releaseKeepAlive', 'disconnect']);
    expect(controller.state.active, isFalse);

    // The session ending because we ended it is not a lost cast.
    bridge.session_.add(const CastSessionEvent(CastSessionState.ended));
    await pumpEventQueue();
    expect(controller.state.lost, isNull);
  });

  test('a session that ends on its own is offered back to the phone', () async {
    await castAndConnect(channels[1]);
    calls.clear();

    bridge.session_.add(const CastSessionEvent(CastSessionState.ended));
    await pumpEventQueue();

    expect(calls, ['relay.stop', 'releaseKeepAlive']);
    expect(controller.state.active, isFalse);
    expect(controller.state.lost?.channel?.id, '2');
    expect(controller.state.error, contains('Lost the connection'));
  });

  test('lock-screen next and previous step through the channel list', () async {
    await castAndConnect(channels[0]);
    calls.clear();

    bridge.commands_.add(CastCommand.next);
    await pumpEventQueue();
    expect(controller.state.media?.channel?.id, '2');
    expect(calls.first, 'tune ${channels[1].streamUrl}');

    bridge.commands_.add(CastCommand.previous);
    await pumpEventQueue();
    expect(controller.state.media?.channel?.id, '1');
  });

  test('a receiver error is retried without a new provider connection', () async {
    await castAndConnect(channels[0]);
    calls.clear();

    bridge.receiver_.add(const ReceiverStatus(ReceiverState.idle, 'error'));
    await Future.delayed(const Duration(milliseconds: 50));

    expect(calls, ['load Channel 1']);
    expect(controller.state.unsupported, isFalse);
  });

  test('MPEG-2 video is reported as uncastable, not retried forever', () async {
    relay.videoType = 0x02;
    await castAndConnect(channels[0]);
    calls.clear();

    bridge.receiver_.add(const ReceiverStatus(ReceiverState.idle, 'error'));
    await Future.delayed(const Duration(milliseconds: 50));

    expect(controller.state.unsupported, isTrue);
    expect(controller.state.error, contains('MPEG-2'));
    // The provider's one stream is released, and nothing is reloaded.
    expect(calls, ['relay.stop']);

    // Moving on to another channel still works.
    relay.videoType = 0x1B;
    await controller.step(true);
    expect(controller.state.unsupported, isFalse);
    expect(controller.state.media?.channel?.id, '2');
  });

  test('a film the receiver cannot play is refused before connecting', () async {
    expect(
      () => controller.castMovie(
        const CastMedia.movie(url: 'http://provider/movie/u/p/9.mkv', title: 'Film'),
        device: _device,
      ),
      throwsA(isA<CastUnsupported>()),
    );
    expect(calls, isEmpty);
  });

  test('an MP4 film is proxied and loaded', () async {
    await controller.castMovie(
      const CastMedia.movie(url: 'http://provider/movie/u/p/9.mp4', title: 'Film'),
      device: _device,
    );
    bridge.session_.add(const CastSessionEvent(CastSessionState.connected));
    await pumpEventQueue();
    expect(calls, ['connect tv', 'tuneMovie mp4', 'load Film', 'keepAlive Film']);
  });

  test('a session left over from an earlier run is ended', () async {
    controller.bridge; // as the device picker does
    bridge.session_.add(const CastSessionEvent(CastSessionState.resumed));
    await pumpEventQueue();
    expect(calls, ['disconnect']);
    expect(controller.state.active, isFalse);
  });

  group('rules', () {
    test('film formats', () {
      expect(CastController.movieFormat('http://h/movie/u/p/1.mp4')?.mimeType, 'video/mp4');
      expect(CastController.movieFormat('http://h/movie/u/p/1.M4V')?.mimeType, 'video/mp4');
      expect(CastController.movieFormat('http://h/movie/u/p/1.webm')?.mimeType, 'video/webm');
      expect(CastController.movieFormat('http://h/movie/u/p/1.mkv'), isNull);
      expect(CastController.movieFormat('http://h/movie/u/p/1.avi'), isNull);
      expect(CastController.movieFormat('http://h/movie/u/p/1'), isNull);
      expect(CastController.unsupportedMovieMessage('http://h/1.mkv'), contains('MKV'));
    });

    test('codec failures', () {
      String? rule(String codec, {bool played = false, int errors = 1}) =>
          CastController.liveFailure(videoCodec: codec, playedBefore: played, errors: errors);
      expect(rule('MPEG-2'), contains('MPEG-2'));
      expect(rule('HEVC'), isNull);
      expect(rule('HEVC', errors: 2), contains('HEVC'));
      expect(rule('H.264', errors: 10), isNull);
      // Once it has played, the codec is not the problem.
      expect(rule('MPEG-2', played: true), isNull);
    });
  });
}
