import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../../core/player/video_output.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/playlist_source.dart';
import '../../data/services/storage_service.dart';
import '../../core/platform/tv_platform.dart';
import '../../providers/navigation_provider.dart';
import '../../providers/playlist_provider.dart';
import '../../providers/tv_provider.dart';
import '../player/enhanced_video_player.dart';
import '../widgets/tv_text_field.dart';

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
              // Hidden on TV: file_picker fires ACTION_GET_CONTENT, and most
              // Android TV devices ship no DocumentsUI to resolve it, so the
              // picker either fails or returns nothing.
              if (!context.isTv) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: _ActionCard(
                    icon: Icons.folder_open,
                    title: 'Add M3U File',
                    subtitle: 'From local file',
                    onTap: () => _pickM3UFile(),
                  ),
                ),
              ],
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
              // HomeScreen reloads channels, movies and the guide whenever
              // the active playlist changes, so there is nothing to kick here.
              onActivate: () =>
                  ref.read(playlistSourcesProvider.notifier).setActive(source.id),
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
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              AppConstants.appName,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'Version ${AppConstants.appVersion}',
                              style: const TextStyle(
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
    final qualityPolicy = ref.watch(qualityPolicyProvider);
    final tvOverride = ref.watch(tvModeOverrideProvider);
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
              'Higher buffer = more stability, but more delay. Applies to the '
              'running stream immediately.',
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

            // Stream Quality
            const Text(
              'Stream Quality',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            const Text(
              'Many providers carry the same channel at several bitrates. When '
              'the connection cannot keep up, the player can switch to a '
              'smaller one instead of stuttering. Press Q in the player to '
              'choose by hand at any time.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),

            ...QualityPolicy.values.map((policy) => RadioListTile<QualityPolicy>(
              title: Text(policy.label),
              subtitle: Text(
                policy.description,
                style: const TextStyle(fontSize: 12),
              ),
              value: policy,
              groupValue: qualityPolicy,
              onChanged: (value) {
                if (value != null) {
                  ref.read(qualityPolicyProvider.notifier).state = value;
                  storage.saveSetting(
                    AppConstants.settingQualityPolicy,
                    value.index,
                  );
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
                'Detect frozen video and recover on its own, escalating from a '
                'quick resync up to restarting the player. Keeps retrying '
                'rather than giving up.',
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
            
            // Video output - Android only, where one renderer does not suit
            // every device.
            if (VideoOutput.isConfigurable) ...[
              const Divider(height: 32),
              const Text(
                'Video Output',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              const Text(
                'If channels play sound with a black picture, try another '
                'output here. Applies from the next channel you open.',
                style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
              ),
              const SizedBox(height: 12),
              ...VideoOutput.values.map((output) => RadioListTile<VideoOutput>(
                    title: Text(output.label),
                    subtitle: Text(
                      output == VideoOutput.auto
                          ? '${output.description}. Currently: '
                              '${VideoOutput.learned.label}'
                          : output.description,
                      style: const TextStyle(fontSize: 12),
                    ),
                    value: output,
                    groupValue: VideoOutput.preference,
                    onChanged: (value) {
                      if (value == null) return;
                      // A latched global like kIsTv, read when each player is
                      // built, so there is no provider to notify.
                      setState(() => VideoOutput.preference = value);
                      storage.saveSetting(
                        AppConstants.settingVideoOutput,
                        value.index,
                      );
                    },
                    activeColor: AppTheme.primaryColor,
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                  )),
            ],

            const Divider(height: 32),

            // Device layout
            const Text(
              'Device Layout',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              context.isTv
                  ? 'Running the TV layout: larger text, focus highlighting and '
                      'remote navigation. Takes effect on restart.'
                  : 'Running the touch and pointer layout. Forcing the TV '
                      'layout here is how you preview it without a TV. Takes '
                      'effect on restart.',
              style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 12),

            ...TvModeOverride.values.map((mode) => RadioListTile<TvModeOverride>(
              title: Text(mode.label),
              subtitle: Text(
                mode.description,
                style: const TextStyle(fontSize: 12),
              ),
              value: mode,
              groupValue: tvOverride,
              onChanged: (value) {
                if (value == null) return;
                ref.read(tvModeOverrideProvider.notifier).state = value;
                storage.saveSetting(
                  AppConstants.settingTvModeOverride,
                  value.index,
                );
                // Deliberately not applied live. kIsTv is latched before
                // runApp so the very first frame is already the right layout,
                // and the theme, every layout branch and the focus wiring all
                // read it - re-deriving them mid-session would be a much
                // larger change than a restart is worth for a debug control.
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Restart the app to apply the layout change'),
                  ),
                );
              },
              activeColor: AppTheme.primaryColor,
              contentPadding: EdgeInsets.zero,
              dense: true,
            )),

            // Shortcut cheat-sheet. Keyboard keys mean nothing on a phone, and
            // on TV the remote is the input, so each gets its own text.
            if (context.isDesktop || context.isTv) ...[
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
                        Text(
                          context.isTv
                              ? 'Remote Control in Player'
                              : 'Keyboard Shortcuts in Player',
                          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          context.isTv
                              ? 'OK = Show controls / Play/Pause • ↑↓ or CH+/CH- = Change channel • ←→ = Move between controls • Menu or the Options button = Mute, quality, stats, reconnect • Info = Stream stats • Back = Channel list'
                              : 'R = Manual reconnect • Q = Stream quality • I = Stream stats • Space = Play/Pause • ↑↓ = Change channel • M = Mute • F = Fullscreen',
                          style: TextStyle(fontSize: 11, color: AppTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ],
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

    String? error;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        void submit() {
          final url = _normaliseUrl(urlController.text);
          if (url.isEmpty) {
            setDialogState(() => error = 'Enter the playlist URL');
            return;
          }
          final epg = _normaliseUrl(epgController.text);
          final name = nameController.text.trim();
          final isFirst = ref.read(playlistSourcesProvider).isEmpty;
          ref.read(playlistSourcesProvider.notifier).addM3UPlaylist(
            name.isEmpty ? (Uri.tryParse(url)?.host ?? 'My Playlist') : name,
            url,
            epgUrl: epg.isEmpty ? null : epg,
          );
          Navigator.pop(context);
          _onPlaylistAdded(isFirst: isFirst);
        }

        return AlertDialog(
          title: Text(isUrl ? 'Add M3U URL' : 'Add M3U Playlist'),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TvTextField(
                controller: nameController,
                autofocus: context.isTv,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Playlist Name (Optional)',
                  hintText: 'My IPTV',
                ),
              ),
              const SizedBox(height: 16),
              TvTextField(
                controller: urlController,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'M3U URL',
                  hintText: 'http://example.com/playlist.m3u',
                ),
              ),
              const SizedBox(height: 16),
              TvTextField(
                controller: epgController,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => submit(),
                decoration: const InputDecoration(
                  labelText: 'EPG URL (Optional)',
                  hintText: 'http://example.com/epg.xml',
                ),
              ),
              if (error != null) _DialogError(error!),
            ],
          ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: submit,
              child: const Text('Add'),
            ),
          ],
        );
      }),
    );
  }

  void _showAddXtreamDialog(BuildContext context) {
    final nameController = TextEditingController();
    final serverController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();

    String? error;
    var obscurePassword = true;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) {
        void submit() {
          final server = _normaliseUrl(serverController.text);
          // Usernames and passwords keep inner spaces but lose the trailing
          // one an on-screen keyboard's autocomplete loves to add.
          final username = usernameController.text.trim();
          final password = passwordController.text.trim();
          final missing = [
            if (server.isEmpty) 'server URL',
            if (username.isEmpty) 'username',
            if (password.isEmpty) 'password',
          ];
          if (missing.isNotEmpty) {
            setDialogState(() => error = 'Enter the ${missing.join(', ')}');
            return;
          }
          final name = nameController.text.trim();
          final isFirst = ref.read(playlistSourcesProvider).isEmpty;
          ref.read(playlistSourcesProvider.notifier).addXtreamPlaylist(
            name.isEmpty ? (Uri.tryParse(server)?.host ?? 'My Provider') : name,
            server,
            username,
            password,
          );
          Navigator.pop(context);
          _onPlaylistAdded(isFirst: isFirst);
        }

        return AlertDialog(
          title: const Text('Add Xtream Playlist'),
          content: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TvTextField(
                controller: nameController,
                autofocus: context.isTv,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Playlist Name (Optional)',
                  hintText: 'My Provider',
                ),
              ),
              const SizedBox(height: 16),
              TvTextField(
                controller: serverController,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Server URL',
                  hintText: 'http://server.com:port',
                ),
              ),
              const SizedBox(height: 16),
              TvTextField(
                controller: usernameController,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Username',
                ),
              ),
              const SizedBox(height: 16),
              TvTextField(
                controller: passwordController,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => submit(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  // Typing a password with a remote is error-prone enough
                  // without doing it blind.
                  suffixIcon: IconButton(
                    icon: Icon(obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined),
                    tooltip: obscurePassword ? 'Show password' : 'Hide password',
                    onPressed: () => setDialogState(
                        () => obscurePassword = !obscurePassword),
                  ),
                ),
                obscureText: obscurePassword,
              ),
              if (error != null) _DialogError(error!),
            ],
          ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: submit,
              child: const Text('Add'),
            ),
          ],
        );
      }),
    );
  }

  /// Trims what was typed and assumes `http://` when no scheme was given -
  /// providers hand out `server.tld:8080`, and Dio rejects a URL without one.
  static String _normaliseUrl(String input) {
    final url = input.trim();
    if (url.isEmpty) return url;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(url)) return url;
    return 'http://$url';
  }

  /// Confirms the add and takes the user to the channel list, which the shell
  /// is already loading because the active playlist changed.
  void _onPlaylistAdded({required bool isFirst}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(isFirst
            ? 'Playlist added - loading channels'
            : 'Playlist added. Activate it below to switch to it.'),
      ),
    );
    if (isFirst) ref.read(homeTabProvider.notifier).state = HomeTab.liveTv;
  }

  Future<void> _pickM3UFile() async {
    // file_picker 12.x: pickFiles is static (no .platform) and returns the
    // list of picked files directly rather than a nullable result wrapper.
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['m3u', 'm3u8'],
    );

    if (files.isEmpty) return;
    final picked = files.first;
    final path = picked.path;
    if (path == null) return;

    final name = picked.name.replaceAll(RegExp(r'\.(m3u8?|M3U8?)$'), '');
    _onPlaylistAdded(isFirst: ref.read(playlistSourcesProvider).isEmpty);
    await ref.read(playlistSourcesProvider.notifier).addM3UPlaylist(name, path);
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

  /// Where the playlist comes from, without path, query or credentials: the
  /// host for anything remote, the file name for a local file.
  static String _location(PlaylistSource source) {
    final uri = Uri.tryParse(source.url);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return source.url.split(RegExp(r'[/\\]')).last;
  }

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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        // Host only. An M3U URL is usually `get.php?username=..&password=..`,
        // and this screen is exactly what someone screenshots for help.
        subtitle: Text(
          '${source.type == PlaylistType.xtream ? 'Xtream Codes' : 'M3U'}'
          '${_location(source).isEmpty ? '' : ' • ${_location(source)}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
              tooltip: 'Delete playlist',
            ),
          ],
        ),
      ),
    );
  }
}


/// Inline validation message under an add-playlist form.
class _DialogError extends StatelessWidget {
  final String message;

  const _DialogError(this.message);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: AppTheme.errorColor, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.errorColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
