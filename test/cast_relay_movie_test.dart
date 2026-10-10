import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/cast/cast_relay.dart';

/// A provider serving one film with Range support, slowly enough that a seek
/// overlaps the request before it, and counting its open connections.
///
/// Raw sockets rather than HttpServer, for the same reason as the live test:
/// the count must drop the moment the relay's hang-up arrives. HttpServer does
/// not read a socket while it is writing a response, so it went on counting a
/// closed connection as active for as long as its writes kept buffering.
class _FakeFilmServer {
  late final ServerSocket _server;
  final Uint8List film =
      Uint8List.fromList(List.generate(2 * 1024 * 1024, (i) => i & 0xFF));
  int active = 0;
  int maxActive = 0;
  final List<String?> ranges = [];

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  String get url => 'http://127.0.0.1:${_server.port}/movie/u/p/42.mp4';

  void _serve(Socket socket) {
    active++;
    maxActive = math.max(maxActive, active);
    var open = true;
    void hungUp() {
      if (!open) return;
      open = false;
      active--;
    }

    final header = StringBuffer();
    var started = false;
    socket.listen(
      (data) {
        if (started) return;
        header.write(String.fromCharCodes(data));
        if (header.toString().contains('\r\n\r\n')) {
          started = true;
          _respond(socket, header.toString(), () => open).whenComplete(() {
            hungUp();
            socket.destroy();
          });
        }
      },
      onDone: hungUp,
      onError: (_) => hungUp(),
    );
  }

  Future<void> _respond(Socket socket, String head, bool Function() open) async {
    final m = RegExp(r'^range: *bytes=(\d+)-(\d*)', caseSensitive: false, multiLine: true)
        .firstMatch(head);
    ranges.add(m == null ? null : 'bytes=${m.group(1)}-${m.group(2)}');
    var start = 0;
    var end = film.length - 1;
    final status = StringBuffer();
    if (m != null) {
      start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
      status
        ..write('HTTP/1.1 206 Partial Content\r\n')
        ..write('Content-Range: bytes $start-$end/${film.length}\r\n');
    } else {
      status.write('HTTP/1.1 200 OK\r\n');
    }
    status
      ..write('Content-Type: video/mp4\r\n')
      ..write('Content-Length: ${end - start + 1}\r\n')
      ..write('Accept-Ranges: bytes\r\nConnection: close\r\n\r\n');
    try {
      socket.write(status.toString());
      for (var o = start; o <= end && open(); o += 64 * 1024) {
        socket.add(Uint8List.sublistView(film, o, math.min(o + 64 * 1024, end + 1)));
        await socket.flush();
        await Future.delayed(const Duration(milliseconds: 20));
      }
    } catch (_) {
      // The relay hung up.
    }
  }

  Future<void> close() => _server.close();
}

Future<HttpClientResponse> _get(Uri uri, {String? range, HttpClient? client}) async {
  final c = client ?? HttpClient();
  final request = await c.getUrl(uri);
  if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
  return request.close();
}

void main() {
  late _FakeFilmServer provider;
  late CastRelay relay;

  setUp(() async {
    provider = _FakeFilmServer();
    await provider.start();
    relay = CastRelay(host: InternetAddress.loopbackIPv4);
  });

  tearDown(() async {
    await relay.dispose();
    await provider.close();
  });

  test('passes a range request through with CORS', () async {
    final uri = await relay.tuneMovie(provider.url, extension: 'mp4');
    expect(uri.path, endsWith('/movie.mp4'));

    final response = await _get(uri, range: 'bytes=1000-1999');
    expect(response.statusCode, HttpStatus.partialContent);
    expect(response.headers.value('access-control-allow-origin'), '*');
    expect(response.headers.value(HttpHeaders.contentRangeHeader),
        'bytes 1000-1999/${provider.film.length}');
    final body = await response.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(body, provider.film.sublist(1000, 2000));
    expect(provider.ranges, ['bytes=1000-1999']);
  });

  test('a seek replaces the request before it, one connection', () async {
    final uri = await relay.tuneMovie(provider.url, extension: 'mp4');

    // The whole film, slowly; then a seek while it is still arriving.
    final client = HttpClient();
    final first = await _get(uri, client: client);
    final firstBody = first.drain<void>().catchError((_) {});
    await Future.delayed(const Duration(milliseconds: 200));

    final seek = await _get(uri, range: 'bytes=1500000-');
    expect(seek.statusCode, HttpStatus.partialContent);
    final tail = await seek.fold<List<int>>([], (a, b) => a..addAll(b));
    expect(tail.length, provider.film.length - 1500000);
    await firstBody;
    client.close(force: true);

    expect(provider.maxActive, 1);
    expect(relay.providerConnections, 0);
  });

  test('switching back to live hangs up on the film', () async {
    final uri = await relay.tuneMovie(provider.url, extension: 'mp4');
    final client = HttpClient();
    final response = await _get(uri, client: client);
    final body = response.drain<void>().catchError((_) {});
    await Future.delayed(const Duration(milliseconds: 100));
    expect(relay.providerConnections, 1);

    await relay.stop();
    await body;
    client.close(force: true);
    expect(relay.providerConnections, 0);
  });
}
