import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/channel.dart';
import '../player/stream_tuning.dart';
import 'cast_bridge.dart';
import 'cast_relay.dart';

/// Something on the Chromecast: a live channel, or a film.
class CastMedia {
  /// Set for live TV; next and previous step through the channel list.
  final Channel? channel;
  final String url;
  final String title;
  final String? artwork;

  const CastMedia.live(Channel this.channel)
      : url = '',
        title = '',
        artwork = null;

  const CastMedia.movie({required this.url, required this.title, this.artwork})
      : channel = null;

  bool get live => channel != null;
  String get displayTitle => channel?.name ?? title;
  String get streamUrl => channel?.streamUrl ?? url;
  String? get image => channel?.logoUrl ?? artwork;

  bool sameAs(CastMedia? other) =>
      other != null &&
      other.live == live &&
      (live ? other.channel!.id == channel!.id : other.url == url);
}

/// Thrown by [CastController.castMovie] for a format the receiver cannot play.
class CastUnsupported implements Exception {
  final String message;
  const CastUnsupported(this.message);
  @override
  String toString() => message;
}

enum CastPhase {
  idle,

  /// Joining a Chromecast.
  connecting,

  /// Joined, with nothing on it yet.
  connected,
  casting,
}

class CastState {
  final CastPhase phase;
  final String? device;
  final CastMedia? media;
  final ReceiverStatus receiver;

  /// 0 to 1.
  final double volume;
  final CastProgress? progress;

  /// The Chromecast dropped off Wi-Fi; the Cast SDK is trying to rejoin.
  final bool reconnecting;

  /// What went wrong, in words for the person casting.
  final String? error;

  /// The receiver cannot play [media] at all, so retrying is pointless and the
  /// only way to watch it is on the phone.
  final bool unsupported;

  /// The cast ended on its own - the Chromecast was switched off or lost
  /// Wi-Fi. Kept so the phone can offer to carry on with it.
  final CastMedia? lost;
  final Duration? lostPosition;

  const CastState({
    this.phase = CastPhase.idle,
    this.device,
    this.media,
    this.receiver = const ReceiverStatus(ReceiverState.unknown),
    this.volume = 0.5,
    this.progress,
    this.reconnecting = false,
    this.error,
    this.unsupported = false,
    this.lost,
    this.lostPosition,
  });

  /// Anything other than idle: a phone player must not open, and a tap on a
  /// channel casts it instead.
  bool get active => phase != CastPhase.idle;

  bool get playing => receiver.state == ReceiverState.playing;

  /// Like every state class here, [error] is not preserved: any change clears
  /// it unless it is passed again. Nor are [unsupported] and [lost], which
  /// describe one moment.
  CastState copyWith({
    CastPhase? phase,
    String? device,
    CastMedia? media,
    ReceiverStatus? receiver,
    double? volume,
    CastProgress? progress,
    bool clearProgress = false,
    bool? reconnecting,
    String? error,
    bool unsupported = false,
  }) {
    return CastState(
      phase: phase ?? this.phase,
      device: device ?? this.device,
      media: media ?? this.media,
      receiver: receiver ?? this.receiver,
      volume: volume ?? this.volume,
      progress: clearProgress ? null : progress ?? this.progress,
      reconnecting: reconnecting ?? this.reconnecting,
      error: error,
      unsupported: unsupported,
    );
  }
}

/// Owns the Cast session and the relay for the whole app, so a cast carries
/// on while the person browses, and every screen sees the same one.
///
/// The provider allows one stream, and this class is what keeps it to one:
/// a phone player calls [stop] before it opens, and the relay is always
/// stopped before the session is let go, so the receiver cannot ask a dead
/// relay for more and nothing on the phone can race it.
class CastController extends StateNotifier<CastState> {
  final CastBridge Function() _newBridge;
  final CastRelay Function() _newRelay;

  /// The channel before or after this one in the current list.
  final Channel? Function(Channel current, bool forward)? stepChannel;

  /// Records a cast channel in history, as the phone's player does.
  final void Function(Channel channel)? onWatched;

  /// Wait before handing an errored receiver the stream again.
  final Duration retryDelay;

  CastController({
    CastBridge Function()? bridge,
    CastRelay Function()? relay,
    this.stepChannel,
    this.onWatched,
    this.retryDelay = const Duration(seconds: 2),
  })  : _newBridge = bridge ?? CastBridge.new,
        _newRelay = relay ?? CastRelay.new,
        super(const CastState());

  CastBridge? _bridge;
  CastRelay? _relay;
  final List<StreamSubscription> _subscriptions = [];

  /// What to play once the session being joined is up.
  CastMedia? _pending;
  Duration _pendingPosition = Duration.zero;

  /// Bumped on every play and stop, so a slow load cannot land on top of a
  /// later one.
  int _generation = 0;
  bool _stopping = false;
  bool _playedSinceLoad = false;
  int _errorsSinceLoad = 0;
  Timer? _retryTimer;

  /// Lazily, because the Cast SDK is Android-only and the channel's other end
  /// does not exist anywhere else. Nothing touches it until someone casts.
  CastBridge get bridge {
    final existing = _bridge;
    if (existing != null) return existing;
    final created = _newBridge();
    _subscriptions
      ..add(created.session.listen(_onSession))
      ..add(created.receiver.listen(_onReceiver))
      ..add(created.commands.listen(_onCommand))
      ..add(created.volume.listen((v) {
        if (mounted && state.active) {
          state = state.copyWith(volume: v, error: state.error, unsupported: state.unsupported);
        }
      }))
      ..add(created.progress.listen((p) {
        if (mounted && state.active && state.media?.live == false) {
          state = state.copyWith(progress: p, error: state.error, unsupported: state.unsupported);
        }
      }));
    _bridge = created;
    return created;
  }

  CastRelay get _relayOrNew => _relay ??= _newRelay();

  Stream<List<CastDevice>> get devices => bridge.devices;

  Future<void> startDiscovery() => bridge.startDiscovery();

  Future<void> stopDiscovery() async {
    if (_bridge != null) await _bridge!.stopDiscovery();
  }

  Future<void> castChannel(Channel channel, {CastDevice? device}) =>
      cast(CastMedia.live(channel), device: device);

  /// Casts a film, from [position] when the phone was already part-way in.
  ///
  /// Throws [CastUnsupported] for a container the Chromecast cannot play,
  /// before anything is connected or any provider connection closed.
  Future<void> castMovie(
    CastMedia movie, {
    CastDevice? device,
    Duration position = Duration.zero,
  }) {
    if (movieFormat(movie.url) == null) {
      throw CastUnsupported(unsupportedMovieMessage(movie.url));
    }
    return cast(movie, device: device, position: position);
  }

  /// Plays [media] on the Chromecast, joining [device] first when no session
  /// is up. With one up, [device] is ignored.
  Future<void> cast(
    CastMedia media, {
    CastDevice? device,
    Duration position = Duration.zero,
  }) async {
    switch (state.phase) {
      case CastPhase.idle:
        if (device == null) {
          throw StateError('Pick a Chromecast first');
        }
        _pending = media;
        _pendingPosition = position;
        _stopping = false;
        state = CastState(
          phase: CastPhase.connecting,
          device: device.name,
          media: media,
          volume: state.volume,
        );
        try {
          await bridge.connect(device.id);
        } catch (e) {
          _pending = null;
          state = CastState(error: describe(e));
        }
      case CastPhase.connecting:
        _pending = media;
        _pendingPosition = position;
        state = state.copyWith(media: media);
      case CastPhase.connected:
      case CastPhase.casting:
        await _play(media, position: position);
    }
  }

  Future<void> _play(CastMedia media, {Duration position = Duration.zero}) async {
    final generation = ++_generation;
    _retryTimer?.cancel();
    _playedSinceLoad = false;
    _errorsSinceLoad = 0;
    state = state.copyWith(
      phase: CastPhase.casting,
      media: media,
      receiver: const ReceiverStatus(ReceiverState.loading),
      clearProgress: true,
    );
    final relay = _relayOrNew;
    try {
      if (media.live) {
        final url = await relay.tune(media.streamUrl);
        if (generation != _generation) return;
        await bridge.load(url.toString(), title: media.displayTitle);
        onWatched?.call(media.channel!);
      } else {
        final format = movieFormat(media.url)!;
        final url = await relay.tuneMovie(media.url, extension: format.extension);
        if (generation != _generation) return;
        await bridge.load(
          url.toString(),
          title: media.displayTitle,
          live: false,
          contentType: format.mimeType,
          position: position,
        );
      }
      if (generation != _generation) return;
      await _keepAlive();
    } catch (e) {
      if (generation != _generation || !mounted) return;
      state = state.copyWith(error: describe(e));
    }
  }

  Future<void> _keepAlive() async {
    final media = state.media;
    if (media == null) return;
    try {
      await bridge.keepAlive(
        title: media.displayTitle,
        device: state.device ?? 'Chromecast',
        live: media.live,
        playing: media.live || state.receiver.state != ReceiverState.paused,
      );
    } catch (e) {
      // The notification is a convenience; casting carries on without it.
      print('Cast: keep-alive failed ${describe(e)}');
    }
  }

  /// Next or previous channel, from the screen, the bar or the lock screen.
  Future<void> step(bool forward) async {
    final channel = state.media?.channel;
    if (channel == null || state.phase != CastPhase.casting) return;
    final next = stepChannel?.call(channel, forward);
    if (next != null) await _play(CastMedia.live(next));
  }

  Future<void> togglePause() async {
    if (state.media?.live != false) return;
    try {
      if (state.receiver.state == ReceiverState.paused) {
        await bridge.play();
      } else {
        await bridge.pause();
      }
    } catch (e) {
      state = state.copyWith(error: describe(e));
    }
  }

  Future<void> seek(Duration position) async {
    if (state.media?.live != false) return;
    final duration = state.progress?.duration ?? Duration.zero;
    state = state.copyWith(progress: CastProgress(position, duration));
    try {
      await bridge.seek(position);
    } catch (e) {
      state = state.copyWith(error: describe(e));
    }
  }

  Future<void> setVolume(double level) async {
    final clamped = level.clamp(0.0, 1.0);
    state = state.copyWith(volume: clamped, error: state.error, unsupported: state.unsupported);
    try {
      await bridge.setVolume(clamped);
    } catch (_) {
      // The session is going away; its own event says so.
    }
  }

  /// Ends the cast: the provider connection first, then the notification,
  /// then the session. Safe to call when idle, and what every phone player
  /// calls before it opens a stream.
  Future<void> stop() async {
    if (!state.active && _relay == null) return;
    _stopping = true;
    _pending = null;
    _generation++;
    _retryTimer?.cancel();
    await _relay?.stop();
    final bridge = _bridge;
    if (bridge != null) {
      try {
        await bridge.releaseKeepAlive();
      } catch (_) {}
      try {
        await bridge.disconnect();
      } catch (_) {}
    }
    if (mounted) state = CastState(volume: state.volume);
  }

  /// Clears a [CastState.lost] once the phone has offered it.
  void forgetLost() {
    if (state.lost != null) state = CastState(volume: state.volume);
  }

  // ==========================================================================
  // Events
  // ==========================================================================

  void _onSession(CastSessionEvent event) {
    if (!mounted) return;
    switch (event.state) {
      case CastSessionState.connecting:
        break;
      case CastSessionState.connected:
        if (state.phase == CastPhase.connecting) {
          final pending = _pending;
          _pending = null;
          state = state.copyWith(phase: CastPhase.connected, device: event.device);
          if (pending != null) _play(pending, position: _pendingPosition);
        } else if (state.reconnecting) {
          // Back after a Wi-Fi blip. The receiver may have given up on the
          // stream in the meantime; the relay never stopped, so handing it
          // the address again costs no provider connection.
          state = state.copyWith(reconnecting: false);
          _reload();
        }
      case CastSessionState.resumed:
        // A session the SDK kept from an earlier run of the app. Its relay
        // died with that run, so the receiver is showing a stream that will
        // never arrive; end it rather than leave the TV stuck.
        if (state.phase == CastPhase.idle) {
          bridge.disconnect().catchError((_) {});
        }
      case CastSessionState.suspended:
        if (state.active) state = state.copyWith(reconnecting: true);
      case CastSessionState.ended:
      case CastSessionState.failed:
        _onSessionGone(event);
    }
  }

  Future<void> _onSessionGone(CastSessionEvent event) async {
    if (_stopping || !state.active) {
      _stopping = false;
      return;
    }
    final media = state.media;
    final position = state.progress?.position;
    final joining = state.phase == CastPhase.connecting;
    _pending = null;
    _generation++;
    _retryTimer?.cancel();
    // Nothing is watching the relay any more.
    await _relay?.stop();
    try {
      await _bridge?.releaseKeepAlive();
    } catch (_) {}
    if (!mounted) return;
    state = CastState(
      volume: state.volume,
      error: joining
          ? "Couldn't connect to ${state.device ?? 'the Chromecast'}."
          : 'Lost the connection to ${state.device ?? 'the Chromecast'}.',
      lost: joining ? null : media,
      lostPosition: position,
    );
  }

  void _onReceiver(ReceiverStatus status) {
    if (!mounted || state.phase != CastPhase.casting) return;
    final media = state.media;
    if (media == null) return;

    if (status.state == ReceiverState.playing) {
      _playedSinceLoad = true;
      _errorsSinceLoad = 0;
      state = state.copyWith(receiver: status);
      // Pause and play change the lock-screen button.
      if (!media.live) _keepAlive();
      return;
    }

    final wasPaused = state.receiver.state == ReceiverState.paused;
    state = state.copyWith(
      receiver: status,
      error: state.error,
      unsupported: state.unsupported,
    );
    if (!media.live && (status.state == ReceiverState.paused) != wasPaused) {
      _keepAlive();
    }

    if (!media.live &&
        status.state == ReceiverState.idle &&
        status.idleReason == 'finished') {
      stop();
      return;
    }
    // A live playlist the receiver thinks has ended is as dead as an error.
    final failed = status.isError ||
        (media.live && status.state == ReceiverState.idle && status.idleReason == 'finished');
    if (failed) _onReceiverError(media);
  }

  /// Decides between retrying and saying the stream cannot be cast.
  ///
  /// A codec the receiver lacks fails the same way every time, and retrying
  /// it forever would leave the person watching a spinner with no reason
  /// given. Anything else is retried indefinitely while it is on screen, like
  /// the phone's own player: the relay keeps running, so a retry costs no
  /// provider connection.
  void _onReceiverError(CastMedia media) {
    _errorsSinceLoad++;
    final reason = media.live
        ? liveFailure(
            videoCodec: _relay?.stats.info.videoName,
            playedBefore: _playedSinceLoad,
            errors: _errorsSinceLoad,
          )
        : (_playedSinceLoad || _errorsSinceLoad < 2
            ? null
            : "The Chromecast couldn't play this film. It may be in a format the "
                'Chromecast does not support.');
    if (reason != null) {
      _retryTimer?.cancel();
      _generation++;
      // Nothing is going to play it; do not keep the provider's one stream.
      _relay?.stop();
      state = state.copyWith(error: reason, unsupported: true);
      return;
    }
    if (_errorsSinceLoad >= 3) {
      state = state.copyWith(
        error: 'The Chromecast is having trouble with this channel. Retrying...',
      );
    }
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive == true) return;
    final generation = _generation;
    _retryTimer = Timer(retryDelay, () {
      if (generation != _generation || state.phase != CastPhase.casting) return;
      _reload();
    });
  }

  /// Hands the receiver the current address again.
  Future<void> _reload() async {
    final media = state.media;
    final relay = _relay;
    if (media == null || relay == null || state.phase != CastPhase.casting) return;
    try {
      if (media.live) {
        await bridge.load(relay.playlistUri.toString(), title: media.displayTitle);
      } else {
        final format = movieFormat(media.url)!;
        await bridge.load(
          relay.movieUri.toString(),
          title: media.displayTitle,
          live: false,
          contentType: format.mimeType,
          position: state.progress?.position ?? Duration.zero,
        );
      }
    } catch (e) {
      if (mounted) state = state.copyWith(error: describe(e));
    }
  }

  void _onCommand(CastCommand command) {
    switch (command) {
      case CastCommand.next:
        step(true);
      case CastCommand.previous:
        step(false);
      case CastCommand.play:
      case CastCommand.pause:
        togglePause();
      case CastCommand.stop:
        stop();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _relay?.dispose();
    _bridge?.dispose();
    super.dispose();
  }

  // ==========================================================================
  // Rules
  // ==========================================================================

  /// Why a live channel cannot be cast, or null to keep retrying.
  ///
  /// MPEG-1/2 video is in no Chromecast's decoder, so the first failure is
  /// conclusive. HEVC is in some (Chromecast with Google TV, Ultra) and not
  /// others, so it is only blamed after it has failed twice without ever
  /// playing.
  static String? liveFailure({
    required String? videoCodec,
    required bool playedBefore,
    required int errors,
  }) {
    if (playedBefore) return null;
    if (videoCodec == 'MPEG-2' || videoCodec == 'MPEG-1') {
      return "This channel's video is $videoCodec, which a Chromecast can't play. "
          'Watch it on the phone, or try another version of the channel.';
    }
    if (videoCodec == 'HEVC' && errors >= 2) {
      return "This channel's video is HEVC, which this Chromecast can't play. "
          'Watch it on the phone, or try another version of the channel.';
    }
    return null;
  }

  /// The container of a film URL, or null when the receiver cannot play it.
  ///
  /// MP4 and WebM are what the Default Media Receiver plays. MKV, AVI and the
  /// rest are refused up front: some newer Chromecasts open MKV, most do not,
  /// and a cast that fails after the phone's player was closed is worse than
  /// one that was never offered.
  static ({String extension, String mimeType})? movieFormat(String url) {
    final ext = extensionOf(url);
    switch (ext) {
      case 'mp4':
      case 'm4v':
        return (extension: ext!, mimeType: 'video/mp4');
      case 'webm':
        return (extension: 'webm', mimeType: 'video/webm');
      default:
        return null;
    }
  }

  static String? extensionOf(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return null;
    return name.substring(dot + 1).toLowerCase();
  }

  static String unsupportedMovieMessage(String url) {
    final ext = extensionOf(url);
    final kind = ext == null ? 'This film' : 'This film is ${ext.toUpperCase()}, which';
    return ext == null
        ? "$kind is in a format a Chromecast can't play. Watch it on the phone instead."
        : "$kind a Chromecast can't play. Watch it on the phone instead.";
  }

  static String describe(Object e) {
    if (e is PlatformException) return e.message ?? e.code;
    if (e is CastUnsupported) return e.message;
    if (e is StateError) return e.message;
    // Socket errors can embed the provider URL, credentials and all.
    return StreamTuning.redactUrl(e.toString());
  }
}
