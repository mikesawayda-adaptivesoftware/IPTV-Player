import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../player/stream_tuning.dart';
import 'ts_segmenter.dart';

/// What the relay is doing, for the cast test screen. Never carries a URL:
/// the provider's carries the subscription credentials.
class RelayStats {
  final bool connected;
  final int providerConnections;
  final int bytesIn;
  final double kbpsIn;
  final int segments;
  final double? lastSegmentSeconds;
  final double? keyframeInterval;
  final int forcedCuts;
  final int resyncs;
  final int reconnects;
  final String? lastError;
  final TsStreamInfo info;
  final int playlistRequests;
  final int segmentRequests;
  final DateTime? lastReceiverRequest;

  const RelayStats({
    required this.connected,
    required this.providerConnections,
    required this.bytesIn,
    required this.kbpsIn,
    required this.segments,
    required this.lastSegmentSeconds,
    required this.keyframeInterval,
    required this.forcedCuts,
    required this.resyncs,
    required this.reconnects,
    required this.lastError,
    required this.info,
    required this.playlistRequests,
    required this.segmentRequests,
    required this.lastReceiverRequest,
  });
}

/// Holds the one provider connection and serves it to a Chromecast as HLS.
///
/// The provider only ever sees this phone, which is the point: a one-stream
/// subscription counts casting as the same single stream. To keep it that way
/// the old connection is always closed before a new one opens, on a channel
/// change and on a reconnect alike.
///
/// Every tune gets a fresh path (`/<token>/<generation>/live.m3u8`) so the
/// receiver can never be served the previous channel's segments from a cache,
/// and the token keeps other devices on the network from finding the stream.
class CastRelay {
  /// Overrides the advertised address; tests use loopback.
  final InternetAddress? host;

  /// Seconds with no bytes before the provider connection is treated as dead.
  final Duration stallTimeout;

  /// Pause between hanging up on one channel and dialling the next. The
  /// provider has to see the old connection close before the new one arrives,
  /// or a one-stream subscription refuses it; the close and the next connect
  /// otherwise race each other on the provider's side.
  final Duration handoverDelay;

  CastRelay({
    this.host,
    this.stallTimeout = const Duration(seconds: 10),
    this.handoverDelay = const Duration(milliseconds: 300),
  });

  HttpServer? _server;
  InternetAddress? _address;
  final String _token = _randomToken();

  String? _sourceUrl;
  int _generation = 0;
  TsSegmenter _segmenter = TsSegmenter();

  HttpClient? _client;
  StreamSubscription<List<int>>? _subscription;
  Timer? _stallTimer;
  bool _connected = false;
  bool _stopped = true;

  /// How many provider connections are open right now. The test asserts it
  /// never exceeds one; the screen shows it so a person can see that too.
  int get providerConnections => _openConnections;
  int _openConnections = 0;

  int _reconnects = 0;
  String? _lastError;
  int _playlistRequests = 0;
  int _segmentRequests = 0;
  DateTime? _lastReceiverRequest;

  // Rolling inbound rate.
  int _rateBytes = 0;
  DateTime _rateStart = DateTime.now();
  double _kbps = 0;

  final StreamController<void> _changes = StreamController.broadcast();

  /// Fires whenever [stats] may have changed.
  Stream<void> get changes => _changes.stream;

  RelayStats get stats {
    final segments = _segmenter.segments;
    return RelayStats(
      connected: _connected,
      providerConnections: _openConnections,
      bytesIn: _segmenter.bytesIn,
      kbpsIn: _kbps,
      segments: segments.length,
      lastSegmentSeconds: segments.isEmpty ? null : segments.last.duration,
      keyframeInterval: _segmenter.keyframeInterval,
      forcedCuts: _segmenter.forcedCuts,
      resyncs: _segmenter.resyncs,
      reconnects: _reconnects,
      lastError: _lastError,
      info: _segmenter.info,
      playlistRequests: _playlistRequests,
      segmentRequests: _segmentRequests,
      lastReceiverRequest: _lastReceiverRequest,
    );
  }

  /// Starts the local server. Safe to call more than once.
  Future<void> start() async {
    if (_server != null) return;
    _address = host ?? await _wifiAddress();
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen(_handle, onError: (Object e) => print('Cast relay server: $e'));
    _server = server;
  }

  /// Switches the relay to [sourceUrl] and returns the address to hand the
  /// Chromecast. The previous provider connection is closed first.
  Future<Uri> tune(String sourceUrl) async {
    await start();
    _stopped = false;
    final generation = ++_generation;
    if (await _closeProvider()) await Future.delayed(handoverDelay);
    // A quicker channel press arrived during the handover; it owns the relay.
    if (generation != _generation) return playlistUri;
    _sourceUrl = sourceUrl;
    _segmenter = TsSegmenter();
    _reconnects = 0;
    _lastError = null;
    _playlistRequests = 0;
    _segmentRequests = 0;
    _connect(generation);
    return playlistUri;
  }

  Uri get playlistUri => Uri(
        scheme: 'http',
        host: _address!.address,
        port: _server!.port,
        path: '/$_token/$_generation/live.m3u8',
      );

  /// Closes the provider connection and the server.
  Future<void> stop() async {
    _stopped = true;
    _generation++;
    await _closeProvider();
    await _server?.close(force: true);
    _server = null;
    _changed();
  }

  Future<void> dispose() async {
    await stop();
    await _changes.close();
  }

  // ==========================================================================
  // Provider side
  // ==========================================================================

  Future<void> _connect(int generation) async {
    if (_stopped || generation != _generation) return;
    final url = _sourceUrl;
    if (url == null) return;

    final client = HttpClient()
      ..userAgent = StreamTuning.userAgent
      ..connectionTimeout = const Duration(seconds: 10);
    _client = client;
    _openConnections++;
    _changed();

    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();
      if (generation != _generation) {
        await _closeClient(client);
        return;
      }
      if (response.statusCode != HttpStatus.ok) {
        _lastError = 'Provider answered HTTP ${response.statusCode}';
        await response.drain<void>().catchError((_) {});
        await _closeClient(client);
        _retry(generation);
        return;
      }
      _connected = true;
      _lastError = null;
      _armStallTimer(generation);
      _subscription = response.listen(
        (chunk) {
          _segmenter.add(chunk);
          _noteBytes(chunk.length);
          _armStallTimer(generation);
        },
        onError: (Object e) {
          _lastError = 'Connection error';
          print('Cast relay: provider stream error '
              '${StreamTuning.redactUrl(e.toString())}');
          _dropAndRetry(generation, client);
        },
        onDone: () {
          _lastError = 'Provider closed the stream';
          _dropAndRetry(generation, client);
        },
        cancelOnError: true,
      );
    } catch (e) {
      // Socket exceptions can embed the URL, credentials and all.
      print('Cast relay: connect failed ${StreamTuning.redactUrl(e.toString())}');
      _lastError = 'Could not connect to the provider';
      await _closeClient(client);
      _retry(generation);
    }
  }

  void _armStallTimer(int generation) {
    _stallTimer?.cancel();
    _stallTimer = Timer(stallTimeout, () {
      final client = _client;
      if (client == null || generation != _generation) return;
      _lastError = 'Provider stopped sending';
      _dropAndRetry(generation, client);
    });
  }

  Future<void> _dropAndRetry(int generation, HttpClient client) async {
    if (generation != _generation) return;
    _stallTimer?.cancel();
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    await _closeClient(client);
    _retry(generation);
  }

  void _retry(int generation) {
    if (_stopped || generation != _generation) return;
    _connected = false;
    _reconnects++;
    _segmenter.markDiscontinuity();
    _changed();
    // Backs off to five seconds. Some providers hold a closed connection's slot
    // briefly and refuse the next one, which a fast retry would only repeat.
    final delay = Duration(milliseconds: math.min(5000, 1000 * _reconnects));
    Timer(delay, () => _connect(generation));
  }

  /// Returns whether a connection was open.
  Future<bool> _closeProvider() async {
    _stallTimer?.cancel();
    _stallTimer = null;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final client = _client;
    if (client != null) await _closeClient(client);
    _connected = false;
    return client != null;
  }

  Future<void> _closeClient(HttpClient client) async {
    if (!identical(client, _client)) return;
    _client = null;
    client.close(force: true);
    _openConnections--;
    _changed();
  }

  void _noteBytes(int count) {
    _rateBytes += count;
    final now = DateTime.now();
    final elapsed = now.difference(_rateStart).inMilliseconds;
    if (elapsed >= 2000) {
      _kbps = _rateBytes * 8 / elapsed;
      _rateBytes = 0;
      _rateStart = now;
      _changed();
    }
  }

  // ==========================================================================
  // Receiver side
  // ==========================================================================

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      ..set('Access-Control-Allow-Headers', '*');

    try {
      if (request.method == 'OPTIONS') {
        response.statusCode = HttpStatus.noContent;
        return;
      }

      final parts = request.uri.pathSegments;
      if (parts.length != 3 ||
          parts[0] != _token ||
          parts[1] != '$_generation') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      _lastReceiverRequest = DateTime.now();

      final name = parts[2];
      if (name == 'live.m3u8') {
        _playlistRequests++;
        _changed();
        await _servePlaylist(response, _generation);
        return;
      }

      final match = RegExp(r'^seg(\d+)\.ts$').firstMatch(name);
      final segment =
          match == null ? null : _segmenter.segment(int.parse(match.group(1)!));
      if (segment == null) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      _segmentRequests++;
      _changed();
      response.headers
        ..contentType = ContentType('video', 'mp2t')
        ..contentLength = segment.bytes.length;
      if (request.method != 'HEAD') response.add(segment.bytes);
    } catch (e) {
      print('Cast relay: request failed $e');
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      await response.close().catchError((_) {});
    }
  }

  /// Holds the first request until there is something to play: an empty live
  /// playlist reads to a receiver as a stream that has ended.
  Future<void> _servePlaylist(HttpResponse response, int generation) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (_segmenter.segments.length < 2 && DateTime.now().isBefore(deadline)) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (generation != _generation) break;
    }
    if (generation != _generation || _segmenter.segments.isEmpty) {
      response.statusCode = HttpStatus.serviceUnavailable;
      return;
    }
    final body = _segmenter.playlist((seq) => 'seg$seq.ts');
    response.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    response.write(body);
  }

  void _changed() {
    if (!_changes.isClosed) _changes.add(null);
  }

  static String _randomToken() {
    final random = math.Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(20, (_) => chars[random.nextInt(chars.length)]).join();
  }

  /// The phone's address on the home network, which is what the Chromecast
  /// has to reach. Prefers the Wi-Fi interface over mobile data.
  static Future<InternetAddress> _wifiAddress() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    bool isPrivate(InternetAddress a) {
      final b = a.rawAddress;
      return b[0] == 10 ||
          (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
          (b[0] == 192 && b[1] == 168);
    }

    for (final i in interfaces) {
      if (!i.name.startsWith('wlan')) continue;
      for (final a in i.addresses) {
        if (isPrivate(a)) return a;
      }
    }
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (isPrivate(a)) return a;
      }
    }
    throw const SocketException(
        'No Wi-Fi address found. The phone must be on the same Wi-Fi as the Chromecast.');
  }
}
