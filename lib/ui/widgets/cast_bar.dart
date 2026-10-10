import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_bridge.dart';
import '../../core/cast/cast_controller.dart';
import '../../core/theme/app_theme.dart';
import '../../providers/cast_provider.dart';
import '../screens/cast_screen.dart';

/// The strip along the bottom of the home screen while casting: what is on
/// the TV, a quick control, and Stop. Tapping it opens the cast screen.
class CastBar extends ConsumerWidget {
  const CastBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cast = ref.watch(castProvider);
    final media = cast.media;
    if (!cast.active || media == null) return const SizedBox.shrink();
    final controller = ref.read(castProvider.notifier);

    final status = cast.reconnecting
        ? 'Reconnecting...'
        : cast.unsupported
            ? "Can't play on the Chromecast"
            : cast.phase == CastPhase.connecting
                ? 'Connecting to ${cast.device ?? 'the Chromecast'}...'
                : 'Casting to ${cast.device ?? 'the Chromecast'}';

    return Material(
      color: AppTheme.surfaceColor,
      elevation: 8,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CastScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.cast_connected,
                  color: cast.unsupported ? AppTheme.errorColor : AppTheme.accentColor),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      media.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (media.live)
                IconButton(
                  icon: const Icon(Icons.skip_next, color: AppTheme.textPrimary),
                  tooltip: 'Next channel',
                  onPressed: () => controller.step(true),
                )
              else
                IconButton(
                  icon: Icon(
                    cast.receiver.state == ReceiverState.paused
                        ? Icons.play_arrow
                        : Icons.pause,
                    color: AppTheme.textPrimary,
                  ),
                  tooltip: cast.receiver.state == ReceiverState.paused ? 'Play' : 'Pause',
                  onPressed: controller.togglePause,
                ),
              IconButton(
                icon: const Icon(Icons.close, color: AppTheme.textSecondary),
                tooltip: 'Stop casting',
                onPressed: controller.stop,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
