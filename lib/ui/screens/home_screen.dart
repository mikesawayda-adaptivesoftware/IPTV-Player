import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
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
  int _selectedIndex = 0;

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
      if (activePlaylist != null) {
        ref.read(channelStateProvider.notifier).loadChannels(activePlaylist);
        ref.read(vodStateProvider.notifier).loadVOD(activePlaylist);
        ref.read(epgStateProvider.notifier).loadEPG(activePlaylist.effectiveEpgUrl);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
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
              if (isDesktop) _buildNavigationRail(),
              
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
                    index: _selectedIndex,
                    children: [
                      for (var i = 0; i < _screens.length; i++)
                        ExcludeFocus(
                          excluding: i != _selectedIndex,
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
      bottomNavigationBar: isDesktop ? null : _buildBottomNavBar(),
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
        tooltip: 'Multi-View (Watch 4 channels)',
        child: const Icon(Icons.grid_view),
      ),
    );
  }

  Widget _buildNavigationRail() {
    return NavigationRail(
      selectedIndex: _selectedIndex,
      onDestinationSelected: (index) {
        setState(() => _selectedIndex = index);
      },
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
              'IPTV',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.bold,
                fontSize: 12,
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
          label: Text('VOD'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.calendar_today_outlined),
          selectedIcon: Icon(Icons.calendar_today),
          label: Text('EPG'),
        ),
        NavigationRailDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: Text('Settings'),
        ),
      ],
    );
  }

  Widget _buildBottomNavBar() {
    return BottomNavigationBar(
      currentIndex: _selectedIndex,
      onTap: (index) {
        setState(() => _selectedIndex = index);
      },
      items: const [
        BottomNavigationBarItem(
          icon: Icon(Icons.tv_outlined),
          activeIcon: Icon(Icons.tv),
          label: 'Live TV',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.movie_outlined),
          activeIcon: Icon(Icons.movie),
          label: 'VOD',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.calendar_today_outlined),
          activeIcon: Icon(Icons.calendar_today),
          label: 'EPG',
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

