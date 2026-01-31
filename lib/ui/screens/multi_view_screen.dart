import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/channel.dart';
import '../../providers/playlist_provider.dart';

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
    for (final slot in _slots) {
      slot.dispose();
    }
    _focusNode.dispose();
    super.dispose();
  }

  void _addChannelToSlot(int slotIndex, Channel channel) async {
    final slot = _slots[slotIndex];
    
    // Dispose existing player if any
    slot.dispose();
    
    // Create new player with buffer configuration
    slot.player = Player(
      configuration: PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024, // 64MB buffer
      ),
    );
    slot.controller = VideoController(slot.player!);
    slot.channel = channel;
    slot.isLoading = true;
    
    setState(() {});
    
    // Set up listeners
    slot.player!.stream.buffering.listen((buffering) {
      if (mounted) {
        setState(() => slot.isLoading = buffering);
      }
    });
    
    slot.player!.stream.error.listen((error) {
      if (mounted && error.isNotEmpty) {
        setState(() => slot.error = error);
      }
    });
    
    // Mute unless this is the active audio slot
    if (slotIndex != _activeAudioSlot) {
      slot.player!.setVolume(0);
    }
    
    try {
      await slot.player!.open(Media(channel.streamUrl));
      
      // Mark as watched
      ref.read(channelStateProvider.notifier).markAsWatched(channel);
    } catch (e) {
      if (mounted) {
        setState(() {
          slot.error = e.toString();
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
            
            // Error overlay
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
                        style: TextStyle(color: Colors.white.withOpacity(0.7)),
                      ),
                    ],
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
  bool isLoading = false;
  String? error;
  
  void dispose() {
    player?.dispose();
    player = null;
    controller = null;
    isLoading = false;
    error = null;
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

