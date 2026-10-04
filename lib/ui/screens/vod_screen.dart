import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../core/theme/app_theme.dart';
import '../widgets/tv_focusable.dart';
import '../../core/platform/tv_platform.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/vod_item.dart';
import '../../data/models/playlist_source.dart';
import '../../providers/playlist_provider.dart';
import '../player/video_player_screen.dart';
import '../../providers/navigation_provider.dart';
import '../widgets/category_sidebar.dart';
import '../widgets/empty_state.dart';
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
        secondaryLabel: 'Playlist settings',
        onSecondary: () =>
            ref.read(homeTabProvider.notifier).state = HomeTab.settings,
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
                    ? _buildEmptyView(vodState)
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
                      'Movies',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    Text(
                      '${itemCount.grouped} ${itemCount == 1 ? 'title' : 'titles'}',
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
            hintText: 'Search movies...',
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
    // A 1080p TV is only about 960dp wide at density 2.0, and the rail and
    // category sidebar take ~300 of that - six columns would leave ~96dp
    // posters, unreadable from a sofa.
    final crossAxisCount = context.isTv
        ? 3
        : isDesktop
            ? 6
            : (context.isTablet ? 4 : 3);

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
    return EmptyState(
      icon: Icons.playlist_add,
      title: 'No playlist yet',
      message: 'Add an Xtream Codes login to browse movies.',
      actionLabel: 'Add a playlist',
      actionIcon: Icons.add,
      onAction: () =>
          ref.read(homeTabProvider.notifier).state = HomeTab.settings,
    );
  }

  Widget _buildXtreamOnlyView() {
    return const EmptyState(
      icon: Icons.movie_outlined,
      title: 'Movies need an Xtream login',
      message: 'M3U playlists only carry live channels. Add your provider as '
          'an Xtream Codes source in Settings to browse their movies.',
    );
  }

  Widget _buildEmptyView(VODState state) {
    if (_searchQuery.isNotEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches for "$_searchQuery"',
        message: state.selectedCategoryId == null ||
                state.selectedCategoryId == 'all'
            ? 'Check the spelling, or try part of the title.'
            : 'Only this category was searched. Try All Movies.',
      );
    }
    if (state.selectedCategoryId == 'favorites') {
      return const EmptyState(
        icon: Icons.favorite_border,
        title: 'No favorite movies yet',
        message: 'Tap the heart on any poster to keep it here.',
      );
    }
    return const EmptyState(
      icon: Icons.movie_outlined,
      title: 'No movies here',
      message: 'This category is empty. Try another one, or refresh.',
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
    // One focus target per card, not three.
    //
    // The card used to carry an outer GestureDetector (unfocusable), a
    // Positioned.fill InkWell and a favourite IconButton. Directional
    // traversal filters candidates to those beyond the focused node's edge and
    // then prefers the smallest vertical distance - and the next row's heart
    // icon sits higher than its card's centre, so D-pad *down* landed on a
    // heart every single time, never on a card. Collapsing the card to a
    // single node fixes the geometry rather than papering over it.
    return TvFocusable(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      semanticLabel: item.name,
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
            //
            // Excluded from traversal on TV so it cannot win a vertical move
            // against the cards (see the note above). Still reachable by touch
            // and mouse everywhere, and by keyboard off TV.
            Positioned(
              top: 4,
              right: 4,
              child: ExcludeFocus(
                excluding: kIsTv,
                child: IconButton(
                  icon: Icon(
                    item.isFavorite ? Icons.favorite : Icons.favorite_border,
                    color: item.isFavorite ? AppTheme.errorColor : Colors.white,
                    size: 20,
                  ),
                  onPressed: onFavoriteToggle,
                ),
              ),
            ),
            
            // Play overlay.
            //
            // On TV this is decoration only - the card is the focus target, and
            // a second full-bleed node inside it would put two candidates at
            // the same place and make traversal unpredictable. Off TV it keeps
            // its InkWell so the ripple and pointer behaviour are unchanged.
            Positioned.fill(
              child: IgnorePointer(
                ignoring: kIsTv,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: kIsTv ? null : onTap,
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
        // Decode near display size; provider posters are often 1000px+ and
        // a scrolled grid of them is a lot of memory on a TV box.
        memCacheWidth: 400,
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

