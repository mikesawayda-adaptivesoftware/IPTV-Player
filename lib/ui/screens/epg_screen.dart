import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/channel.dart';
import '../../data/models/epg_program.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart';
import '../widgets/loading_widget.dart';
import '../widgets/mini_player.dart';

class EPGScreen extends ConsumerStatefulWidget {
  const EPGScreen({super.key});

  @override
  ConsumerState<EPGScreen> createState() => _EPGScreenState();
}

class _EPGScreenState extends ConsumerState<EPGScreen> {
  String? _selectedChannelId;
  String _searchQuery = '';
  bool _searchPrograms = true; // Search both channels and programs
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _verticalScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _verticalScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final channelState = ref.watch(channelStateProvider);
    final epgState = ref.watch(epgStateProvider);
    final activePlaylist = ref.watch(activePlaylistProvider);

    if (activePlaylist == null) {
      return _buildNoPlaylistView();
    }

    if (channelState.isLoading) {
      return const LoadingWidget(message: 'Loading guide...');
    }

    if (channelState.channels.isEmpty) {
      return _buildEmptyView();
    }

    return Column(
      children: [
        // Header
        _buildHeader(),
        
        // EPG Grid
        Expanded(
          child: _buildEPGGrid(channelState.channels, epgState),
        ),
      ],
    );
  }

  Widget _buildHeader() {
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
                      'Program Guide',
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    Text(
                      DateFormat('EEEE, MMMM d').format(DateTime.now()),
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
                    ref.read(epgStateProvider.notifier).loadEPG(activePlaylist.effectiveEpgUrl);
                  }
                },
                tooltip: 'Refresh EPG',
              ),
              IconButton(
                icon: const Icon(Icons.today),
                onPressed: _scrollToNow,
                tooltip: 'Jump to now',
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Search bar
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                  },
                  decoration: InputDecoration(
                    hintText: 'Search channels & programs...',
                    prefixIcon: const Icon(Icons.search, color: AppTheme.textMuted),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: AppTheme.textMuted),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                    filled: true,
                    fillColor: AppTheme.surfaceColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilterChip(
                label: const Text('Shows'),
                selected: _searchPrograms,
                onSelected: (value) {
                  setState(() => _searchPrograms = value);
                },
                avatar: Icon(
                  _searchPrograms ? Icons.check : Icons.tv,
                  size: 16,
                  color: _searchPrograms ? AppTheme.primaryColor : AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEPGGrid(List<Channel> channels, Map<String, List<EPGProgram>> epgData) {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    final endOfDay = startOfDay.add(const Duration(days: 1));
    
    // Calculate time slots (30 min each)
    final timeSlots = <DateTime>[];
    var currentTime = startOfDay;
    while (currentTime.isBefore(endOfDay)) {
      timeSlots.add(currentTime);
      currentTime = currentTime.add(const Duration(minutes: 30));
    }

    // Filter channels that have EPG data
    var channelsWithEpg = channels.where((c) {
      final epgId = c.epgChannelId ?? c.id;
      return epgData.containsKey(epgId);
    }).toList();

    // Apply search filter
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      channelsWithEpg = channelsWithEpg.where((c) {
        // Always search channel name
        if (c.name.toLowerCase().contains(query)) {
          return true;
        }
        // Optionally search program titles
        if (_searchPrograms) {
          final epgId = c.epgChannelId ?? c.id;
          final programs = epgData[epgId] ?? [];
          return programs.any((p) => p.title.toLowerCase().contains(query));
        }
        return false;
      }).toList();
    }

    if (channelsWithEpg.isEmpty && _searchQuery.isEmpty) {
      return _buildNoEPGDataView();
    }

    if (channelsWithEpg.isEmpty && _searchQuery.isNotEmpty) {
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
              'No results for "$_searchQuery"',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              _searchPrograms 
                  ? 'Searched channels and program titles'
                  : 'Searched channel names only',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        // Channel list (fixed)
        SizedBox(
          width: 150,
          child: Column(
            children: [
              // Time header placeholder
              Container(
                height: 40,
                color: AppTheme.surfaceColor,
                padding: const EdgeInsets.all(8),
                alignment: Alignment.centerLeft,
                child: const Text('Channel'),
              ),
              
              // Channel names
              Expanded(
                child: ListView.builder(
                  controller: _verticalScrollController,
                  itemCount: channelsWithEpg.length,
                  itemBuilder: (context, index) {
                    final channel = channelsWithEpg[index];
                    return _buildChannelLabel(channel);
                  },
                ),
              ),
            ],
          ),
        ),
        
        // Program grid (scrollable)
        Expanded(
          child: Column(
            children: [
              // Time header
              SizedBox(
                height: 40,
                child: ListView.builder(
                  controller: _horizontalScrollController,
                  scrollDirection: Axis.horizontal,
                  itemCount: timeSlots.length,
                  itemBuilder: (context, index) {
                    return _buildTimeSlot(timeSlots[index], now);
                  },
                ),
              ),
              
              // Programs
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    // Sync horizontal scroll
                    return false;
                  },
                  child: ListView.builder(
                    controller: _verticalScrollController,
                    itemCount: channelsWithEpg.length,
                    itemBuilder: (context, index) {
                      final channel = channelsWithEpg[index];
                      final epgId = channel.epgChannelId ?? channel.id;
                      final programs = epgData[epgId] ?? [];
                      return _buildChannelPrograms(channel, programs, startOfDay, endOfDay);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChannelLabel(Channel channel) {
    return GestureDetector(
      onTap: () => _playChannel(channel),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.cardColor,
            border: Border(
              bottom: BorderSide(color: AppTheme.textMuted.withOpacity(0.1)),
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppTheme.primaryColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Icon(Icons.play_arrow, size: 14, color: AppTheme.primaryColor),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  channel.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
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

  Widget _buildTimeSlot(DateTime time, DateTime now) {
    final isNow = time.hour == now.hour && 
        (time.minute <= now.minute && now.minute < time.minute + 30);
    
    return Container(
      width: 100,
      height: 40,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isNow ? AppTheme.primaryColor.withOpacity(0.2) : AppTheme.surfaceColor,
        border: Border(
          right: BorderSide(color: AppTheme.textMuted.withOpacity(0.1)),
        ),
      ),
      child: Text(
        time.timeString,
        style: TextStyle(
          fontSize: 12,
          fontWeight: isNow ? FontWeight.bold : FontWeight.normal,
          color: isNow ? AppTheme.primaryColor : AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildChannelPrograms(
    Channel channel,
    List<EPGProgram> programs,
    DateTime startOfDay,
    DateTime endOfDay,
  ) {
    final now = DateTime.now();
    final todayPrograms = programs.where((p) {
      return p.endTime.isAfter(startOfDay) && p.startTime.isBefore(endOfDay);
    }).toList();

    return Container(
      height: 60,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.textMuted.withOpacity(0.1)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: todayPrograms.isEmpty
              ? [_buildNoDataSlot()]
              : todayPrograms.map((program) {
                  return _buildProgramSlot(program, now);
                }).toList(),
        ),
      ),
    );
  }

  Widget _buildProgramSlot(EPGProgram program, DateTime now) {
    final duration = program.duration.inMinutes;
    final width = (duration / 30) * 100.0; // 100 pixels per 30 min
    final isLive = program.isLive;
    final isPast = program.hasEnded;
    
    // Highlight if matches search
    final isSearchMatch = _searchQuery.isNotEmpty && 
        _searchPrograms &&
        program.title.toLowerCase().contains(_searchQuery.toLowerCase());

    return GestureDetector(
      onTap: () => _showProgramDetails(program),
      child: Container(
        width: width.clamp(50.0, 400.0),
        height: 56,
        margin: const EdgeInsets.symmetric(vertical: 2),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: isSearchMatch
              ? AppTheme.accentColor.withOpacity(0.3)
              : isLive 
                  ? AppTheme.primaryColor.withOpacity(0.3)
                  : isPast 
                      ? AppTheme.cardColor.withOpacity(0.5)
                      : AppTheme.cardColor,
          borderRadius: BorderRadius.circular(4),
          border: isSearchMatch
              ? Border.all(color: AppTheme.accentColor, width: 2)
              : isLive 
                  ? Border.all(color: AppTheme.primaryColor, width: 2)
                  : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isLive)
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            Text(
              program.title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: isPast ? AppTheme.textMuted : AppTheme.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${program.startTime.timeString} - ${program.endTime.timeString}',
              style: TextStyle(
                fontSize: 9,
                color: isPast ? AppTheme.textMuted.withOpacity(0.5) : AppTheme.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoDataSlot() {
    return Container(
      width: 200,
      height: 56,
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: AppTheme.cardColor.withOpacity(0.3),
        borderRadius: BorderRadius.circular(4),
      ),
      alignment: Alignment.center,
      child: Text(
        'No program data',
        style: TextStyle(
          fontSize: 11,
          color: AppTheme.textMuted.withOpacity(0.5),
        ),
      ),
    );
  }

  void _showProgramDetails(EPGProgram program) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (program.isLive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: AppTheme.errorColor,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      program.title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${program.startTime.timeString} - ${program.endTime.timeString}',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              if (program.description != null) ...[
                const SizedBox(height: 16),
                Text(
                  program.description!,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
              if (program.category != null) ...[
                const SizedBox(height: 12),
                Chip(
                  label: Text(program.category!),
                  backgroundColor: AppTheme.primaryColor.withOpacity(0.2),
                ),
              ],
              const SizedBox(height: 24),
            ],
          ),
        );
      },
    );
  }

  void _scrollToNow() {
    final now = DateTime.now();
    final minutesSinceStart = now.hour * 60 + now.minute;
    final offset = (minutesSinceStart / 30) * 100.0 - 200; // Center on screen
    
    _horizontalScrollController.animateTo(
      offset.clamp(0.0, _horizontalScrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
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
            Icons.calendar_today,
            size: 64,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No channels loaded',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildNoEPGDataView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.event_busy,
            size: 64,
            color: AppTheme.textMuted.withOpacity(0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No EPG data available',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'EPG data may still be loading or not available for your playlist',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

