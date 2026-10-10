import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/channel.dart';
import '../../providers/fantasy_zone_provider.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart';
import '../../providers/navigation_provider.dart';
import '../widgets/category_sidebar.dart';
import '../widgets/empty_state.dart';
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

  /// While the Fantasy Zone looks for a game. The first open can take a few
  /// seconds: it reads rosters from Sleeper before the scoreboard.
  bool _opening = false;

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
        secondaryLabel: 'Playlist settings',
        onSecondary: () =>
            ref.read(homeTabProvider.notifier).state = HomeTab.settings,
      );
    }

    final filteredChannels = _searchQuery.isEmpty
        ? channelState.filteredChannels
        : ref.read(channelStateProvider.notifier).searchChannels(_searchQuery);

    return Row(
      children: [
        // Categories sidebar on desktop and TV. TV used to get the phone's
        // horizontal chip row, which on a real subscription is hundreds of
        // categories long and has to be walked one Right press at a time.
        // A vertical list is one Left away from the content and scrolls.
        if (isDesktop || context.isTv)
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
              
              // Category chips (phone and tablet only)
              if (!isDesktop && !context.isTv) _buildCategoryChips(channelState),
              
              // Channel list
              Expanded(
                child: filteredChannels.isEmpty
                    ? _buildEmptyView(channelState)
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
                      '${channelCount.grouped} '
                      '${channelCount == 1 ? 'channel' : 'channels'}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.sports_football),
                onPressed: _opening ? null : _openFantasyZone,
                tooltip: 'Fantasy Zone',
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
    // Watched so the list picks up "now playing" once the guide finishes
    // loading, which is usually after the channels are already on screen.
    ref.watch(epgStateProvider);
    final epg = ref.read(epgStateProvider.notifier);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: channels.length,
      itemBuilder: (context, index) {
        final channel = channels[index];
        final epgId = channel.epgChannelId;
        return _ChannelListTile(
          channel: channel,
          nowPlaying: epgId == null || epgId.isEmpty
              ? null
              : epg.getCurrentProgram(epgId)?.title,
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
    return EmptyState(
      icon: Icons.playlist_add,
      title: 'No playlist yet',
      message: 'Add an M3U playlist or an Xtream Codes login to start watching.',
      actionLabel: 'Add a playlist',
      actionIcon: Icons.add,
      onAction: () =>
          ref.read(homeTabProvider.notifier).state = HomeTab.settings,
    );
  }

  Widget _buildEmptyView(ChannelState state) {
    if (_searchQuery.isNotEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches for "$_searchQuery"',
        message: state.selectedCategoryId == null ||
                state.selectedCategoryId == 'all'
            ? 'Check the spelling, or try part of the channel name.'
            : 'Only this category was searched. Try All Channels.',
      );
    }
    switch (state.selectedCategoryId) {
      case 'favorites':
        return const EmptyState(
          icon: Icons.favorite_border,
          title: 'No favorites yet',
          message: 'Tap the heart on any channel to keep it here.',
        );
      case 'recent':
        return const EmptyState(
          icon: Icons.history,
          title: 'Nothing watched yet',
          message: 'Channels you watch will appear here.',
        );
    }
    return const EmptyState(
      icon: Icons.live_tv,
      title: 'No channels here',
      message: 'This category is empty. Try another one, or refresh the playlist.',
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

  Future<void> _openFantasyZone() async {
    final zone = ref.read(fantasyZoneProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    if (!ref.read(fantasyZoneProvider).isLinked) {
      ref.read(homeTabProvider.notifier).state = HomeTab.settings;
      messenger.showSnackBar(const SnackBar(
        content: Text('Link your Sleeper account under Fantasy Zone first.'),
      ));
      return;
    }

    setState(() => _opening = true);
    messenger.showSnackBar(const SnackBar(
      content: Text("Finding your players' games..."),
      duration: Duration(seconds: 2),
    ));
    final target = await zone.start();
    if (!mounted) return;
    setState(() => _opening = false);

    if (target == null) {
      final state = ref.read(fantasyZoneProvider);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text(state.error ?? state.message ?? 'Nothing to show yet.'),
      ));
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => EnhancedVideoPlayer(
          channel: target.channel,
          isLive: true,
          fantasyZone: true,
          onMinimize: () {
            Navigator.of(context).pop();
            ref.read(miniPlayerProvider.notifier).play(target.channel);
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

  /// Title of the programme on air, when the guide has one.
  final String? nowPlaying;

  const _ChannelListTile({
    required this.channel,
    this.nowPlaying,
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
        // What is on beats which folder the channel lives in, when known.
        subtitle: nowPlaying != null
            ? Row(
                children: [
                  const Icon(Icons.circle, size: 6, color: AppTheme.errorColor),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      nowPlaying!,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : channel.groupTitle != null
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
              tooltip: channel.isFavorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
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
    // Contain, not cover: channel logos are mostly wide wordmarks, and cover
    // cropped "ESPN" down to "SP". The tile behind it gives transparent logos
    // a consistent backing.
    return Container(
      width: 48,
      height: 48,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: channel.logoUrl != null && channel.logoUrl!.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: channel.logoUrl!,
              fit: BoxFit.contain,
              // Decode at display size, not the provider's 1000px original:
              // a long list of full-size logos is a lot of memory on a TV box.
              memCacheHeight: 128,
              placeholder: (context, url) => _monogram(),
              errorWidget: (context, url, error) => _monogram(),
            )
          : _monogram(),
    );
  }

  static final _prefix =
      RegExp(r'^\s*(\|[^|]{1,6}\||\[[^\]]{1,6}\]|[A-Za-z0-9]{2,4}\s*[:|])\s*');

  /// First letter of the channel name, so logo-less channels are still told
  /// apart at a glance instead of being a column of identical TV icons.
  Widget _monogram() {
    // Skip a bouquet prefix - `US: ESPN`, `|UK| BBC One`, `[FR] TF1` - or
    // every channel in a country would get the same letter.
    final name = channel.name
        .replaceFirst(_prefix, '')
        .replaceAll(RegExp(r'^[^A-Za-z0-9]+'), '');
    return Center(
      child: name.isEmpty
          ? const Icon(Icons.tv, color: AppTheme.textMuted)
          : Text(
              name[0].toUpperCase(),
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
    );
  }
}

