import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/theme/app_theme.dart';
import '../../data/models/playlist_source.dart';
import '../../data/services/storage_service.dart';
import '../../providers/playlist_provider.dart';
import '../player/enhanced_video_player.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final playlistSources = ref.watch(playlistSourcesProvider);
    final activePlaylist = ref.watch(activePlaylistProvider);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            'Settings',
            style: Theme.of(context).textTheme.displaySmall,
          ),
          const SizedBox(height: 24),

          // Playlists section
          _buildSectionHeader('Playlists', Icons.playlist_play),
          const SizedBox(height: 12),
          
          // Add playlist buttons
          Row(
            children: [
              Expanded(
                child: _ActionCard(
                  icon: Icons.link,
                  title: 'Add M3U URL',
                  subtitle: 'From a remote URL',
                  onTap: () => _showAddM3UDialog(context, isUrl: true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionCard(
                  icon: Icons.folder_open,
                  title: 'Add M3U File',
                  subtitle: 'From local file',
                  onTap: () => _pickM3UFile(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ActionCard(
                  icon: Icons.cloud,
                  title: 'Add Xtream',
                  subtitle: 'Xtream Codes login',
                  onTap: () => _showAddXtreamDialog(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Playlist list
          if (playlistSources.isEmpty)
            _buildEmptyPlaylistView()
          else
            ...playlistSources.map((source) => _PlaylistTile(
              source: source,
              isActive: activePlaylist?.id == source.id,
              onActivate: () {
                ref.read(playlistSourcesProvider.notifier).setActive(source.id);
                _reloadData(source);
              },
              onDelete: () => _confirmDeletePlaylist(source),
            )),

          const SizedBox(height: 32),

          // Playback section
          _buildSectionHeader('Playback', Icons.play_circle_outline),
          const SizedBox(height: 12),
          _buildPlaybackSettings(),

          const SizedBox(height: 32),

          // About section
          _buildSectionHeader('About', Icons.info_outline),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
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
                          size: 32,
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'IPTV Player',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Version 1.0.0',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'A cross-platform IPTV player supporting M3U playlists and Xtream Codes API.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.primaryColor),
        const SizedBox(width: 8),
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ],
    );
  }

  Widget _buildPlaybackSettings() {
    final bufferMode = ref.watch(bufferModeProvider);
    final autoReconnect = ref.watch(autoReconnectProvider);
    final storage = StorageService();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Buffer Mode
            const Text(
              'Buffer Mode',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              'Higher buffer = more stability, but more delay',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),
            
            ...BufferMode.values.map((mode) => RadioListTile<BufferMode>(
              title: Text(mode.label),
              subtitle: Text(
                mode.description,
                style: const TextStyle(fontSize: 12),
              ),
              value: mode,
              groupValue: bufferMode,
              onChanged: (value) {
                if (value != null) {
                  ref.read(bufferModeProvider.notifier).state = value;
                  storage.saveSetting('buffer_mode', value.index);
                }
              },
              activeColor: AppTheme.primaryColor,
              contentPadding: EdgeInsets.zero,
              dense: true,
            )),
            
            const Divider(height: 32),
            
            // Auto Reconnect
            SwitchListTile(
              title: const Text('Auto Reconnect'),
              subtitle: Text(
                'Automatically reconnect when stream freezes or errors',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
              value: autoReconnect,
              onChanged: (value) {
                ref.read(autoReconnectProvider.notifier).state = value;
                storage.saveSetting('auto_reconnect', value);
              },
              activeColor: AppTheme.primaryColor,
              contentPadding: EdgeInsets.zero,
            ),
            
            const Divider(height: 32),
            
            // Info box
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppTheme.primaryColor, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Keyboard Shortcuts in Player',
                          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'R = Manual reconnect • Space = Play/Pause • ↑↓ = Change channel • M = Mute • F = Fullscreen',
                          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
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

  Widget _buildEmptyPlaylistView() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            Icon(
              Icons.playlist_add,
              size: 48,
              color: AppTheme.textMuted.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            const Text(
              'No playlists added yet',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              'Add an M3U playlist or Xtream login to get started',
              style: TextStyle(color: AppTheme.textMuted),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _showAddM3UDialog(BuildContext context, {bool isUrl = true}) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final epgController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isUrl ? 'Add M3U URL' : 'Add M3U Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Playlist Name',
                hintText: 'My IPTV',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'M3U URL',
                hintText: 'http://example.com/playlist.m3u',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: epgController,
              decoration: const InputDecoration(
                labelText: 'EPG URL (Optional)',
                hintText: 'http://example.com/epg.xml',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty && urlController.text.isNotEmpty) {
                ref.read(playlistSourcesProvider.notifier).addM3UPlaylist(
                  nameController.text,
                  urlController.text,
                  epgUrl: epgController.text.isEmpty ? null : epgController.text,
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  void _showAddXtreamDialog(BuildContext context) {
    final nameController = TextEditingController();
    final serverController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Xtream Playlist'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Playlist Name',
                hintText: 'My Provider',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: serverController,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'http://server.com:port',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: usernameController,
              decoration: const InputDecoration(
                labelText: 'Username',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: passwordController,
              decoration: const InputDecoration(
                labelText: 'Password',
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (nameController.text.isNotEmpty &&
                  serverController.text.isNotEmpty &&
                  usernameController.text.isNotEmpty &&
                  passwordController.text.isNotEmpty) {
                ref.read(playlistSourcesProvider.notifier).addXtreamPlaylist(
                  nameController.text,
                  serverController.text,
                  usernameController.text,
                  passwordController.text,
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickM3UFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      final name = result.files.single.name.replaceAll(RegExp(r'\.(m3u8?|M3U8?)$'), '');
      
      ref.read(playlistSourcesProvider.notifier).addM3UPlaylist(name, path);
    }
  }

  void _confirmDeletePlaylist(PlaylistSource source) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Are you sure you want to delete "${source.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
            ),
            onPressed: () {
              ref.read(playlistSourcesProvider.notifier).deletePlaylist(source.id);
              Navigator.pop(context);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _reloadData(PlaylistSource source) {
    ref.read(channelStateProvider.notifier).loadChannels(source);
    ref.read(vodStateProvider.notifier).loadVOD(source);
    ref.read(epgStateProvider.notifier).loadEPG(source.effectiveEpgUrl);
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Icon(icon, size: 32, color: AppTheme.primaryColor),
              const SizedBox(height: 8),
              Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: AppTheme.textMuted,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final PlaylistSource source;
  final bool isActive;
  final VoidCallback onActivate;
  final VoidCallback onDelete;

  const _PlaylistTile({
    required this.source,
    required this.isActive,
    required this.onActivate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (isActive ? AppTheme.primaryColor : AppTheme.textMuted).withOpacity(0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            source.type == PlaylistType.xtream ? Icons.cloud : Icons.list,
            color: isActive ? AppTheme.primaryColor : AppTheme.textMuted,
          ),
        ),
        title: Text(
          source.name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          source.type == PlaylistType.xtream 
              ? 'Xtream Codes' 
              : source.url.length > 40 
                  ? '${source.url.substring(0, 40)}...'
                  : source.url,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textMuted,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.successColor.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Active',
                  style: TextStyle(
                    color: AppTheme.successColor,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (!isActive)
              TextButton(
                onPressed: onActivate,
                child: const Text('Activate'),
              ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
              color: AppTheme.errorColor,
            ),
          ],
        ),
      ),
    );
  }
}

