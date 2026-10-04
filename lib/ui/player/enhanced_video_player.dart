import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/constants/app_constants.dart';
import '../../core/player/quality_controller.dart';
import '../../core/player/stream_quality.dart';
import '../../core/player/stream_tuning.dart';
import '../../core/player/video_output.dart';
import '../../core/platform/tv_platform.dart';
import '../../core/player/stream_watchdog.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/channel.dart';
import '../../data/services/storage_service.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/tv_focusable.dart';

// BufferMode moved to core/player/stream_tuning.dart so the tuning layer can
// use it without depending on the UI. Re-exported here because the settings
// screen imports it from this file.
export '../../core/player/stream_tuning.dart' show BufferMode;
export '../../core/player/stream_quality.dart' show QualityPolicy;

/// Provider for buffer settings
final bufferModeProvider = StateProvider<BufferMode>((ref) {
  final storage = StorageService();
  final savedMode = storage.getSetting<int>('buffer_mode', defaultValue: 1);
  return BufferMode.values[savedMode ?? 1];
});

final autoReconnectProvider = StateProvider<bool>((ref) {
  final storage = StorageService();
  return storage.getSetting<bool>('auto_reconnect', defaultValue: true) ?? true;
});

/// Whether the player may lower quality on its own when the connection cannot
/// keep up. Same shape as [bufferModeProvider]: read straight from Hive here,
/// written at the settings call site.
final qualityPolicyProvider = StateProvider<QualityPolicy>((ref) {
  final storage = StorageService();
  final saved = storage.getSetting<int>(
    AppConstants.settingQualityPolicy,
    defaultValue: 0,
  );
  return QualityPolicy.values[saved ?? 0];
});

class EnhancedVideoPlayer extends ConsumerStatefulWidget {
  final Channel channel;
  final bool isLive;
  final VoidCallback? onClose;
  final VoidCallback? onMinimize;

  const EnhancedVideoPlayer({
    super.key,
    required this.channel,
    this.isLive = true,
    this.onClose,
    this.onMinimize,
  });

  @override
  ConsumerState<EnhancedVideoPlayer> createState() => _EnhancedVideoPlayerState();
}

class _EnhancedVideoPlayerState extends ConsumerState<EnhancedVideoPlayer>
    with WidgetsBindingObserver {
  // Nullable, and rebuilt from scratch by the watchdog's recreate step - a
  // wedged libmpv instance cannot be recovered any other way.
  Player? _player;
  VideoController? _controller;
  final List<StreamSubscription> _subscriptions = [];

  late StreamWatchdog _watchdog;
  late QualityController _quality;
  WatchdogStatus _watchdogStatus =
      const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');

  late Channel _currentChannel;

  /// Mutable because the watchdog may fall back to the provider's other stream
  /// format when the original will not play.
  late String _streamUrl;

  bool _isFullscreen = false;
  bool _showControls = true;
  bool _isLoading = true;
  bool _isBuffering = false;
  String? _errorMessage;
  Timer? _hideTimer;

  /// Drives the now/next banner shown after a channel change.
  Timer? _bannerTimer;
  bool _showChannelBanner = false;

  double _bufferHealth = 0.0;

  /// Extra inset for the player's floating overlays on TV.
  ///
  /// The player's Stack is deliberately full-bleed: the overscan injected into
  /// MediaQuery in app.dart is honoured by SafeArea, and the video itself must
  /// not be letterboxed. So anything positioned absolutely inside this Stack
  /// has to clear the overscan itself, or it lands in the strip a TV crops.
  static double get _overlayInset => kIsTv ? 48.0 : 0.0;

  /// Diagnostic overlay, toggled with `I`. Off by default, and its sampler only
  /// runs while it is on - it reads eight mpv properties a second, which is not
  /// something to do behind the user's back.
  bool _showStats = false;
  Timer? _statsTimer;
  _StreamStats? _stats;

  /// Settled measurement per quality played this session, so two qualities can
  /// be compared side by side rather than remembered. Keyed by option label.
  final Map<String, _StreamStats> _qualitySamples = {};

  /// Recent video-bitrate readings. Instantaneous bitrate swings with scene
  /// complexity, so a single reading cannot meaningfully be compared with
  /// another - the overlay reports the mean of these.
  final List<double> _bitrateWindow = [];

  final FocusNode _focusNode = FocusNode();

  /// The output the current player was built with. Starts from what this
  /// device last showed a picture on, and is stepped by [_checkPicture] when a
  /// stream plays sound with no video.
  VideoOutput _output = VideoOutput.effective;

  /// Fires once per open, a few seconds in, to confirm a picture appeared.
  Timer? _pictureTimer;

  /// Set when every output failed on one stream. That stream's video is
  /// probably the problem, not the output, so the next channel goes back to
  /// the output that last worked rather than staying on the last resort.
  bool _rebuildOnNextChannel = false;

  @override
  void initState() {
    super.initState();
    _currentChannel = widget.channel;
    _streamUrl = widget.channel.streamUrl;

    // Go immersive the moment the player opens: hide the phone's status bar and
    // navigation buttons so video is truly full-screen. Restored in dispose.
    // No-op on desktop. immersiveSticky keeps the bars hidden but lets a user
    // swipe from an edge to reveal them briefly.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    // media_kit draws into a Flutter Texture rather than a SurfaceView, so
    // Android cannot tell that video is on screen and the TV's screensaver
    // fires mid-programme. Nothing else in the app takes a wakelock.
    WidgetsBinding.instance.addObserver(this);
    TvPlatform.acquireKeepScreenOn();

    // Constructed before the watchdog because the watchdog's quality callbacks
    // point at it; its own watchdogRef is a closure, so the cycle is fine.
    _quality = QualityController(
      playerRef: () => _player,
      watchdogRef: () => _watchdog,
      onApply: _applyQuality,
      autoEnabled: _autoQualityEnabled,
      onChanged: () {
        if (mounted) setState(() {});
      },
    );

    _watchdog = StreamWatchdog(
      playerRef: () => _player,
      urlRef: () => _streamUrl,
      enabled: () => ref.read(autoReconnectProvider),
      isLive: widget.isLive,
      onRecreate: _recreatePlayer,
      onOpen: _openUrl,
      onUrlChanged: (url) => _streamUrl = url,
      canDegradeQuality: () => _autoQualityEnabled() && _quality.canDegrade,
      onDegradeQuality: _quality.degrade,
      // The primary trigger. Congestion is detected while the stream is still
      // playing, so quality drops in about ten seconds rather than after the
      // whole repair ladder has failed.
      onCongested: _quality.degrade,
      reconnectHint: kIsTv
          ? 'Stream frozen - press OK to reconnect'
          : 'Stream frozen - tap to reconnect',
      onStatus: _onWatchdogStatus,
    );

    _bootstrap();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(channelStateProvider.notifier).markAsWatched(_currentChannel);
    });
  }

  /// Stops playback when the app leaves the foreground.
  ///
  /// Without this, pressing Home on a TV leaves audio playing from a
  /// backgrounded app with no way to stop it short of killing the process.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _player?.pause();
    }
  }

  Future<void> _bootstrap() async {
    await _createPlayer();
    _refreshQualityOptions();
    await _openUrl(_streamUrl);
    _watchdog.start();
    _quality.start();
    _startHideTimer();
  }

  /// Whether the automatic quality path may act.
  ///
  /// Auto-reconnect off means "do not change playback behind my back", which
  /// covers this too.
  bool _autoQualityEnabled() {
    return ref.read(qualityPolicyProvider) == QualityPolicy.auto &&
        ref.read(autoReconnectProvider);
  }

  /// Rebuilds the quality ladder for whatever channel is now current.
  void _refreshQualityOptions() {
    _quality.setOptions(
      ref.read(channelStateProvider).qualityIndex.optionsFor(
            channelId: _currentChannel.id,
            sourceLabel: _currentChannel.name,
            currentUrl: _currentChannel.streamUrl,
          ),
    );
  }

  // ==========================================================================
  // Player lifecycle
  // ==========================================================================

  Future<void> _createPlayer() async {
    try {
      final player = Player(
        configuration: const PlayerConfiguration(
          bufferSize: 64 * 1024 * 1024,
        ),
      );

      final controller = VideoController(
        player,
        // Software rendering on Linux only, where GPU textures crash on some
        // drivers. On Android, one of several outputs - see VideoOutput.
        configuration: _output.configuration,
      );

      // Publish to the widget tree FIRST. The VideoController only finishes
      // initialising once a Video widget mounts, and setProperty waits on that
      // - tuning before the first build deadlocks until every property times
      // out, which made each recovery ~30s slower.
      _player = player;
      _controller = controller;
      _attachListeners(player);
      if (mounted) setState(() {});

      // Still before open(): the FFmpeg demuxer options are read at open time.
      await _applyTuning(player);
    } catch (e, stackTrace) {
      print('Error creating player: $e');
      print('Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _errorMessage = 'Failed to initialize player: $e';
          _isLoading = false;
        });
      }
    }
  }

  /// The one place mpv tuning is applied, so buffer mode and quality can never
  /// overwrite one another.
  ///
  /// The buffer-mode listener in [build] used to call [StreamTuning.apply]
  /// directly with only the mode, which meant changing buffer mode while in
  /// audio-only silently switched video back on and put the bandwidth straight
  /// back.
  Future<void> _applyTuning(Player player, {BufferMode? mode}) {
    final option = _quality.current;
    return StreamTuning.apply(
      player,
      mode: mode ?? ref.read(bufferModeProvider),
      isLive: widget.isLive,
      hlsBitrate: option?.hlsBitrate ?? 'max',
      videoDisabled: option?.videoDisabled ?? false,
    );
  }

  /// [QualityApply] for [QualityController].
  Future<void> _applyQuality(
    QualityOption option, {
    required bool userInitiated,
  }) async {
    final player = _player;
    if (player == null) return;

    // `hls-bitrate` and `vid` are read when the stream is opened, so the tuning
    // has to be re-applied before the open, not after it.
    await _applyTuning(player);
    _resetStatsWindow();
    await _openUrl(option.url, userInitiated: userInitiated);
  }

  void _attachListeners(Player player) {
    void listen<T>(Stream<T> stream, void Function(T) onData) {
      _subscriptions.add(stream.listen(onData));
    }

    listen(player.stream.playing, (_) {
      if (mounted) setState(() {});
    });

    // The mute icon reads player.state.volume, which is a snapshot - setVolume
    // alone rebuilds nothing, so the icon only caught up when an unrelated
    // setState fired (a tap, or the controls auto-hiding). Volume is a stream
    // for the same reason `playing` is.
    listen(player.stream.volume, (_) {
      if (mounted) setState(() {});
    });

    listen(player.stream.buffering, (buffering) {
      if (!mounted) return;
      setState(() {
        _isBuffering = buffering;
        _isLoading = buffering && player.state.position == Duration.zero;
      });
    });

    listen(player.stream.buffer, (_) => _updateBufferHealth());

    listen(player.stream.error, (error) {
      if (!mounted || error.isEmpty) return;
      _handlePlaybackError(error);
    });
  }

  Future<void> _cancelSubscriptions() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
  }

  /// Tears the player down completely and builds a new one. This is the
  /// recovery step that actually clears a wedged libmpv/FFmpeg state, which no
  /// amount of re-opening the same stream will fix.
  Future<void> _recreatePlayer(String url) async {
    final old = _player;

    await _cancelSubscriptions();

    // Drop the Video widget before disposing, so it never holds a controller
    // whose player is going away.
    _player = null;
    _controller = null;
    if (mounted) setState(() => _isLoading = true);
    await Future.delayed(const Duration(milliseconds: 100));

    try {
      await old?.dispose();
    } catch (e) {
      print('Error disposing player during recreate: $e');
    }

    await _createPlayer();
    await _openUrl(url);
  }

  Future<void> _openUrl(String url, {bool userInitiated = false}) async {
    final player = _player;
    if (player == null) return;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      // _currentChannel stays the channel the user chose even while a lower
      // quality is playing, so log the quality alongside it - otherwise a
      // sibling switch prints the source's name and looks like nothing
      // happened. Never log the URL itself; it carries the subscription
      // credentials.
      final quality = _quality.current;
      final via = quality == null || quality.isSource ? '' : ' [${quality.label}]';
      print('Opening stream: ${_currentChannel.name}$via');
      await player.open(Media(url));
      // Whatever is actually playing, including a quality sibling or an
      // alternate container, so the watchdog reads the right URL.
      _streamUrl = url;
      _watchdog.noteStreamOpened(userInitiated: userInitiated);
      _schedulePictureCheck();
    } catch (e) {
      // Exception text from mpv/Dio routinely embeds the full stream URL.
      print('Error opening stream: ${StreamTuning.redactUrl(e.toString())}');
      _handlePlaybackError(e.toString());
    }
  }

  // ==========================================================================
  // Picture check
  // ==========================================================================

  /// How long after an open a picture must have appeared. Generous, because a
  /// false positive costs a player rebuild on a stream that was about to work.
  static const _pictureGrace = Duration(seconds: 8);

  void _schedulePictureCheck() {
    _pictureTimer?.cancel();
    if (!VideoOutput.isConfigurable) return;
    final player = _player;
    _pictureTimer = Timer(_pictureGrace, () => _checkPicture(player));
  }

  /// Catches "sound but no picture", which the watchdog cannot: the playhead
  /// moves, so as far as it is concerned the stream is healthy.
  ///
  /// When mpv cannot bring its video output up it deselects the video track
  /// and keeps playing audio, with no error event. So the signal is a stream
  /// that has a video track while mpv has no configured video output. The fix
  /// is a different output, and outputs are fixed when the VideoController is
  /// built, so this rebuilds the player on the next one in line.
  Future<void> _checkPicture(Player? player) async {
    if (!mounted || player == null || !identical(player, _player)) return;
    // Audio-only is the user's choice, and a stalled stream is the
    // watchdog's - neither says anything about the output.
    if (_quality.current?.videoDisabled ?? false) return;
    if (!_watchdogStatus.isHealthy || !player.state.playing) return;

    // Radio channels and audio-only feeds carry no video track at all.
    final hasVideo = player.state.tracks.video
        .any((track) => track.id != 'auto' && track.id != 'no');
    if (!hasVideo) return;

    final reads = await Future.wait([
      StreamTuning.readProperty(player, 'vid'),
      StreamTuning.readProperty(player, 'current-vo'),
      StreamTuning.readProperty(player, 'video-params/w'),
    ]);
    if (!mounted || !identical(player, _player)) return;

    final vid = reads[0];
    final vo = reads[1];
    final width = reads[2];
    // vo=null is media_kit's placeholder until the Flutter surface exists; if
    // it is still there now, the surface never arrived.
    final noPicture = vid == 'no' || vo == null || vo == 'null' || width == null;

    if (!noPicture) {
      if (VideoOutput.preference == VideoOutput.auto &&
          VideoOutput.learned != _output) {
        print('Picture confirmed on ${_output.name} output; remembering it');
        VideoOutput.learned = _output;
        StorageService().saveSetting(
          AppConstants.settingVideoOutputLearned,
          _output.index,
        );
      }
      return;
    }

    print('No picture on ${_output.name} output (vid=$vid vo=$vo w=$width)');

    // A pinned output is the user's call; say nothing and leave it.
    if (VideoOutput.preference != VideoOutput.auto) return;

    final next = _output.fallback;
    if (next == null) {
      print('No output shows a picture for this stream');
      _rebuildOnNextChannel = _output != VideoOutput.effective;
      return;
    }

    print('Rebuilding player on ${next.name} output');
    _output = next;
    await _recreatePlayer(_streamUrl);
  }

  void _handlePlaybackError(String rawError) {
    // mpv error text embeds the failing URL, credentials and all - both the log
    // line and the on-screen message have to be redacted.
    final error = StreamTuning.redactUrl(rawError);

    if (ref.read(autoReconnectProvider)) {
      // Hand it to the watchdog rather than surfacing a dead end. Errors that
      // arrive without a stall (a failed open, say) would otherwise never be
      // noticed by the sampler.
      print('Playback error: $error - handing to watchdog');
      _watchdog.forceRecovery(userInitiated: false);
      return;
    }

    if (mounted) {
      setState(() {
        _errorMessage = error;
        _isLoading = false;
        _isBuffering = false;
      });
    }
  }

  void _onWatchdogStatus(WatchdogStatus status) {
    if (!mounted) return;
    setState(() {
      _watchdogStatus = status;
      if (status.phase == WatchdogPhase.healthy) {
        _errorMessage = null;
        _isLoading = false;
      }
    });
  }

  void _updateBufferHealth() {
    final player = _player;
    if (player == null || !mounted) return;

    final health = StreamTuning.bufferHealth(
      player.state.buffer,
      player.state.position,
      ref.read(bufferModeProvider).seconds,
    );

    if ((health - _bufferHealth).abs() > 0.01) {
      setState(() => _bufferHealth = health);
    }
  }

  @override
  void dispose() {
    // Hand the system bars back to the rest of the app on the way out.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    WidgetsBinding.instance.removeObserver(this);
    TvPlatform.releaseKeepScreenOn();
    _hideTimer?.cancel();
    _bannerTimer?.cancel();
    _statsTimer?.cancel();
    _pictureTimer?.cancel();
    _quality.dispose();
    _watchdog.dispose();
    _cancelSubscriptions();
    _player?.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ==========================================================================
  // Channel / controls
  // ==========================================================================

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_player?.state.playing ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _showControlsTemporarily() {
    setState(() => _showControls = true);
    _startHideTimer();
  }

  /// Shared by the `M` key and the bottom-bar button.
  ///
  /// Deliberately does not setState: the volume listener in [_attachListeners]
  /// does that, so the icon stays correct even when something other than this
  /// changes the volume.
  void _toggleMute() {
    final player = _player;
    if (player == null) return;
    player.setVolume(player.state.volume > 0 ? 0 : 100);
  }

  void _toggleFullscreen() {
    // Meaningless on TV: the app is already full-screen, and both
    // immersiveSticky and setPreferredOrientations are no-ops there.
    if (kIsTv) return;
    setState(() => _isFullscreen = !_isFullscreen);

    // The player is immersive for its whole lifetime (see initState), so the
    // toggle only locks orientation: on = force landscape, off = allow rotation.
    // Re-assert immersive here too, in case the system bars crept back after an
    // app switch or a transient swipe-reveal.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    if (_isFullscreen) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  Future<void> _switchChannel(Channel newChannel) async {
    setState(() {
      _currentChannel = newChannel;
      _streamUrl = newChannel.streamUrl;
      _isLoading = true;
      _errorMessage = null;
      _bufferHealth = 0.0;
      _watchdogStatus =
          const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');
    });

    ref.read(channelStateProvider.notifier).markAsWatched(newChannel);
    _flashChannelBanner();
    _refreshQualityOptions();
    _resetStatsWindow();
    _qualitySamples.clear();
    if (_rebuildOnNextChannel) {
      _rebuildOnNextChannel = false;
      _output = VideoOutput.effective;
      await _recreatePlayer(newChannel.streamUrl);
      return;
    }
    await _openUrl(newChannel.streamUrl);
  }

  /// Shows which channel was just tuned, and what is on it, for a few
  /// seconds. A banner rather than revealing the controls: those would make
  /// the next OK press pause instead of waking them, which is not what someone
  /// flicking through channels expects.
  void _flashChannelBanner() {
    _bannerTimer?.cancel();
    setState(() => _showChannelBanner = true);
    _bannerTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showChannelBanner = false);
    });
  }

  void _nextChannel() {
    final next =
        ref.read(channelStateProvider.notifier).getNextChannel(_currentChannel);
    if (next != null) _switchChannel(next);
  }

  void _previousChannel() {
    final previous = ref
        .read(channelStateProvider.notifier)
        .getPreviousChannel(_currentChannel);
    if (previous != null) _switchChannel(previous);
  }

  /// Manual reconnect - the R key and the on-screen banner. A clean slate:
  /// restores the channel's original URL in case the watchdog had fallen back
  /// to an alternate format that turned out to be worse, and undoes any
  /// quality degradation.
  Future<void> _manualReconnect() async {
    _streamUrl = _currentChannel.streamUrl;
    setState(() => _errorMessage = null);

    // Resetting quality re-opens the stream itself, so only fall through to the
    // recovery ladder when there was no degradation to undo.
    if (_quality.isDegraded) {
      await _quality.reset();
      return;
    }
    await _watchdog.forceRecovery();
  }

  /// Keys the player claims for itself, regardless of what has focus.
  ///
  /// Mounted on a [Focus] that cannot itself be focused (see [build]), so key
  /// events reach it by bubbling up the ancestor chain from whatever control
  /// currently holds focus. Anything not claimed here returns
  /// [KeyEventResult.ignored] and falls through to Flutter's directional
  /// traversal - which is what moves focus between the on-screen buttons - and
  /// then to the platform, which is how the remote's Back button still works.
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Both edges of a claimed key must be consumed. If only key-down is taken,
    // the matching key-up is redispatched to the Android activity - and Back
    // fires on ACTION_UP, so the activity would pop out from under us.
    if (event is KeyRepeatEvent) return KeyEventResult.handled;

    // The remote's Back. Acted on at key-up, not key-down: acting on the down
    // pops this route, so the up lands on the channel list where nothing
    // claims it, reaches the activity - which fires Back on ACTION_UP - and
    // pops again, straight out of the app. Latched so an up whose down
    // happened somewhere else is swallowed rather than acted on.
    if (event.logicalKey == LogicalKeyboardKey.goBack) {
      if (event is KeyDownEvent) {
        _backPressed = true;
      } else if (_backPressed) {
        _backPressed = false;
        _goBack();
      }
      return KeyEventResult.handled;
    }

    // The remote's Menu key opens the options menu, at key-up for the same
    // reason as Back: the menu is a route, so the up would otherwise land in
    // it unclaimed and reach the activity on its own.
    if (event.logicalKey == LogicalKeyboardKey.contextMenu) {
      if (event is KeyDownEvent) {
        _menuPressed = true;
      } else if (_menuPressed) {
        _menuPressed = false;
        _showOptionsMenu();
      }
      return KeyEventResult.handled;
    }

    if (event is! KeyDownEvent) {
      if (_swallowSelectUp && event.logicalKey == LogicalKeyboardKey.select) {
        _swallowSelectUp = false;
        return KeyEventResult.handled;
      }
      return _claimedKeys.contains(event.logicalKey)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (!_claimedKeys.contains(event.logicalKey)) {
      // Not ours. On TV a directional press while the controls are hidden
      // should wake them before traversal moves focus, so the user is never
      // navigating an invisible UI.
      if (!_showControls && _isDirectional(event.logicalKey)) {
        final wasHidden = !_showControls;
        _showControlsTemporarily();
        // Select on a control nobody can see would activate something at
        // random, so the first press only wakes the UI. Latched rather than
        // re-tested on key-up, because by then _showControls is already true
        // and the up event would leak to the platform unmatched.
        if (wasHidden && event.logicalKey == LogicalKeyboardKey.select) {
          _swallowSelectUp = true;
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    final player = _player;
    _showControlsTemporarily();

    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.mediaPlay:
      case LogicalKeyboardKey.mediaPause:
        player?.playOrPause();
      case LogicalKeyboardKey.mediaStop:
        player?.pause();
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.channelUp:
      case LogicalKeyboardKey.mediaTrackPrevious:
        _previousChannel();
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.channelDown:
      case LogicalKeyboardKey.mediaTrackNext:
        _nextChannel();
      case LogicalKeyboardKey.arrowLeft:
        if (!widget.isLive && player != null) {
          player.seek(player.state.position - const Duration(seconds: 10));
        }
      case LogicalKeyboardKey.arrowRight:
        if (!widget.isLive && player != null) {
          player.seek(player.state.position + const Duration(seconds: 10));
        }
      case LogicalKeyboardKey.keyM:
        _toggleMute();
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
      case LogicalKeyboardKey.keyI:
      case LogicalKeyboardKey.info:
        _toggleStats();
      case LogicalKeyboardKey.keyQ:
        _showQualityPicker();
      case LogicalKeyboardKey.keyR:
        _manualReconnect();
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          _exitPlayer();
        }
    }

    return KeyEventResult.handled;
  }

  /// Set when a Select press was spent waking the controls, so its key-up is
  /// consumed too rather than leaking to the platform unmatched.
  bool _swallowSelectUp = false;

  /// Set on Back's key-down, so its key-up is the one that acts.
  bool _backPressed = false;

  /// Set on Menu's key-down, so its key-up is the one that acts.
  bool _menuPressed = false;

  /// Back from the remote: closes the stats overlay if it is up, otherwise
  /// leaves the player.
  ///
  /// maybePop rather than [_exitPlayer], so the expanded mini player's
  /// PopScope still turns Back into minimise instead of stopping playback.
  void _goBack() {
    if (_showStats) {
      _toggleStats();
      return;
    }
    Navigator.of(context).maybePop();
  }

  /// The back arrow, the TV's Channels button and Esc.
  void _exitPlayer() {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Keys handled by [_handleKeyEvent], as a set so key-up can be consumed
  /// symmetrically without duplicating the switch.
  ///
  /// Up/Down are claimed unconditionally: channel surfing is the most-used
  /// interaction on a live TV player and must not cost two presses to reveal
  /// the controls first. Left/Right are claimed for VOD seeking only, leaving
  /// them free for horizontal focus traversal on a live stream.
  Set<LogicalKeyboardKey> get _claimedKeys => {
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.mediaPlayPause,
        LogicalKeyboardKey.mediaPlay,
        LogicalKeyboardKey.mediaPause,
        LogicalKeyboardKey.mediaStop,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.channelUp,
        LogicalKeyboardKey.mediaTrackPrevious,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.channelDown,
        LogicalKeyboardKey.mediaTrackNext,
        if (!widget.isLive) LogicalKeyboardKey.arrowLeft,
        if (!widget.isLive) LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.keyM,
        if (!kIsTv) LogicalKeyboardKey.keyF,
        LogicalKeyboardKey.keyI,
        LogicalKeyboardKey.info,
        LogicalKeyboardKey.keyQ,
        LogicalKeyboardKey.keyR,
        LogicalKeyboardKey.escape,
      };

  static bool _isDirectional(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowLeft ||
      key == LogicalKeyboardKey.arrowRight ||
      key == LogicalKeyboardKey.arrowUp ||
      key == LogicalKeyboardKey.arrowDown ||
      key == LogicalKeyboardKey.select;

  // ==========================================================================
  // Build
  // ==========================================================================

  @override
  Widget build(BuildContext context) {
    // Cache sizing applies live, so a buffer-mode change takes effect on the
    // running stream rather than waiting for the next channel change.
    ref.listen<BufferMode>(bufferModeProvider, (_, mode) {
      final player = _player;
      if (player != null) {
        _applyTuning(player, mode: mode);
      }
    });

    final controller = _controller;

    // canRequestFocus/skipTraversal false is the whole point. This used to be
    // a KeyboardListener with autofocus:true, which made a full-screen node the
    // scope's focusedChild - and directional traversal filters candidates to
    // those beyond the focused node's edge, so with a full-screen rect the
    // candidate set was empty in all four directions and focus could never
    // reach any control, on a remote or on a desktop keyboard. As a
    // non-focusable interceptor it still receives every key by bubbling, while
    // the real focusedChild is a button with a real rect that traversal can
    // move away from.
    return Focus(
      focusNode: _focusNode,
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        // Stays a plain GestureDetector: this is the whole-screen
        // tap-to-reveal affordance, not a control. Making it focusable would
        // put a full-screen node in the traversal order, which is exactly the
        // bug the Focus interceptor above was introduced to fix. The remote
        // equivalent is the directional-wake rule in _handleKeyEvent.
        body: GestureDetector(
          onTap: _showControlsTemporarily,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (controller != null)
                Center(
                  child: Video(
                    controller: controller,
                    controls: NoVideoControls,
                  ),
                )
              else
                const ColoredBox(color: Colors.black),

              // Video is off, so say so. A black frame with sound still playing
              // is indistinguishable from the freeze this was meant to fix.
              if (_quality.current?.videoDisabled ?? false)
                _buildAudioOnlyPanel(),

              if (_isLoading) _buildLoadingOverlay(),

              if (_isBuffering && !_isLoading) _buildBufferingIndicator(),

              // Recovery banner - shown whenever the watchdog is not happy and
              // we are not already covered by the loading overlay.
              if (!_watchdogStatus.isHealthy && !_isLoading)
                _buildWatchdogBanner(),

              if (_errorMessage != null) _buildErrorView(),

              // Mounted whenever there is no error, not only while visible.
              // _buildControls already fades itself with AnimatedOpacity, so
              // the old `_showControls &&` guard meant that animation never ran
              // in its fade-out direction - and, worse on a remote, the focused
              // button left the tree entirely when the hide timer fired.
              // IgnorePointer keeps an invisible control from being clicked;
              // Select while hidden is swallowed in _handleKeyEvent.
              if (_errorMessage == null)
                IgnorePointer(
                  ignoring: !_showControls,
                  child: _buildControls(),
                ),

              if (_showControls && _errorMessage == null && widget.isLive)
                _buildBufferHealthIndicator(),

              // Shown whether or not the controls are up: it is the explanation
              // for why the picture got worse, plus the way back.
              if (_quality.isDegraded && _errorMessage == null)
                _buildQualityBadge(),

              // Hidden under the controls, which already name the channel.
              if (widget.isLive && _errorMessage == null)
                _buildChannelBanner(),

              if (_showStats) _buildStatsOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChannelBanner() {
    final channel = _currentChannel;
    final epg = ref.read(epgStateProvider.notifier);
    final epgId = channel.epgChannelId;
    final hasEpg = epgId != null && epgId.isNotEmpty;
    final now = hasEpg ? epg.getCurrentProgram(epgId) : null;
    final next = hasEpg ? epg.getNextProgram(epgId) : null;
    final logo = channel.logoUrl;

    return Positioned(
      left: 24 + _overlayInset,
      right: 24 + _overlayInset,
      bottom: 24 + _overlayInset,
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _showChannelBanner && !_showControls ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 250),
          child: Center(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 640),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  if (logo != null && logo.isNotEmpty) ...[
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: CachedNetworkImage(
                        imageUrl: logo,
                        fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => const Icon(
                          Icons.live_tv,
                          color: Colors.white54,
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          channel.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (now != null)
                          _bannerProgram('Now', now.title,
                              '${_hhmm(now.startTime)} - ${_hhmm(now.endTime)}'),
                        if (next != null)
                          _bannerProgram(
                              'Next', next.title, _hhmm(next.startTime)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bannerProgram(String label, String title, String time) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(
                color: AppTheme.accentColor,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            time,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  static String _hhmm(DateTime t) {
    final local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildLoadingOverlay() {
    final bufferMode = ref.watch(bufferModeProvider);
    final recovering = _watchdogStatus.isRecovering;

    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppTheme.primaryColor),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                recovering
                    ? _watchdogStatus.message
                    : 'Tuning to ${_currentChannel.name}...',
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Buffer mode: ${bufferMode.label}',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBufferingIndicator() {
    return Positioned(
      top: 100 + _overlayInset,
      left: 0,
      right: 0,
      // The subtree stays const even though Positioned cannot be, now that its
      // offset depends on the TV overlay inset.
      child: const Center(
        child: _Pill(
          color: Colors.black54,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  color: AppTheme.primaryColor,
                  strokeWidth: 2,
                ),
              ),
              SizedBox(width: 8),
              Text(
                'Buffering...',
                style: TextStyle(color: Colors.white, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Status banner for everything the watchdog is doing. Deliberately
  /// non-blocking: recovery continues on its own, and tapping only short-cuts
  /// the wait rather than being the thing that makes recovery happen.
  Widget _buildWatchdogBanner() {
    final status = _watchdogStatus;
    final autoReconnect = ref.watch(autoReconnectProvider);

    final Color color;
    final IconData icon;
    final String label;

    switch (status.phase) {
      case WatchdogPhase.degraded:
        color = AppTheme.warningColor;
        icon = Icons.warning_amber;
        label = autoReconnect
            ? status.message
            : 'Stream frozen - auto reconnect is off. Tap to reconnect';
      case WatchdogPhase.recovering:
      case WatchdogPhase.verifying:
        color = AppTheme.primaryColor;
        icon = Icons.autorenew;
        label = status.message;
      case WatchdogPhase.backingOff:
        color = AppTheme.errorColor;
        icon = Icons.cloud_off;
        label = status.message;
      case WatchdogPhase.healthy:
        return const SizedBox.shrink();
    }

    return Positioned(
      top: 100 + _overlayInset,
      left: 0,
      right: 0,
      child: Center(
        child: TvFocusable(
          onTap: _manualReconnect,
          borderRadius: BorderRadius.circular(20),
          semanticLabel: 'Reconnect',
          child: _Pill(
            color: color.withValues(alpha: 0.9),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: Colors.white, size: 16),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (status.isRecovering) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // Diagnostics overlay
  // ==========================================================================

  void _toggleStats() {
    setState(() => _showStats = !_showStats);
    _statsTimer?.cancel();
    if (!_showStats) return;

    _sampleStats();
    _statsTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _sampleStats());
  }

  Future<void> _sampleStats() async {
    final player = _player;
    if (player == null || !mounted) return;

    // Concurrently: each read carries its own timeout, and eight in series
    // would not fit the one-second interval on a struggling stream.
    final numbers = await Future.wait([
      StreamTuning.readDouble(player, 'video-params/w'),
      StreamTuning.readDouble(player, 'video-params/h'),
      StreamTuning.readDouble(player, 'video-bitrate'),
      StreamTuning.readDouble(player, 'audio-bitrate'),
      StreamTuning.readDouble(player, 'cache-speed'),
      StreamTuning.readDouble(player, 'demuxer-cache-time'),
      StreamTuning.readDouble(player, 'container-fps'),
    ]);
    final strings = await Future.wait([
      StreamTuning.readProperty(player, 'video-format'),
      StreamTuning.readProperty(player, 'current-vo'),
      StreamTuning.readProperty(player, 'hwdec-current'),
    ]);
    final codec = strings[0];

    if (!mounted) return;

    final videoBitrate = numbers[2];
    if (videoBitrate != null && videoBitrate > 0) {
      _bitrateWindow.add(videoBitrate);
      if (_bitrateWindow.length > 12) _bitrateWindow.removeAt(0);
    }

    final stats = _StreamStats(
      width: numbers[0]?.round(),
      height: numbers[1]?.round(),
      videoBitrate: _bitrateWindow.isEmpty
          ? null
          : _bitrateWindow.reduce((a, b) => a + b) / _bitrateWindow.length,
      audioBitrate: numbers[3],
      cacheSpeed: numbers[4],
      cacheTime: numbers[5],
      fps: numbers[6],
      codec: codec,
      // What mpv is actually rendering with, which is not necessarily what
      // was asked for: hwdec falls back to software silently.
      output: '${strings[1] ?? 'none'} / ${strings[2] ?? 'no'} hwdec',
      samples: _bitrateWindow.length,
    );

    setState(() {
      _stats = stats;
      // Recorded only once the average has settled, or the comparison table
      // fills with numbers from the first second of playback.
      final label = _quality.current?.label;
      if (label != null && stats.samples >= 8 && stats.width != null) {
        _qualitySamples[label] = stats;
      }
    });
  }

  /// A new stream invalidates both the running average and the resolution.
  void _resetStatsWindow() {
    _bitrateWindow.clear();
    _stats = null;
  }

  // ==========================================================================
  // Quality
  // ==========================================================================

  /// Badge shown while playing anything other than the source, with the way
  /// back. A downgrade nobody can see or undo is a support ticket.
  Widget _buildQualityBadge() {
    final option = _quality.current;
    if (option == null) return const SizedBox.shrink();

    return Positioned(
      top: 108 + _overlayInset,
      right: 16 + _overlayInset,
      child: TvFocusable(
        onTap: _showQualityPicker,
        borderRadius: BorderRadius.circular(4),
        semanticLabel: 'Stream quality',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: AppTheme.warningColor, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_qualityIcon(option), color: AppTheme.warningColor, size: 13),
              const SizedBox(width: 5),
              Text(
                option.label,
                style: const TextStyle(
                  color: AppTheme.warningColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAudioOnlyPanel() {
    return Container(
      color: AppTheme.backgroundColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, size: 56, color: AppTheme.primaryColor),
            const SizedBox(height: 16),
            const Text(
              'Audio only',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _currentChannel.name,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () => _quality.reset(),
              icon: const Icon(Icons.videocam_outlined, size: 18),
              label: const Text('Turn video back on'),
            ),
          ],
        ),
      ),
    );
  }

  IconData _qualityIcon(QualityOption option) => switch (option.kind) {
        QualityKind.source => Icons.high_quality_outlined,
        QualityKind.sibling => Icons.sd_outlined,
        QualityKind.hlsCap => Icons.network_check,
        QualityKind.audioOnly => Icons.graphic_eq,
      };

  String _qualityDescription(QualityOption option) => switch (option.kind) {
        QualityKind.source => 'The channel as listed',
        QualityKind.sibling => 'A lower-bitrate version of this channel',
        QualityKind.hlsCap => 'Asks the provider for its smallest rendition',
        // Deliberately not overstated. On a muxed transport stream - which most
        // Xtream live channels are - the whole stream still has to be
        // downloaded; only the decoding stops.
        QualityKind.audioOnly =>
          'Stops decoding video. Saves power, but usually not data',
      };

  Future<void> _showQualityPicker() async {
    _showControlsTemporarily();

    final options = _quality.options;
    if (options.length < 2) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No other quality is available for this channel'),
        ));
      }
      return;
    }

    final current = _quality.current;
    final chosen = await showModalBottomSheet<QualityOption>(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 18, color: AppTheme.textSecondary),
                  SizedBox(width: 8),
                  Text(
                    'Stream quality',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      // A remote needs somewhere to start from, and the
                      // current option is where the user is.
                      autofocus: kIsTv && option == current,
                      leading: Icon(
                        _qualityIcon(option),
                        size: 20,
                        color: option == current
                            ? AppTheme.primaryColor
                            : AppTheme.textSecondary,
                      ),
                      title: Text(option.label),
                      subtitle: Text(
                        _qualityDescription(option),
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: option == current
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: AppTheme.primaryColor,
                            )
                          : null,
                      onTap: () => Navigator.of(sheetContext).pop(option),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (chosen != null && chosen != current) {
      await _quality.selectManual(chosen);
    }
  }

  // ==========================================================================
  // Options menu
  // ==========================================================================

  /// Every keyboard shortcut as a list a remote can drive: the Menu key, or
  /// the Options button on the bottom bar.
  ///
  /// On TV this is the only way to most of these. Up/Down are channel keys,
  /// so the top bar is out of reach of the D-pad, and there is no button at
  /// all for quality (until it degrades) or reconnect. A sheet rather than
  /// more buttons on the overlay: it is a route of its own, so the player's
  /// key interceptor is not in its ancestor chain and Up/Down move through
  /// the list instead of changing channel.
  Future<void> _showOptionsMenu() async {
    final player = _player;
    if (player == null) return;
    _showControlsTemporarily();

    final playing = player.state.playing;
    final muted = player.state.volume == 0;
    final quality = _quality.current;
    final canPickQuality = _quality.options.length >= 2;

    Widget item(
      BuildContext sheetContext,
      _PlayerAction action,
      IconData icon,
      String title, {
      String? subtitle,
      String? shortcut,
      bool autofocus = false,
    }) {
      return ListTile(
        dense: true,
        autofocus: autofocus,
        leading: Icon(icon, size: 20, color: AppTheme.textSecondary),
        title: Text(title),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: const TextStyle(fontSize: 11)),
        // The keyboard equivalent, for desktop. Meaningless on a remote.
        trailing: shortcut == null || kIsTv
            ? null
            : Text(
                shortcut,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMuted,
                ),
              ),
        onTap: () => Navigator.of(sheetContext).pop(action),
      );
    }

    final action = await showModalBottomSheet<_PlayerAction>(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  Icon(Icons.tune, size: 18, color: AppTheme.textSecondary),
                  SizedBox(width: 8),
                  Text(
                    'Options',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  item(
                    sheetContext,
                    _PlayerAction.playPause,
                    playing ? Icons.pause : Icons.play_arrow,
                    playing ? 'Pause' : 'Play',
                    shortcut: 'Space',
                    autofocus: kIsTv,
                  ),
                  item(
                    sheetContext,
                    _PlayerAction.mute,
                    muted ? Icons.volume_up : Icons.volume_off,
                    muted ? 'Unmute' : 'Mute',
                    shortcut: 'M',
                  ),
                  item(
                    sheetContext,
                    _PlayerAction.quality,
                    Icons.high_quality_outlined,
                    'Stream quality',
                    subtitle: canPickQuality
                        ? quality?.label
                        : 'Only one quality for this channel',
                    shortcut: 'Q',
                  ),
                  item(
                    sheetContext,
                    _PlayerAction.stats,
                    Icons.analytics_outlined,
                    _showStats ? 'Hide stream stats' : 'Show stream stats',
                    shortcut: 'I',
                  ),
                  item(
                    sheetContext,
                    _PlayerAction.reconnect,
                    Icons.refresh,
                    'Reconnect',
                    subtitle: _quality.isDegraded
                        ? 'Back to full quality and the original stream'
                        : 'Re-open the stream from scratch',
                    shortcut: 'R',
                  ),
                  if (widget.onMinimize != null)
                    item(
                      sheetContext,
                      _PlayerAction.minimize,
                      Icons.picture_in_picture_alt,
                      'Mini player',
                    ),
                  if (!kIsTv)
                    item(
                      sheetContext,
                      _PlayerAction.fullscreen,
                      _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      _isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                      shortcut: 'F',
                    ),
                  item(
                    sheetContext,
                    _PlayerAction.close,
                    kIsTv ? Icons.format_list_bulleted : Icons.close,
                    kIsTv ? 'Channel list' : 'Close player',
                    shortcut: 'Esc',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    // Acted on after the sheet has gone, so the quality picker opens on its
    // own rather than stacked over this one.
    if (action == null || !mounted) return;
    switch (action) {
      case _PlayerAction.playPause:
        _player?.playOrPause();
      case _PlayerAction.mute:
        _toggleMute();
      case _PlayerAction.quality:
        await _showQualityPicker();
      case _PlayerAction.stats:
        _toggleStats();
      case _PlayerAction.reconnect:
        await _manualReconnect();
      case _PlayerAction.minimize:
        widget.onMinimize?.call();
      case _PlayerAction.fullscreen:
        _toggleFullscreen();
      case _PlayerAction.close:
        _exitPlayer();
    }
  }

  Widget _buildStatsOverlay() {
    final stats = _stats;
    final quality = _quality.current;

    // Ordered by measured pixel count, so if the labels lie the table says so.
    final compared = _qualitySamples.entries.toList()
      ..sort((a, b) => b.value.pixels.compareTo(a.value.pixels));

    return Positioned(
      left: 12 + _overlayInset,
      top: 72 + _overlayInset,
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppTheme.accentColor, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.analytics_outlined,
                    size: 13, color: AppTheme.accentColor),
                const SizedBox(width: 6),
                const Text(
                  'STREAM STATS',
                  style: TextStyle(
                    color: AppTheme.accentColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                TvFocusable(
                  onTap: _toggleStats,
                  borderRadius: BorderRadius.circular(4),
                  semanticLabel: 'Close stats',
                  child: const Padding(
                    // Was a bare 13px icon - far too small to aim a focus ring
                    // at, let alone hit.
                    padding: EdgeInsets.all(6),
                    child: Icon(Icons.close, size: 14, color: Colors.white54),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            _statLine('playing', quality?.label ?? _currentChannel.name),
            _statLine('kind', quality?.kind.name ?? 'source'),
            const Divider(height: 12, color: Colors.white12),

            _statLine('resolution', stats?.resolution ?? '-'),
            _statLine(
              'video bitrate',
              _StreamStats.mbps(stats?.videoBitrate),
              // Below eight samples the mean is still moving, so say so rather
              // than let it be compared against a settled figure.
              provisional: (stats?.samples ?? 0) < 8,
            ),
            _statLine('audio bitrate', _StreamStats.mbps(stats?.audioBitrate)),
            _statLine('codec / fps',
                '${stats?.codec ?? '-'}  ${stats?.fps?.toStringAsFixed(0) ?? '-'}fps'),
            if (VideoOutput.isConfigurable)
              _statLine('output', stats?.output ?? '-'),
            const Divider(height: 12, color: Colors.white12),

            _statLine('arriving', _StreamStats.mbpsFromBytes(stats?.cacheSpeed)),
            _statLine('demuxer cache',
                '${stats?.cacheTime?.toStringAsFixed(1) ?? '-'}s'),
            _statLine('buffer health', '${(_bufferHealth * 100).toInt()}%'),
            _statLine(
                'watchdog',
                _watchdogStatus.isHealthy
                    ? 'healthy'
                    : _watchdogStatus.phase.name),

            if (compared.length > 1) ...[
              const Divider(height: 14, color: Colors.white12),
              const Text(
                'MEASURED THIS SESSION',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 6),
              for (final entry in compared)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.key,
                          style: TextStyle(
                            color: entry.key == quality?.label
                                ? AppTheme.accentColor
                                : Colors.white70,
                            fontSize: 10,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${entry.value.resolution}  '
                        '${_StreamStats.mbps(entry.value.videoBitrate)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statLine(String label, String value, {bool provisional = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ),
          Expanded(
            child: Text(
              provisional && value != '-' ? '$value  (settling)' : value,
              style: TextStyle(
                color: provisional ? Colors.white54 : Colors.white,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBufferHealthIndicator() {
    final Color healthColor;
    if (_bufferHealth > 0.7) {
      healthColor = AppTheme.successColor;
    } else if (_bufferHealth > 0.3) {
      healthColor = AppTheme.warningColor;
    } else {
      healthColor = AppTheme.errorColor;
    }

    return Positioned(
      top: 80 + _overlayInset,
      right: 16 + _overlayInset,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _bufferHealth > 0.5
                  ? Icons.signal_cellular_alt
                  : Icons.signal_cellular_alt_2_bar,
              color: healthColor,
              size: 14,
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 40,
              height: 4,
              child: LinearProgressIndicator(
                value: _bufferHealth,
                backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation(healthColor),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '${(_bufferHealth * 100).toInt()}%',
              style: TextStyle(color: healthColor, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.errorColor, size: 48),
          const SizedBox(height: 16),
          Text(
            'Playback Error',
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: Colors.white),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage!,
              style: const TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'Turn on Auto Reconnect in Settings to recover from this '
              'automatically.',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: _manualReconnect,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
              const SizedBox(width: 16),
              OutlinedButton(
                onPressed: _nextChannel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white54),
                ),
                child: const Text('Try Next Channel'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final epgNotifier = ref.read(epgStateProvider.notifier);
    final currentProgram = _currentChannel.epgChannelId != null
        ? epgNotifier.getCurrentProgram(_currentChannel.epgChannelId!)
        : null;

    return AnimatedOpacity(
      opacity: _showControls ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 300),
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.7),
              Colors.transparent,
              Colors.transparent,
              Colors.black.withValues(alpha: 0.7),
            ],
            stops: const [0.0, 0.2, 0.8, 1.0],
          ),
        ),
        // Contains traversal: without a group, an arrow press at the edge of
        // the controls escapes into whatever else is in the scope - on the
        // expanded mini player that is HomeScreen's navigation rail and
        // channel list, sitting behind the video.
        child: FocusTraversalGroup(
          child: Column(
            children: [
              _buildTopBar(currentProgram?.title),
              Expanded(child: _buildCenterControls()),
              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(String? programTitle) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _exitPlayer,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _currentChannel.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (programTitle != null)
                    Text(
                      programTitle,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.7),
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (widget.isLive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, color: Colors.white, size: 8),
                    SizedBox(width: 4),
                    Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(width: 8),
            IconButton(
              icon: Icon(
                Icons.analytics_outlined,
                color: _showStats ? AppTheme.accentColor : Colors.white,
              ),
              onPressed: _toggleStats,
              tooltip: 'Stream stats (I)',
            ),
            if (widget.onMinimize != null) ...[
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.picture_in_picture_alt,
                    color: Colors.white),
                onPressed: widget.onMinimize,
                tooltip: 'Mini player',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCenterControls() {
    final player = _player;

    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, color: Colors.white, size: 36),
            onPressed: _previousChannel,
            tooltip: 'Previous channel (↑)',
          ),
          const SizedBox(width: 24),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.replay_10, color: Colors.white, size: 36),
              onPressed: player == null
                  ? null
                  : () => player
                      .seek(player.state.position - const Duration(seconds: 10)),
            ),
          const SizedBox(width: 16),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: IconButton(
              iconSize: 64,
              // The deterministic first focus target. Traversal needs
              // *something* focused to move away from, and the centre
              // play/pause button is the conventional landing spot on TV.
              autofocus: kIsTv,
              icon: Icon(
                (player?.state.playing ?? false)
                    ? Icons.pause
                    : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed: player == null ? null : () => player.playOrPause(),
            ),
          ),
          const SizedBox(width: 16),
          if (!widget.isLive)
            IconButton(
              icon: const Icon(Icons.forward_10, color: Colors.white, size: 36),
              onPressed: player == null
                  ? null
                  : () => player
                      .seek(player.state.position + const Duration(seconds: 10)),
            ),
          const SizedBox(width: 24),
          IconButton(
            icon: const Icon(Icons.skip_next, color: Colors.white, size: 36),
            onPressed: _nextChannel,
            tooltip: 'Next channel (↓)',
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar() {
    final player = _player;

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              (player?.state.volume ?? 0) == 0
                  ? Icons.volume_off
                  : Icons.volume_up,
              color: Colors.white,
            ),
            onPressed: player == null ? null : _toggleMute,
          ),
          // Keyboard hints mean nothing on a touchscreen, and the desktop
          // string is wider than a phone - it overflowed the row there.
          Expanded(
            child: kIsTv || context.isDesktop
                ? Text(
                    kIsTv
                        ? 'OK: Play/Pause • ↑↓: Channel • Menu: Options • '
                            'Back: Channel list'
                        : 'Space: Play/Pause • ↑↓: Channel • M: Mute • Q: Quality • '
                            'I: Stats • R: Reconnect • F: Fullscreen',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 11,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          // Everything the keyboard shortcuts do, for a remote or a
          // touchscreen. On the row Left/Right already moves along, like
          // Channels below.
          if (kIsTv)
            TextButton.icon(
              onPressed: player == null ? null : _showOptionsMenu,
              icon: const Icon(Icons.tune, color: Colors.white),
              label: const Text(
                'Options',
                style: TextStyle(color: Colors.white),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.tune, color: Colors.white),
              tooltip: 'Options',
              onPressed: player == null ? null : _showOptionsMenu,
            ),
          // On TV the fullscreen toggle did nothing (the app is always
          // full-screen there), and Up/Down are channel keys, so the top bar's
          // back arrow was out of reach of the remote. This slot is on the
          // row Left/Right already moves along.
          if (kIsTv)
            TextButton.icon(
              onPressed: _exitPlayer,
              icon: const Icon(Icons.format_list_bulleted, color: Colors.white),
              label: const Text(
                'Channels',
                style: TextStyle(color: Colors.white),
              ),
            )
          else
            IconButton(
              icon: Icon(
                _isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                color: Colors.white,
              ),
              onPressed: _toggleFullscreen,
            ),
        ],
      ),
    );
  }
}

/// What the options menu returns, acted on once the sheet has closed.
enum _PlayerAction {
  playPause,
  mute,
  quality,
  stats,
  reconnect,
  minimize,
  fullscreen,
  close,
}

/// One sample of what libmpv reports about the stream actually playing.
///
/// These are measurements, not labels. A provider calling a channel `4K` says
/// nothing; `video-params/w` is the truth.
class _StreamStats {
  final int? width;
  final int? height;

  /// Mean of the recent `video-bitrate` readings, in bits per second.
  final double? videoBitrate;
  final double? audioBitrate;

  /// `cache-speed`, in *bytes* per second - mpv's unit.
  final double? cacheSpeed;
  final double? cacheTime;
  final double? fps;
  final String? codec;

  /// mpv's video output and the hardware decoder in use, as `vo / hwdec`.
  final String? output;

  /// How many bitrate readings the mean is over, so a number that has not
  /// settled yet can be shown as provisional.
  final int samples;

  const _StreamStats({
    this.width,
    this.height,
    this.videoBitrate,
    this.audioBitrate,
    this.cacheSpeed,
    this.cacheTime,
    this.fps,
    this.codec,
    this.output,
    this.samples = 0,
  });

  String get resolution =>
      width == null || height == null ? '-' : '$width x $height';

  /// Pixel count, for ordering the comparison table by real size rather than
  /// by what the provider called it.
  int get pixels => (width ?? 0) * (height ?? 0);

  static String mbps(double? bitsPerSecond) {
    if (bitsPerSecond == null || bitsPerSecond <= 0) return '-';
    return '${(bitsPerSecond / 1000000).toStringAsFixed(2)} Mbps';
  }

  /// Bytes per second rendered as bits, so throughput and bitrate are
  /// directly comparable on screen.
  static String mbpsFromBytes(double? bytesPerSecond) =>
      mbps(bytesPerSecond == null ? null : bytesPerSecond * 8);
}

/// Rounded translucent container used by the buffering and watchdog banners.
class _Pill extends StatelessWidget {
  final Color color;
  final Widget child;

  const _Pill({required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: child,
    );
  }
}

Widget NoVideoControls(VideoState state) => const SizedBox.shrink();
