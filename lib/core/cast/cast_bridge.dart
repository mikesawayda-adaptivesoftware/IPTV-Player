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

  bool get isError => state == ReceiverState.idle && idleReason == 'error';
}

/// The Cast session's state, as the Cast SDK reports it.
enum CastSessionState {
  connecting,
  connected,

  /// Picked back up by the SDK - typically a session left running when the
  /// app was killed. Whatever fed it is gone.
  resumed,

  /// The device went quiet (Wi-Fi dropped); the SDK is trying to rejoin.
  suspended,
  ended,
  failed,
}

class CastSessionEvent {
  final CastSessionState state;
  final String? device;
  final String? reason;

  const CastSessionEvent(this.state, {this.device, this.reason});
}

/// A film's playback position on the receiver.
class CastProgress {
  final Duration position;
  final Duration duration;

  const CastProgress(this.position, this.duration);
}

/// A button on the casting notification or the lock screen.
enum CastCommand { next, previous, play, pause, stop }

/// The Cast session, in Kotlin on top of Google's Cast SDK (`CastBridge.kt`).
///
/// Android phones only. The Cast SDK has no desktop build, and a TV is a cast
/// target rather than a sender.
class CastBridge {
  static const MethodChannel _channel =
      MethodChannel('com.adaptivesoftware.iptvplayer/cast');

  final _devices = StreamController<List<CastDevice>>.broadcast();
  final _session = StreamController<CastSessionEvent>.broadcast();
  final _receiver = StreamController<ReceiverStatus>.broadcast();
  final _commands = StreamController<CastCommand>.broadcast();
  final _volume = StreamController<double>.broadcast();
  final _progress = StreamController<CastProgress>.broadcast();

  /// Devices currently visible. Updated as they appear and disappear.
  Stream<List<CastDevice>> get devices => _devices.stream;

  Stream<CastSessionEvent> get session => _session.stream;

  Stream<ReceiverStatus> get receiver => _receiver.stream;

  /// Buttons pressed on the notification or lock screen. The listener owns
  /// what they do, so a Stop closes the provider connection before anything
  /// else.
  Stream<CastCommand> get commands => _commands.stream;

  /// The receiver's volume, 0 to 1, wherever it was changed.
  Stream<double> get volume => _volume.stream;

  /// Once a second while a film plays.
  Stream<CastProgress> get progress => _progress.stream;

  CastBridge() {
    _channel.setMethodCallHandler(_onCall);
  }

  Future<void> startDiscovery() => _channel.invokeMethod('startDiscovery');

  Future<void> stopDiscovery() => _channel.invokeMethod('stopDiscovery');

  Future<void> connect(String deviceId) =>
      _channel.invokeMethod('connect', {'id': deviceId});

  /// Hands the receiver an address to play. Throws if it refuses.
  ///
  /// Live streams are the relay's HLS; a film is passed through as it is, so
  /// it carries its own [contentType] and can start at [position].
  Future<void> load(
    String url, {
    required String title,
    bool live = true,
    String contentType = 'application/x-mpegURL',
    Duration position = Duration.zero,
  }) =>
      _channel.invokeMethod('load', {
        'url': url,
        'title': title,
        'live': live,
        'contentType': contentType,
        'position': position.inMilliseconds,
      });

  Future<void> play() => _channel.invokeMethod('play');

  Future<void> pause() => _channel.invokeMethod('pause');

  Future<void> seek(Duration position) =>
      _channel.invokeMethod('seek', {'position': position.inMilliseconds});

  Future<void> setVolume(double level) =>
      _channel.invokeMethod('setVolume', {'level': level});

  /// Stops playback and ends the session, closing the receiver app.
  Future<void> disconnect() => _channel.invokeMethod('disconnect');

  /// Keeps the phone relaying with the screen off, behind a notification that
  /// doubles as the lock-screen controls. Call again whenever [title] or
  /// [playing] changes; only the first call starts the service.
  Future<void> keepAlive({
    required String title,
    required String device,
    required bool live,
    bool playing = true,
  }) =>
      _channel.invokeMethod('keepAlive', {
        'title': title,
        'device': device,
        'live': live,
        'playing': playing,
      });

  Future<void> releaseKeepAlive() => _channel.invokeMethod('releaseKeepAlive');

  void dispose() {
    _channel.setMethodCallHandler(null);
    _commands.close();
    _volume.close();
    _progress.close();
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
        _session.add(sessionEventFrom(args as Map));
      case 'command':
        final command = CastCommand.values
            .where((c) => c.name == args)
            .firstOrNull;
        if (command != null) _commands.add(command);
      case 'volume':
        _volume.add((args as num).toDouble());
      case 'progress':
        final map = args as Map;
        _progress.add(CastProgress(
          Duration(milliseconds: (map['position'] as num? ?? 0).toInt()),
          Duration(milliseconds: (map['duration'] as num? ?? 0).toInt()),
        ));
      case 'receiver':
        final map = args as Map;
        _receiver.add(ReceiverStatus(
          _stateFrom(map['state'] as int? ?? 0),
          map['idleReason'] as String?,
        ));
    }
    return null;
  }

  static CastSessionEvent sessionEventFrom(Map map) {
    final raw = map['state'] as String? ?? '';
    final device = map['device'] as String?;
    if (raw.startsWith('failed')) {
      final reason = raw.contains(':') ? raw.substring(raw.indexOf(':') + 1).trim() : null;
      return CastSessionEvent(CastSessionState.failed, device: device, reason: reason);
    }
    final state = CastSessionState.values.where((s) => s.name == raw).firstOrNull ??
        CastSessionState.failed;
    return CastSessionEvent(state, device: device);
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
