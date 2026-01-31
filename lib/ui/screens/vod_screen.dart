import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/vod_item.dart';
import '../../data/models/playlist_source.dart';
import '../../providers/playlist_provider.dart';
import '../player/video_player_screen.dart';
import '../widgets/category_sidebar.dart';
import '../widgets/search_bar_widget.dart';
import '../widgets/loading_widget.dart';
import '../widgets/error_widget.dart';

class VODScreen extends ConsumerStatefulWidget {
  const VODScreen({super.key});

  @override
  ConsumerState<VODScreen> createState() => _VODScreenState();
}

class _VODScreenState extends ConsumerState<VODScreen> {
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final vodState = ref.watch(vodStateProvider);
    final activePlaylist = ref.watch(activePlaylistProvider);
    final isDesktop = context.isDesktop;

    if (activePlaylist == null) {
      return _buildNoPlaylistView();
    }

    if (activePlaylist.type != PlaylistType.xtream) {
      return _buildXtreamOnlyView();
    }

    if (vodState.isLoading) {
      return const LoadingWidget(message: 'Loading movies...');
    }

    if (vodState.error != null) {
      return AppErrorWidget(
        message: vodState.error!,
        onRetry: () => ref.read(vodStateProvider.notifier).loadVOD(activePlaylist),
      );
    }

    final filteredItems = _searchQuery.isEmpty
        ? vodState.filteredItems
        : ref.read(vodStateProvider.notifier).searchVOD(_searchQuery);

    return Row(
      children: [
        // Categories sidebar (desktop only)
        if (isDesktop)
          CategorySidebar(
            categories: vodState.categories,
            selectedCategoryId: vodState.selectedCategoryId,
            onCategorySelected: (id) {
              ref.read(vodStateProvider.notifier).selectCategory(id);
            },
          ),
        
        // Main content
        Expanded(
          child: Column(
            children: [
              // Header with search
              _buildHeader(vodState.categories.length, filteredItems.length),
              
              // Category chips (mobile only)
              if (!isDesktop) _buildCategoryChips(vodState),
              
              // VOD grid
              Expanded(
                child: filteredItems.isEmpty
                    ? _buildEmptyView()
                    : _buildVODGrid(filteredItems),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(int categoryCount, int itemCount) {
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
                      'Movies & Series',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    Text(
                      '$itemCount titles available',
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
                    ref.read(vodStateProvider.notifier).loadVOD(activePlaylist);
                  }
                },
                tooltip: 'Refresh content',
              ),
            ],
          ),
          const SizedBox(height: 16),
          SearchBarWidget(
            hintText: 'Search movies & series...',
            onChanged: (query) {
              setState(() => _searchQuery = query);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChips(VODState state) {
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
                ref.read(vodStateProvider.notifier).selectCategory(category.id);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _buildVODGrid(List<VODItem> items) {
    final isDesktop = context.isDesktop;
    final crossAxisCount = isDesktop ? 6 : (context.isTablet ? 4 : 3);

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: 0.67,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        return _VODCard(
          item: items[index],
          onTap: () => _playVOD(items[index]),
          onFavoriteToggle: () {
            ref.read(vodStateProvider.notifier).toggleFavorite(items[index]);
          },
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
            'Go to Settings to add an Xtream playlist',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }

  Widget _buildXtreamOnlyView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_outlined,
            size: 64,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'VOD Not Available',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Video on Demand is only available with Xtream playlists',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
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
            'No movies found',
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

  void _playVOD(VODItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(
          streamUrl: item.streamUrl,
          title: item.name,
          subtitle: item.year,
          logoUrl: item.posterUrl,
          isLive: false,
        ),
      ),
    );
  }
}

class _VODCard extends StatelessWidget {
  final VODItem item;
  final VoidCallback onTap;
  final VoidCallback onFavoriteToggle;

  const _VODCard({
    required this.item,
    required this.onTap,
    required this.onFavoriteToggle,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: AppTheme.cardColor,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Poster image
            _buildPoster(),
            
            // Gradient overlay
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withOpacity(0.8),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
            ),
            
            // Content
            Positioned(
              left: 8,
              right: 8,
              bottom: 8,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.year != null || item.rating != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (item.year != null)
                          Text(
                            item.year!,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 10,
                            ),
                          ),
                        if (item.year != null && item.rating != null)
                          const SizedBox(width: 8),
                        if (item.rating != null) ...[
                          const Icon(Icons.star, color: Colors.amber, size: 12),
                          const SizedBox(width: 2),
                          Text(
                            item.rating!.toStringAsFixed(1),
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
            
            // Favorite button
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                icon: Icon(
                  item.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: item.isFavorite ? AppTheme.errorColor : Colors.white,
                  size: 20,
                ),
                onPressed: onFavoriteToggle,
              ),
            ),
            
            // Play overlay on hover (desktop)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: const Center(
                    child: Icon(
                      Icons.play_circle_outline,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPoster() {
    if (item.posterUrl != null && item.posterUrl!.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: item.posterUrl!,
        fit: BoxFit.cover,
        placeholder: (context, url) => Container(
          color: AppTheme.surfaceColor,
          child: const Center(
            child: Icon(Icons.movie, color: AppTheme.textMuted, size: 32),
          ),
        ),
        errorWidget: (context, url, error) => Container(
          color: AppTheme.surfaceColor,
          child: const Center(
            child: Icon(Icons.movie, color: AppTheme.textMuted, size: 32),
          ),
        ),
      );
    }

    return Container(
      color: AppTheme.surfaceColor,
      child: const Center(
        child: Icon(Icons.movie, color: AppTheme.textMuted, size: 32),
      ),
    );
  }
}

