import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/player/stream_tuning.dart';
import '../../core/player/stream_watchdog.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models/channel.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart' show autoReconnectProvider, bufferModeProvider;

class MultiViewScreen extends ConsumerStatefulWidget {
  final List<Channel> initialChannels;

  const MultiViewScreen({
    super.key,
    this.initialChannels = const [],
  });

  @override
  ConsumerState<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _MultiViewScreenState extends ConsumerState<MultiViewScreen> {
  final List<_PlayerSlot> _slots = [];
  int _activeAudioSlot = 0;
  bool _isFullscreen = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    // Initialize 4 slots
    for (int i = 0; i < 4; i++) {
      _slots.add(_PlayerSlot());
    }
    
    // Add initial channels if provided
    for (int i = 0; i < widget.initialChannels.length && i < 4; i++) {
      _addChannelToSlot(i, widget.initialChannels[i]);
    }
  }

  @override
  void dispose() {
    // Restore the system bars in case we left while fullscreen (immersive).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    for (final slot in _slots) {
      slot.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _addChannelToSlot(int slotIndex, Channel channel) async {
    final slot = _slots[slotIndex];

    // Fully tear down whatever was here, watchdog included.
    slot.dispose();

    slot.channel = channel;
    slot.url = channel.streamUrl;
    slot.isLoading = true;
    slot.error = null;
    setState(() {});

    await _createSlotPlayer(slotIndex, slot.url!);

    // Each tile gets its own watchdog. A frozen tile in a 2x2 grid is easy to
    // miss - especially a muted one - so unattended recovery matters more here
    // than in the full-screen player, not less.
    slot.watchdog = StreamWatchdog(
      playerRef: () => slot.player,
      urlRef: () => slot.url ?? '',
      enabled: () => ref.read(autoReconnectProvider),
      onRecreate: (url) => _createSlotPlayer(slotIndex, url),
      onUrlChanged: (url) => slot.url = url,
      onStatus: (status) {
        if (!mounted) return;
        setState(() => slot.status = status);
      },
    )..start();

    ref.read(channelStateProvider.notifier).markAsWatched(channel);
  }

  /// Builds (or rebuilds) the player for a slot and opens [url] on it.
  /// Used both for the initial open and for the watchdog's recreate step.
  Future<void> _createSlotPlayer(int slotIndex, String url) async {
    final slot = _slots[slotIndex];

    await slot.disposePlayer();
    if (mounted) setState(() => slot.isLoading = true);

    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );

    // Publish before tuning - setProperty waits on VideoController
    // initialisation, which needs the Video widget mounted.
    slot.player = player;
    slot.controller = VideoController(player);
    if (mounted) setState(() {});

    await StreamTuning.apply(
      player,
      mode: ref.read(bufferModeProvider),
      isLive: true,
    );

    slot.subscriptions.add(player.stream.buffering.listen((buffering) {
      if (mounted) setState(() => slot.isLoading = buffering);
    }));

    slot.subscriptions.add(player.stream.error.listen((error) {
      if (!mounted || error.isEmpty) return;
      if (ref.read(autoReconnectProvider)) {
        slot.watchdog?.forceRecovery(userInitiated: false);
      } else {
        setState(() => slot.error = StreamTuning.redactUrl(error));
      }
    }));

    // Only the active audio slot is audible.
    if (slotIndex != _activeAudioSlot) {
      await player.setVolume(0);
    }

    if (mounted) setState(() {});

    try {
      await player.open(Media(url));
      slot.watchdog?.noteStreamOpened();
    } catch (e) {
      if (mounted) {
        setState(() {
          slot.error = StreamTuning.redactUrl(e.toString());
          slot.isLoading = false;
        });
      }
    }
  }

  void _removeChannelFromSlot(int slotIndex) {
    final slot = _slots[slotIndex];
    slot.dispose();
    slot.channel = null;
    slot.error = null;
    
    // If this was the audio slot, switch to another
    if (slotIndex == _activeAudioSlot) {
      for (int i = 0; i < 4; i++) {
        if (_slots[i].channel != null && i != slotIndex) {
          _setActiveAudio(i);
          break;
        }
      }
    }
    
    setState(() {});
  }

  void _setActiveAudio(int slotIndex) {
    if (_slots[slotIndex].channel == null) return;
    
    // Mute all slots
    for (int i = 0; i < 4; i++) {
      _slots[i].player?.setVolume(0);
    }
    
    // Unmute selected slot
    _slots[slotIndex].player?.setVolume(100);
    
    setState(() => _activeAudioSlot = slotIndex);
  }

  void _toggleFullscreen() {
    setState(() => _isFullscreen = !_isFullscreen);
    
    if (_isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _showChannelPicker(int slotIndex) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      isScrollControlled: true,
      builder: (context) => _ChannelPickerSheet(
        onChannelSelected: (channel) {
          _addChannelToSlot(slotIndex, channel);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    
    switch (event.logicalKey) {
      case LogicalKeyboardKey.digit1:
        _setActiveAudio(0);
        break;
      case LogicalKeyboardKey.digit2:
        _setActiveAudio(1);
        break;
      case LogicalKeyboardKey.digit3:
        _setActiveAudio(2);
        break;
      case LogicalKeyboardKey.digit4:
        _setActiveAudio(3);
        break;
      case LogicalKeyboardKey.keyF:
        _toggleFullscreen();
        break;
      case LogicalKeyboardKey.escape:
        if (_isFullscreen) {
          _toggleFullscreen();
        } else {
          Navigator.of(context).pop();
        }
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _isFullscreen ? null : AppBar(
          backgroundColor: AppTheme.backgroundColor,
          title: const Text('Multi-View'),
          actions: [
            IconButton(
              icon: const Icon(Icons.fullscreen),
              onPressed: _toggleFullscreen,
              tooltip: 'Fullscreen (F)',
            ),
          ],
        ),
        body: Column(
          children: [
            // Video grid
            Expanded(
              child: _buildVideoGrid(),
            ),
            
            // Controls bar (hidden in fullscreen)
            if (!_isFullscreen) _buildControlsBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoGrid() {
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 16 / 9,
      ),
      itemCount: 4,
      itemBuilder: (context, index) {
        return _buildSlot(index);
      },
    );
  }

  Widget _buildSlot(int index) {
    final slot = _slots[index];
    final isActive = index == _activeAudioSlot;
    
    return GestureDetector(
      onTap: () {
        if (slot.channel != null) {
          _setActiveAudio(index);
        } else {
          _showChannelPicker(index);
        }
      },
      child: Container(
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          border: Border.all(
            color: isActive ? AppTheme.primaryColor : Colors.transparent,
            width: 3,
          ),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Video or empty state
            if (slot.channel != null && slot.controller != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: Video(
                  controller: slot.controller!,
                  controls: NoVideoControls,
                ),
              )
            else
              _buildEmptySlot(index),
            
            // Loading indicator
            if (slot.isLoading)
              const Center(
                child: CircularProgressIndicator(color: AppTheme.primaryColor),
              ),
            
            // Recovery / error overlay. Recovery is reported per tile so a
            // frozen muted stream is visible rather than silently dead.
            if (slot.error != null)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error, color: AppTheme.errorColor),
                      const SizedBox(height: 8),
                      Text(
                        'Error',
                        style:
                            TextStyle(color: Colors.white.withOpacity(0.7)),
                      ),
                    ],
                  ),
                ),
              )
            else if (!slot.status.isHealthy)
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: (slot.status.isRecovering
                              ? AppTheme.primaryColor
                              : AppTheme.warningColor)
                          .withOpacity(0.9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      slot.status.message,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 10),
                    ),
                  ),
                ),
              ),
            
            // Channel info overlay
            if (slot.channel != null)
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Row(
                  children: [
                    // Slot number
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: isActive ? AppTheme.primaryColor : Colors.black54,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isActive)
                            const Icon(Icons.volume_up, color: Colors.white, size: 14),
                          if (isActive)
                            const SizedBox(width: 4),
                          Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    
                    // Channel name
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          slot.channel!.name,
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    
                    const SizedBox(width: 8),
                    
                    // Remove button
                    GestureDetector(
                      onTap: () => _removeChannelFromSlot(index),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Icon(Icons.close, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySlot(int index) {
    return Container(
      color: AppTheme.cardColor,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.add_circle_outline,
              size: 48,
              color: AppTheme.textMuted.withOpacity(0.5),
            ),
            const SizedBox(height: 8),
            Text(
              'Slot ${index + 1}',
              style: TextStyle(
                color: AppTheme.textMuted.withOpacity(0.5),
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Click to add channel',
              style: TextStyle(
                color: AppTheme.textMuted.withOpacity(0.3),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.surfaceColor,
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppTheme.textMuted, size: 16),
          const SizedBox(width: 8),
          Text(
            'Click a video to select its audio • Keys 1-4 to switch audio • F for fullscreen',
            style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
          ),
          const Spacer(),
          Text(
            'Audio: Slot ${_activeAudioSlot + 1}',
            style: const TextStyle(
              color: AppTheme.primaryColor,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerSlot {
  Player? player;
  VideoController? controller;
  Channel? channel;

  /// Tracked separately from [channel] because the watchdog may fall back to
  /// the provider's alternate stream format for this slot.
  String? url;

  bool isLoading = false;
  String? error;

  StreamWatchdog? watchdog;
  WatchdogStatus status =
      const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');

  final List<StreamSubscription> subscriptions = [];

  /// Disposes the player only, leaving the watchdog running - this is what the
  /// recreate recovery step needs.
  Future<void> disposePlayer() async {
    for (final subscription in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();

    final old = player;
    player = null;
    controller = null;
    try {
      await old?.dispose();
    } catch (e) {
      print('Error disposing multi-view player: $e');
    }
  }

  /// Full teardown, including the watchdog.
  void dispose() {
    watchdog?.dispose();
    watchdog = null;
    disposePlayer();
    isLoading = false;
    error = null;
    status = const WatchdogStatus(phase: WatchdogPhase.healthy, message: '');
  }
}

Widget NoVideoControls(VideoState state) => const SizedBox.shrink();

// Channel picker sheet
class _ChannelPickerSheet extends ConsumerStatefulWidget {
  final ValueChanged<Channel> onChannelSelected;

  const _ChannelPickerSheet({required this.onChannelSelected});

  @override
  ConsumerState<_ChannelPickerSheet> createState() => _ChannelPickerSheetState();
}

class _ChannelPickerSheetState extends ConsumerState<_ChannelPickerSheet> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final channelState = ref.watch(channelStateProvider);
    
    final filteredChannels = _searchQuery.isEmpty
        ? channelState.channels
        : channelState.channels
            .where((c) => c.name.toLowerCase().contains(_searchQuery.toLowerCase()))
            .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      maxChildSize: 0.9,
      minChildSize: 0.5,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textMuted.withOpacity(0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            
            // Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Select Channel',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            
            // Search
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                onChanged: (value) => setState(() => _searchQuery = value),
                decoration: InputDecoration(
                  hintText: 'Search channels...',
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: AppTheme.cardColor,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            
            // Channel list
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: filteredChannels.length,
                itemBuilder: (context, index) {
                  final channel = filteredChannels[index];
                  return ListTile(
                    leading: const Icon(Icons.tv, color: AppTheme.textMuted),
                    title: Text(channel.name),
                    subtitle: channel.groupTitle != null
                        ? Text(channel.groupTitle!, style: const TextStyle(fontSize: 12))
                        : null,
                    onTap: () => widget.onChannelSelected(channel),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

