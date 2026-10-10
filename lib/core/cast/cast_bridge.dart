import 'dart:async';

import 'package:flutter/services.dart';

/// A Chromecast found on the network.
class CastDevice {
  final String id;
  final String name;
  final String? description;

  const CastDevice({required this.id, required this.name, this.description});
}

/// What the receiver's own player reports.
enum ReceiverState { unknown, idle, loading, buffering, playing, paused }

class ReceiverStatus {
  final ReceiverState state;

  /// Set when [state] is idle: why playback stopped, e.g. `error`.
  final String? idleReason;

  const ReceiverStatus(this.state, [this.idleReason]);
}

/// The Cast session, in Kotlin on top of Google's Cast SDK (`CastBridge.kt`).
///
/// Android phones only. The Cast SDK has no desktop build, and a TV is a cast
/// target rather than a sender.
class CastBridge {
  static const MethodChannel _channel =
      MethodChannel('com.adaptivesoftware.iptvplayer/cast');

  final _devices = StreamController<List<CastDevice>>.broadcast();
  final _session = StreamController<String>.broadcast();
  final _receiver = StreamController<ReceiverStatus>.broadcast();
  final _stopRequested = StreamController<void>.broadcast();

  /// Devices currently visible. Updated as they appear and disappear.
  Stream<List<CastDevice>> get devices => _devices.stream;

  /// `connecting`, `connected`, `ended` or `failed: <reason>`.
  Stream<String> get session => _session.stream;

  Stream<ReceiverStatus> get receiver => _receiver.stream;

  /// The notification's Stop was tapped. The listener owns the teardown, so
  /// the provider connection can be closed before anything else.
  Stream<void> get stopRequested => _stopRequested.stream;

  CastBridge() {
    _channel.setMethodCallHandler(_onCall);
  }

  Future<void> startDiscovery() => _channel.invokeMethod('startDiscovery');

  Future<void> stopDiscovery() => _channel.invokeMethod('stopDiscovery');

  Future<void> connect(String deviceId) =>
      _channel.invokeMethod('connect', {'id': deviceId});

  /// Hands the receiver an HLS address to play. Throws if it refuses.
  Future<void> load(String url, {required String title, bool live = true}) =>
      _channel.invokeMethod('load', {'url': url, 'title': title, 'live': live});

  /// Stops playback and ends the session, closing the receiver app.
  Future<void> disconnect() => _channel.invokeMethod('disconnect');

  /// Keeps the phone relaying with the screen off, behind a "Casting to"
  /// notification. Call again on a channel change to update its text.
  Future<void> keepAlive({required String title, required String device}) =>
      _channel.invokeMethod('keepAlive', {'title': title, 'device': device});

  Future<void> releaseKeepAlive() => _channel.invokeMethod('releaseKeepAlive');

  void dispose() {
    _channel.setMethodCallHandler(null);
    _stopRequested.close();
    _devices.close();
    _session.close();
    _receiver.close();
  }

  Future<dynamic> _onCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'devices':
        final list = (args as List)
            .cast<Map>()
            .map((d) => CastDevice(
                  id: d['id'] as String,
                  name: d['name'] as String,
                  description: d['description'] as String?,
                ))
            .toList();
        _devices.add(list);
      case 'session':
        _session.add(args as String);
      case 'stopRequested':
        _stopRequested.add(null);
      case 'receiver':
        final map = args as Map;
        _receiver.add(ReceiverStatus(
          _stateFrom(map['state'] as int? ?? 0),
          map['idleReason'] as String?,
        ));
    }
    return null;
  }

  /// MediaStatus.PLAYER_STATE_* values.
  static ReceiverState _stateFrom(int value) {
    switch (value) {
      case 1:
        return ReceiverState.idle;
      case 2:
        return ReceiverState.playing;
      case 3:
        return ReceiverState.paused;
      case 4:
        return ReceiverState.buffering;
      case 5:
        return ReceiverState.loading;
      default:
        return ReceiverState.unknown;
    }
  }
}
