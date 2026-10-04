import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/playlist_source.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/mini_player.dart';
import 'live_tv_screen.dart';
import 'vod_screen.dart';
import 'epg_screen.dart';
import 'multi_view_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _screens = const [
    LiveTVScreen(),
    VODScreen(),
    EPGScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  void _loadInitialData() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final activePlaylist = ref.read(activePlaylistProvider);
      if (activePlaylist != null) _loadPlaylist(activePlaylist);
    });
  }

  void _loadPlaylist(PlaylistSource source) {
    ref.read(channelStateProvider.notifier).loadChannels(source);
    ref.read(vodStateProvider.notifier).loadVOD(source);
    ref.read(epgStateProvider.notifier).loadEPG(source.effectiveEpgUrl);
  }

  @override
  Widget build(BuildContext context) {
    // Reload whenever a different playlist becomes the active one: adding the
    // first playlist, activating another, or deleting the active one. Keyed on
    // the id so re-saving the same source does not refetch everything.
    // Previously only initState loaded anything, so a freshly added playlist
    // showed "No channels found" until the user found the refresh button.
    ref.listen<String?>(activePlaylistProvider.select((p) => p?.id),
        (previous, next) {
      if (next == null || next == previous) return;
      final source = ref.read(activePlaylistProvider);
      if (source != null) _loadPlaylist(source);
    });

    final selectedIndex = ref.watch(homeTabProvider).index;
    final isDesktop = context.isDesktop;
    // While the mini player is expanded it draws over this whole Stack, but it
    // is not a route - so without excluding the shell, the rail, the channel
    // list and the FAB all stay live traversal targets *behind* the video, and
    // a D-pad press moves focus to something invisible.
    final playerExpanded = ref.watch(miniPlayerProvider).isExpanded;

    return Scaffold(
      body: Stack(
        children: [
          ExcludeFocus(
            excluding: playerExpanded,
            child: Row(
            children: [
              // Navigation Rail for desktop
              if (isDesktop) _buildNavigationRail(selectedIndex),
              
              // Main content. SafeArea keeps tab headers clear of the phone's
              // status bar and gesture insets - without it the header (and its
              // refresh button) render under the status bar and can't be
              // tapped. No-op on desktop, which has no system insets. The
              // full-screen player routes are pushed separately and stay
              // edge-to-edge.
              // IndexedStack, not _screens[_selectedIndex]: indexing
              // disposed the outgoing screen's State on every tab change,
              // losing its scroll position and whatever held focus. But
              // IndexedStack keeps every child laid out with a real focus rect
              // and only skips painting, so each inactive child has to be
              // excluded explicitly or the D-pad wanders into Settings while
              // Live TV is on screen.
              Expanded(
                child: SafeArea(
                  child: IndexedStack(
                    index: selectedIndex,
                    children: [
                      for (var i = 0; i < _screens.length; i++)
                        ExcludeFocus(
                          excluding: i != selectedIndex,
                          child: _screens[i],
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          ),

          // Mini player overlay
          const MiniPlayerWidget(),
        ],
      ),
      // Bottom nav for mobile/tablet
      bottomNavigationBar: isDesktop ? null : _buildBottomNavBar(selectedIndex),
      // Not on TV: four simultaneous media_kit players will not run on a TV
      // box, and the FAB is a focusable target floating over the video inside
      // the overscan margin.
      floatingActionButton: context.isTv ? null : FloatingActionButton(
        onPressed: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (context) => const MultiViewScreen()),
          );
        },
        backgroundColor: AppTheme.primaryColor,
        tooltip: 'Multi-View (watch 4 channels)',
        child: const Icon(Icons.grid_view),
      ),
    );
  }

  void _selectTab(int index) {
    ref.read(homeTabProvider.notifier).state = HomeTab.values[index];
  }

  Widget _buildNavigationRail(int selectedIndex) {
    return NavigationRail(
      selectedIndex: selectedIndex,
      onDestinationSelected: _selectTab,
      labelType: NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(
                Icons.live_tv,
                color: AppTheme.primaryColor,
                size: 28,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Definitely\nNot Cable',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 11,
                height: 1.2,
              ),
            ),
          ],
        ),
      ),
      destinations: const [
        NavigationRailDestination(
          icon: Icon(Icons.tv_outlined),
          selectedIcon: Icon(Icons.tv),
          label: Text('Live TV'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.movie_outlined),
          selectedIcon: Icon(Icons.movie),
          label: Text('Movies'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.calendar_today_outlined),
          selectedIcon: Icon(Icons.calendar_today),
          label: Text('Guide'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('Settings'),
        ),
      ],
    );
  }

  Widget _buildBottomNavBar(int selectedIndex) {
    return BottomNavigationBar(
      currentIndex: selectedIndex,
      onTap: _selectTab,
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.tv_outlined),
          activeIcon: Icon(Icons.tv),
          label: 'Live TV',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.movie_outlined),
          activeIcon: Icon(Icons.movie),
          label: 'Movies',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.calendar_today_outlined),
          activeIcon: Icon(Icons.calendar_today),
          label: 'Guide',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.settings_outlined),
          activeIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    );
  }
}

