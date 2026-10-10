import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/cast/cast_relay.dart';

import 'ts_fixture.dart';

/// A provider that streams endless synthetic TS, faster than real time, and
/// counts its open connections from the socket's point of view - which is
/// what a one-stream subscription actually limits.
class _FakeProvider {
  late final ServerSocket _server;
  int active = 0;
  int maxActive = 0;
  int accepted = 0;

  /// Close each connection after this many bytes, to force reconnects.
  int? dropAfterBytes;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  String url(String name) => 'http://127.0.0.1:${_server.port}/live/u/p/$name.ts';

  Future<void> _serve(Socket socket) async {
    accepted++;
    active++;
    maxActive = math.max(maxActive, active);
    // Counted down the moment the relay's hang-up arrives, not when this loop
    // next notices, so the count is what a provider would see.
    var open = true;
    void hungUp() {
      if (!open) return;
      open = false;
      active--;
    }

    socket.listen((_) {}, onDone: hungUp, onError: (_) => hungUp());
    final done = socket.done.then((_) {}, onError: (_) {});

    try {
      socket.write('HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\n'
          'Connection: close\r\n\r\n');
      final fixture = TsFixture();
      var sent = 0;
      while (open) {
        final chunk = fixture.seconds(0.5);
        socket.add(chunk);
        sent += chunk.length;
        await socket.flush();
        if (dropAfterBytes != null && sent >= dropAfterBytes!) break;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } catch (_) {
      // The relay hung up.
    } finally {
      hungUp();
      socket.destroy();
      await done;
    }
  }

  Future<void> close() => _server.close();
}

Future<HttpClientResponse> _get(Uri uri) async {
  final client = HttpClient();
  final request = await client.getUrl(uri);
  final response = await request.close();
  client.close();
  return response;
}

void main() {
  late _FakeProvider provider;
  late CastRelay relay;

  setUp(() async {
    provider = _FakeProvider();
    await provider.start();
    relay = CastRelay(host: InternetAddress.loopbackIPv4);
  });

  tearDown(() async {
    await relay.dispose();
    await provider.close();
  });

  test('serves the provider stream as HLS with CORS', () async {
    final playlistUri = await relay.tune(provider.url('1'));

    final response = await _get(playlistUri);
    expect(response.statusCode, 200);
    expect(response.headers.value('access-control-allow-origin'), '*');
    expect(response.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    final playlist = await response.transform(utf8.decoder).join();
    expect(playlist, startsWith('#EXTM3U'));

    final first = RegExp(r'^seg\d+\.ts$', multiLine: true).firstMatch(playlist)!;
    final segment = await _get(playlistUri.resolve(first.group(0)!));
    expect(segment.statusCode, 200);
    expect(segment.headers.contentType?.mimeType, 'video/mp2t');
    final bytes = await segment.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(bytes.length % 188, 0);
    expect(bytes.first, 0x47);

    expect(relay.stats.info.videoName, 'H.264');
    expect(relay.stats.playlistRequests, 1);
    expect(relay.stats.segmentRequests, 1);
  });

  test('never holds two provider connections across channel changes', () async {
    var maxSeen = 0;
    final sub = relay.changes.listen((_) {
      maxSeen = math.max(maxSeen, relay.providerConnections);
    });

    for (var i = 0; i < 5; i++) {
      await relay.tune(provider.url('$i'));
      await Future.delayed(const Duration(milliseconds: 150));
    }
    await relay.stop();
    await Future.delayed(const Duration(milliseconds: 200));
    await sub.cancel();

    expect(provider.accepted, 5);
    expect(maxSeen, 1);
    expect(provider.maxActive, 1);
    expect(provider.active, 0, reason: 'stop() hangs up on the provider');
  });

  test('rapid channel presses end on the last channel, one connection', () async {
    await relay.tune(provider.url('0'));
    await Future.delayed(const Duration(milliseconds: 150));
    final presses = [
      relay.tune(provider.url('1')),
      relay.tune(provider.url('2')),
      relay.tune(provider.url('3')),
    ];
    final uris = await Future.wait(presses);
    expect(uris.toSet().length, 1, reason: 'all report the newest address');

    final response = await _get(uris.last);
    expect(response.statusCode, 200);
    expect(provider.maxActive, 1);
    expect(provider.accepted, 2, reason: 'the skipped channels never dial');
  });

  test('an old channel\'s address stops working after a change', () async {
    final first = await relay.tune(provider.url('a'));
    final second = await relay.tune(provider.url('b'));
    expect(second, isNot(first));
    expect((await _get(first)).statusCode, 404);
    expect((await _get(second)).statusCode, 200);
  });

  test('rejects requests without the token', () async {
    final uri = await relay.tune(provider.url('a'));
    final wrong = uri.replace(path: '/nottoken/1/live.m3u8');
    expect((await _get(wrong)).statusCode, 404);
  });

  test('reconnects after a drop and marks the break', () async {
    provider.dropAfterBytes = 400 * 1024;
    final uri = await relay.tune(provider.url('a'));
    await _get(uri);

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (relay.stats.reconnects < 1 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    // Let the second connection produce segments.
    await Future.delayed(const Duration(milliseconds: 1500));
    expect(relay.stats.reconnects, greaterThanOrEqualTo(1));
    expect(provider.maxActive, 1);

    final playlist =
        await (await _get(uri)).transform(utf8.decoder).join();
    expect(playlist, contains('#EXT-X-DISCONTINUITY'));
  });
}
