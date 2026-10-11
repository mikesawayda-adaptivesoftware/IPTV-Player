import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cast/cast_controller.dart';
import '../../core/platform/tv_platform.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/playlist_source.dart';
import '../../providers/cast_provider.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/playlist_provider.dart';
import '../widgets/cast_bar.dart';
import '../widgets/mini_player.dart';
import 'cast_screen.dart';
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

  static const _tabs = [
    (Icons.tv_outlined, Icons.tv, 'Live TV'),
    (Icons.movie_outlined, Icons.movie, 'Movies'),
    (Icons.calendar_today_outlined, Icons.calendar_today, 'Guide'),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
  ];

  /// One per TV rail destination, so Back and the lost-focus fallback can put
  /// focus on the selected tab rather than wherever traversal lands.
  final _railNodes = List.generate(
    _tabs.length,
    (i) => FocusNode(debugLabel: 'TV rail ${_tabs[i].$3}'),
  );

  /// Whether focus is currently inside the TV rail. Tracked so that arriving
  /// in the rail from the content can be told apart from moving within it.
  bool _railActive = false;

  @override
  void initState() {
    super.initState();
    _loadInitialData();
    if (kIsTv) FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    if (kIsTv) FocusManager.instance.removeListener(_onFocusChanged);
    for (final node in _railNodes) {
      node.dispose();
    }
    super.dispose();
  }

  /// Puts focus back on the rail when the shell loses it entirely.
  ///
  /// A focused node that leaves the tree takes focus with it, and on a remote
  /// that strands the user: the next D-pad press has nothing to move from. It
  /// happened whenever a tab swapped its whole body - pressing Refresh replaces
  /// the header holding the button with a loading spinner, picking a playlist
  /// rebuilds every tab - and the only way out was to keep pressing arrows
  /// until something caught focus.
  void _onFocusChanged() {
    if (!_focusIsLost()) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Re-checked a frame later: an autofocus in whatever replaced the lost
      // node (the error screen's Try Again) wins over the rail.
      if (mounted && _focusIsLost()) _focusRail();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _focusIsLost() {
    if (!mounted) return false;
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    if (ref.read(miniPlayerProvider).isExpanded) return false;
    final primary = FocusManager.instance.primaryFocus;
    return primary == null ||
        primary == FocusManager.instance.rootScope ||
        primary == FocusScope.of(context);
  }

  void _focusRail() {
    _railNodes[ref.read(homeTabProvider).index].requestFocus();
  }

  /// Back on TV: content -> rail -> Live TV -> exit.
  ///
  /// Back used to pop HomeScreen from anywhere, so one press from deep in the
  /// channel list closed the app. This is the
  /// Android TV convention: Back climbs to the navigation first, and only
  /// leaves from the home tab's rail item.
  void _onBack() {
    // The expanded mini player has its own PopScope on this route, and both
    // are told about the same pop. It is minimising; leave focus alone.
    if (ref.read(miniPlayerProvider).isExpanded) return;
    final tab = ref.read(homeTabProvider);
    if (!_railActive) {
      _focusRail();
    } else if (tab != HomeTab.liveTv) {
      _selectTab(HomeTab.liveTv.index);
      _railNodes[HomeTab.liveTv.index].requestFocus();
    } else {
      SystemNavigator.pop();
    }
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

    // A cast that ended on its own - the Chromecast switched off or dropped
    // off Wi-Fi - is said here, wherever the person is, with the offer to
    // carry on on the phone. Not started automatically: the phone may be in
    // a pocket, and sound suddenly coming out of it would be worse.
    ref.listen<CastState>(castProvider, (previous, next) {
      if (previous?.active != true || next.active || next.error == null) return;
      final lost = next.lost;
      final position = next.lostPosition;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(next.error!),
        duration: const Duration(seconds: 10),
        action: lost == null
            ? null
            : SnackBarAction(
                label: 'Watch on phone',
                onPressed: () => watchOnPhone(context, ref, lost, position: position),
              ),
      ));
      Future.microtask(() => ref.read(castProvider.notifier).forgetLost());
    });

    final selectedIndex = ref.watch(homeTabProvider).index;
    final isDesktop = context.isDesktop;
    // While the mini player is expanded it draws over this whole Stack, but it
    // is not a route - so without excluding the shell, the rail, the channel
    // list and the FAB all stay live traversal targets *behind* the video, and
    // a D-pad press moves focus to something invisible.
    final playerExpanded = ref.watch(miniPlayerProvider).isExpanded;

    final scaffold = Scaffold(
      body: Stack(
        children: [
          ExcludeFocus(
            excluding: playerExpanded,
            child: Row(
            children: [
              // Navigation Rail for desktop, and its remote-friendly twin on
              // TV. TV used to get the phone's bottom bar, which sits below
              // the channel list - so with D-pad traversal the only way to
              // reach another tab was to scroll to the end of every channel
              // in the playlist.
              if (isDesktop) _buildNavigationRail(selectedIndex),
              if (context.isTv) _buildTvRail(selectedIndex),
              
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
                  // On TV the rail already sits inside the left overscan
                  // margin; insetting the content by it again wasted 48dp.
                  left: !context.isTv,
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
      bottomNavigationBar: isDesktop || context.isTv
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CastBar(),
                _buildBottomNavBar(selectedIndex),
              ],
            ),
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

    if (!context.isTv) return scaffold;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: scaffold,
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

  /// The TV navigation rail.
  ///
  /// Hand-built rather than a [NavigationRail] because the shell needs a
  /// [FocusNode] per destination: Back and the lost-focus fallback land on the
  /// selected tab, and focus entering the rail from the content is redirected
  /// there too.
  ///
  /// Moving along the rail switches tabs, like the Google TV home screen; OK
  /// steps into the tab's content. Switching is cheap - the IndexedStack keeps
  /// every tab built - and it is what lets Right go straight into the tab the
  /// user is looking at, since the inactive ones are excluded from focus.
  Widget _buildTvRail(int selectedIndex) {
    return SafeArea(
      right: false,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (hasFocus) {
          if (!hasFocus) _railActive = false;
        },
        child: SizedBox(
          width: 104,
          child: Column(
            children: [
              const SizedBox(height: 8),
              const Icon(Icons.live_tv, color: AppTheme.primaryColor, size: 28),
              const SizedBox(height: 24),
              for (var i = 0; i < _tabs.length; i++)
                _TvRailItem(
                  focusNode: _railNodes[i],
                  autofocus: i == selectedIndex,
                  icon: i == selectedIndex ? _tabs[i].$2 : _tabs[i].$1,
                  label: _tabs[i].$3,
                  selected: i == selectedIndex,
                  onFocused: () => _onRailItemFocused(i),
                  onTap: () {
                    _selectTab(i);
                    _railNodes[i].requestFocus();
                  },
                  onActivate: () => _railNodes[i]
                      .focusInDirection(TraversalDirection.right),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _onRailItemFocused(int index) {
    final arriving = !_railActive;
    _railActive = true;
    final selected = ref.read(homeTabProvider).index;
    if (index == selected) return;
    if (arriving) {
      // Coming in from the content, traversal picks whichever item is
      // nearest vertically - often not the current tab. Switching to it
      // would change tabs just by pressing Left, so land on the current one.
      _railNodes[selected].requestFocus();
    } else {
      _selectTab(index);
    }
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


class _TvRailItem extends StatefulWidget {
  final FocusNode focusNode;
  final bool autofocus;
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onFocused;
  final VoidCallback onTap;
  final VoidCallback onActivate;

  const _TvRailItem({
    required this.focusNode,
    required this.autofocus,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onFocused,
    required this.onTap,
    required this.onActivate,
  });

  @override
  State<_TvRailItem> createState() => _TvRailItemState();
}

class _TvRailItemState extends State<_TvRailItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final color = widget.selected || _focused
        ? AppTheme.textPrimary
        : AppTheme.textSecondary;
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        if (focused) widget.onFocused();
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onActivate();
            return null;
          },
        ),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: _focused
                ? AppTheme.primaryColor.withValues(alpha: 0.55)
                : widget.selected
                    ? AppTheme.primaryColor.withValues(alpha: 0.15)
                    : null,
            borderRadius: BorderRadius.circular(12),
            border: _focused
                ? Border.all(color: AppTheme.accentColor, width: 3)
                : Border.all(color: Colors.transparent, width: 3),
          ),
          child: Column(
            children: [
              Icon(widget.icon, color: color),
              const SizedBox(height: 4),
              Text(
                widget.label,
                style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
