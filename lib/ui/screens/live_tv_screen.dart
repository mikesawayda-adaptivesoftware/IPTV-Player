import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/channel.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart';
import '../widgets/category_sidebar.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/loading_widget.dart';
import '../widgets/error_widget.dart';
import '../widgets/mini_player.dart';

class LiveTVScreen extends ConsumerStatefulWidget {
  const LiveTVScreen({super.key});

  @override
  ConsumerState<LiveTVScreen> createState() => _LiveTVScreenState();
}

class _LiveTVScreenState extends ConsumerState<LiveTVScreen> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final channelState = ref.watch(channelStateProvider);
    final activePlaylist = ref.watch(activePlaylistProvider);
    final isDesktop = context.isDesktop;

    if (activePlaylist == null) {
      return _buildNoPlaylistView();
    }

    if (channelState.isLoading) {
      return const LoadingWidget(message: 'Loading channels...');
    }

    if (channelState.error != null) {
      return AppErrorWidget(
        message: channelState.error!,
        onRetry: () => ref.read(channelStateProvider.notifier).loadChannels(activePlaylist),
      );
    }

    final filteredChannels = _searchQuery.isEmpty
        ? channelState.filteredChannels
        : ref.read(channelStateProvider.notifier).searchChannels(_searchQuery);

    return Row(
      children: [
        // Categories sidebar (desktop only)
        if (isDesktop)
          CategorySidebar(
            categories: channelState.categories,
            selectedCategoryId: channelState.selectedCategoryId,
            onCategorySelected: (id) {
              ref.read(channelStateProvider.notifier).selectCategory(id);
            },
          ),
        
        // Main content
        Expanded(
          child: Column(
            children: [
              // Header with search
              _buildHeader(channelState.categories.length, filteredChannels.length),
              
              // Category chips (mobile only)
              if (!isDesktop) _buildCategoryChips(channelState),
              
              // Channel list
              Expanded(
                child: filteredChannels.isEmpty
                    ? _buildEmptyView()
                    : _buildChannelList(filteredChannels),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(int categoryCount, int channelCount) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Live TV',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    Text(
                      '$channelCount channels available',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  final activePlaylist = ref.read(activePlaylistProvider);
                  if (activePlaylist != null) {
                    ref.read(channelStateProvider.notifier).loadChannels(activePlaylist);
                  }
                },
                tooltip: 'Refresh channels',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SearchBarWidget(
            hintText: 'Search channels...',
            onChanged: (query) {
              setState(() => _searchQuery = query);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChips(ChannelState state) {
    return SizedBox(
      height: 48,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: state.categories.length,
        itemBuilder: (context, index) {
          final category = state.categories[index];
          final isSelected = category.id == state.selectedCategoryId ||
              (state.selectedCategoryId == null && category.id == 'all');
          
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(category.name),
              selected: isSelected,
              onSelected: (_) {
                ref.read(channelStateProvider.notifier).selectCategory(category.id);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildChannelList(List<Channel> channels) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        return _ChannelListTile(
          channel: channel,
          onTap: () => _playChannel(channel),
          onFavoriteToggle: () {
            ref.read(channelStateProvider.notifier).toggleFavorite(channel);
          },
          onMiniPlayer: () => _playInMiniPlayer(channel),
        );
      },
    );
  }

  Widget _buildNoPlaylistView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.playlist_add,
            size: 64,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No playlist configured',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Go to Settings to add an M3U or Xtream playlist',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.search_off,
            size: 64,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No channels found',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Try adjusting your search or category filter',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  void _playChannel(Channel channel) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EnhancedVideoPlayer(
          channel: channel,
          isLive: true,
          onMinimize: () {
            Navigator.of(context).pop();
            ref.read(miniPlayerProvider.notifier).play(channel);
          },
        ),
      ),
    );
  }

  void _playInMiniPlayer(Channel channel) {
    ref.read(miniPlayerProvider.notifier).play(channel);
  }
}

class _ChannelListTile extends StatelessWidget {
  final Channel channel;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;
  final VoidCallback? onMiniPlayer;

  const _ChannelListTile({
    required this.channel,
    required this.onTap,
    required this.onFavoriteToggle,
    this.onMiniPlayer,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onTap,
        leading: _buildLogo(),
        title: Text(
          channel.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: channel.groupTitle != null
            ? Text(
                channel.groupTitle!,
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
            : null,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                channel.isFavorite ? Icons.favorite : Icons.favorite_border,
                color: channel.isFavorite ? AppTheme.errorColor : AppTheme.textMuted,
              ),
              onPressed: onFavoriteToggle,
              tooltip: 'Favorite',
            ),
            if (onMiniPlayer != null)
              IconButton(
                icon: const Icon(
                  Icons.picture_in_picture_alt,
                  color: AppTheme.textMuted,
                ),
                onPressed: onMiniPlayer,
                tooltip: 'Mini player',
              ),
            const Icon(
              Icons.play_arrow,
              color: AppTheme.primaryColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    if (channel.logoUrl != null && channel.logoUrl!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: CachedNetworkImage(
          imageUrl: channel.logoUrl!,
          width: 48,
          height: 48,
          fit: BoxFit.cover,
          placeholder: (context, url) => Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.tv, color: AppTheme.textMuted),
          ),
          errorWidget: (context, url, error) => Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppTheme.surfaceColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.tv, color: AppTheme.textMuted),
          ),
        ),
      );
    }

    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.tv, color: AppTheme.textMuted),
    );
  }
}

