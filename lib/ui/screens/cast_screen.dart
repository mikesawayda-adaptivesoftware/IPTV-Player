import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/cast/cast_bridge.dart';
import '../../core/cast/cast_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/cast_provider.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart';
import '../player/video_player_screen.dart';
import '../widgets/cast_device_picker.dart';
import '../widgets/mini_player.dart';

/// Starts casting [media], asking for a Chromecast first when none is joined.
///
/// Returns false when nothing was cast: the picker was dismissed, or the film
/// is in a format a Chromecast cannot play (which is said in a snackbar).
/// The caller must have stopped its own player before this returns true -
/// or, better, before calling, since the relay dials the provider at once.
Future<bool> startCasting(
  BuildContext context,
  WidgetRef ref,
  CastMedia media, {
  Duration position = Duration.zero,
  Future<void> Function()? beforeCasting,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final cast = ref.read(castProvider.notifier);
  if (!media.live && CastController.movieFormat(media.url) == null) {
    messenger.showSnackBar(SnackBar(
      content: Text(CastController.unsupportedMovieMessage(media.url)),
    ));
    return false;
  }

  CastDevice? device;
  if (!ref.read(castProvider).active) {
    device = await pickCastDevice(context);
    if (device == null) return false;
  }
  await beforeCasting?.call();
  // Not awaited: joining a device takes seconds, and the cast screen shows it.
  if (media.live) {
    cast.castChannel(media.channel!, device: device);
  } else {
    cast.castMovie(media, device: device, position: position);
  }
  return true;
}

/// Casts [media] when a cast is already running, so a channel or film picked
/// from a list goes to the TV rather than opening a second stream on the
/// phone. Returns whether it did.
bool castInsteadOfPlaying(BuildContext context, WidgetRef ref, CastMedia media) {
  if (!ref.read(castProvider).active) return false;
  final cast = ref.read(castProvider.notifier);
  if (media.live) {
    cast.castChannel(media.channel!);
  } else {
    try {
      cast.castMovie(media);
    } on CastUnsupported catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
  return true;
}

/// Opens [media] in the phone's own player, after the cast has let go of the
/// provider connection.
Future<void> watchOnPhone(
  BuildContext context,
  WidgetRef ref,
  CastMedia media, {
  Duration? position,
}) async {
  final navigator = Navigator.of(context);
  await ref.read(castProvider.notifier).stop();
  final channel = media.channel;
  navigator.push(MaterialPageRoute(
    builder: (context) => channel != null
        ? EnhancedVideoPlayer(
            channel: channel,
            isLive: true,
            onMinimize: () {
              Navigator.of(context).pop();
              ref.read(miniPlayerProvider.notifier).play(channel);
            },
          )
        : VideoPlayerScreen(
            streamUrl: media.url,
            title: media.title,
            logoUrl: media.artwork,
            isLive: false,
            startPosition: position ?? Duration.zero,
          ),
  ));
}

/// What is on the Chromecast, and the controls for it.
///
/// Back leaves the cast running - the bar on the home screen brings this
/// back - and only Stop ends it. The screen closes itself when the cast ends
/// for any reason.
class CastScreen extends ConsumerStatefulWidget {
  const CastScreen({super.key});

  @override
  ConsumerState<CastScreen> createState() => _CastScreenState();
}

class _CastScreenState extends ConsumerState<CastScreen> {
  /// Set while the seek slider is held, so progress updates do not fight it.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    // Removed synchronously, while it is still the top route: "Watch on the
    // phone" pushes the player straight after stopping the cast, and an
    // asynchronous pop would land on the player instead.
    ref.listen<bool>(castProvider.select((s) => s.active), (was, active) {
      if (was != true || active || !mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
    final cast = ref.watch(castProvider);
    final controller = ref.read(castProvider.notifier);
    final media = cast.media;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundColor,
        title: Text(cast.device == null ? 'Casting' : 'Casting to ${cast.device}'),
      ),
      body: media == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  _artwork(media),
                  const SizedBox(height: 24),
                  Text(
                    media.displayTitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _status(cast),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                  if (media.live) ..._guide(media),
                  if (cast.error != null) ...[
                    const SizedBox(height: 16),
                    _problem(cast, media),
                  ],
                  const SizedBox(height: 24),
                  if (media.live)
                    _channelControls(controller)
                  else
                    ..._filmControls(cast, controller),
                  const SizedBox(height: 24),
                  _volume(cast, controller),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: controller.stop,
                    icon: const Icon(Icons.cast_connected),
                    label: const Text('Stop casting'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.errorColor,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () => watchOnPhone(context, ref, media,
                        position: cast.progress?.position),
                    icon: const Icon(Icons.phone_android),
                    label: const Text('Watch on the phone instead'),
                  ),
                ],
              ),
            ),
    );
  }

  String _status(CastState cast) {
    if (cast.reconnecting) return 'Reconnecting to the Chromecast...';
    if (cast.unsupported) return "Can't play on the Chromecast";
    switch (cast.phase) {
      case CastPhase.idle:
        return 'Not casting';
      case CastPhase.connecting:
        return 'Connecting to ${cast.device ?? 'the Chromecast'}...';
      case CastPhase.connected:
        return 'Starting...';
      case CastPhase.casting:
        break;
    }
    switch (cast.receiver.state) {
      case ReceiverState.playing:
        return 'Playing on ${cast.device ?? 'the TV'}';
      case ReceiverState.paused:
        return 'Paused';
      case ReceiverState.buffering:
        return 'Buffering...';
      case ReceiverState.loading:
      case ReceiverState.unknown:
      case ReceiverState.idle:
        return 'Starting...';
    }
  }

  Widget _artwork(CastMedia media) {
    final image = media.image;
    return Center(
      child: Container(
        width: media.live ? 160 : 180,
        height: media.live ? 120 : 260,
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: image == null || image.isEmpty
            ? Icon(media.live ? Icons.live_tv : Icons.movie,
                size: 56, color: AppTheme.textMuted)
            : CachedNetworkImage(
                imageUrl: image,
                fit: media.live ? BoxFit.contain : BoxFit.cover,
                errorWidget: (_, __, ___) => Icon(
                    media.live ? Icons.live_tv : Icons.movie,
                    size: 56,
                    color: AppTheme.textMuted),
              ),
      ),
    );
  }

  List<Widget> _guide(CastMedia media) {
    final epgId = media.channel?.epgChannelId;
    if (epgId == null || epgId.isEmpty) return const [];
    ref.watch(epgStateProvider);
    final epg = ref.read(epgStateProvider.notifier);
    final now = epg.getCurrentProgram(epgId);
    final next = epg.getNextProgram(epgId);
    if (now == null && next == null) return const [];
    final time = DateFormat.jm();
    return [
      const SizedBox(height: 16),
      Card(
        color: AppTheme.cardColor,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (now != null)
                _guideLine('Now', now.title,
                    '${time.format(now.startTime)} - ${time.format(now.endTime)}'),
              if (now != null && next != null) const SizedBox(height: 8),
              if (next != null)
                _guideLine('Next', next.title, time.format(next.startTime)),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _guideLine(String label, String title, String when) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 48,
          child: Text(label,
              style: const TextStyle(
                  color: AppTheme.accentColor, fontWeight: FontWeight.bold)),
        ),
        Expanded(
          child: Text(title,
              style: const TextStyle(color: AppTheme.textPrimary),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 8),
        Text(when, style: const TextStyle(color: AppTheme.textSecondary)),
      ],
    );
  }

  Widget _problem(CastState cast, CastMedia media) {
    return Card(
      color: AppTheme.errorColor.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(cast.error!, style: const TextStyle(color: AppTheme.textPrimary)),
      ),
    );
  }

  Widget _channelControls(CastController controller) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _bigButton(Icons.skip_previous, 'Previous channel', () => controller.step(false)),
        _bigButton(Icons.skip_next, 'Next channel', () => controller.step(true)),
      ],
    );
  }

  List<Widget> _filmControls(CastState cast, CastController controller) {
    final progress = cast.progress;
    final duration = progress?.duration ?? Duration.zero;
    final position = progress?.position ?? Duration.zero;
    final max = duration.inMilliseconds.toDouble();
    final value = (_dragging ?? position.inMilliseconds.toDouble()).clamp(0.0, max > 0 ? max : 0.0);
    return [
      if (max > 0) ...[
        Slider(
          value: value,
          max: max,
          onChanged: (v) => setState(() => _dragging = v),
          onChangeEnd: (v) {
            setState(() => _dragging = null);
            controller.seek(Duration(milliseconds: v.round()));
          },
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_clock(Duration(milliseconds: value.round())),
                  style: const TextStyle(color: AppTheme.textSecondary)),
              Text(_clock(duration),
                  style: const TextStyle(color: AppTheme.textSecondary)),
            ],
          ),
        ),
      ],
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _bigButton(Icons.replay_10, 'Back 10 seconds', () {
            final target = position - const Duration(seconds: 10);
            controller.seek(target < Duration.zero ? Duration.zero : target);
          }),
          _bigButton(
            cast.receiver.state == ReceiverState.paused ? Icons.play_arrow : Icons.pause,
            cast.receiver.state == ReceiverState.paused ? 'Play' : 'Pause',
            controller.togglePause,
          ),
          _bigButton(Icons.forward_30, 'Forward 30 seconds', () {
            final target = position + const Duration(seconds: 30);
            controller.seek(duration > Duration.zero && target > duration ? duration : target);
          }),
        ],
      ),
    ];
  }

  Widget _volume(CastState cast, CastController controller) {
    return Row(
      children: [
        const Icon(Icons.volume_down, color: AppTheme.textSecondary),
        Expanded(
          child: Slider(
            value: cast.volume,
            onChanged: controller.setVolume,
          ),
        ),
        const Icon(Icons.volume_up, color: AppTheme.textSecondary),
      ],
    );
  }

  Widget _bigButton(IconData icon, String tooltip, VoidCallback onPressed) {
    return IconButton.filledTonal(
      iconSize: 40,
      padding: const EdgeInsets.all(16),
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }

  static String _clock(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
