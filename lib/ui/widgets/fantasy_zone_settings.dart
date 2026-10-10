import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/extensions.dart';
import '../../data/models/fantasy.dart';
import '../../providers/fantasy_zone_provider.dart';
import 'tv_text_field.dart';

/// The Settings card for linking Sleeper and checking which games the
/// Fantasy Zone can find channels for.
class FantasyZoneSettings extends ConsumerStatefulWidget {
  const FantasyZoneSettings({super.key});

  @override
  ConsumerState<FantasyZoneSettings> createState() =>
      _FantasyZoneSettingsState();
}

class _FantasyZoneSettingsState extends ConsumerState<FantasyZoneSettings> {
  final _username = TextEditingController();
  bool _checking = false;

  @override
  void dispose() {
    _username.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zone = ref.watch(fantasyZoneProvider);
    final notifier = ref.read(fantasyZoneProvider.notifier);
    final roster = zone.roster;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'A RedZone for your fantasy team. Link your Sleeper account, '
              'then open Fantasy Zone from Live TV: it follows the games your '
              'players are in and switches when one of them gets into the red '
              'zone, breaks a big play or scores.',
              style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
            ),
            const SizedBox(height: 16),
            if (!zone.isLinked) ...[
              Row(
                children: [
                  Expanded(
                    child: TvTextField(
                      controller: _username,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (value) => notifier.link(value),
                      decoration: const InputDecoration(
                        labelText: 'Sleeper username',
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: () => notifier.link(_username.text),
                    child: const Text('Link'),
                  ),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.sports_football,
                      color: AppTheme.primaryColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Sleeper: ${zone.username}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (zone.syncing)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                roster == null
                    ? (zone.syncing ? 'Reading your leagues...' : 'Not synced yet')
                    : '${roster.players.length} players in '
                        '${roster.leagueNames.length} '
                        '${roster.leagueNames.length == 1 ? 'league' : 'leagues'}'
                        '${roster.leagueNames.isEmpty ? '' : ': ${roster.leagueNames.join(', ')}'}',
                style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
              SwitchListTile(
                title: const Text('Starters only'),
                subtitle: const Text(
                  'Follow only the players in your starting lineups.',
                  style: TextStyle(fontSize: 12),
                ),
                value: zone.startersOnly,
                onChanged: zone.syncing ? null : notifier.setStartersOnly,
                activeThumbColor: AppTheme.primaryColor,
                contentPadding: EdgeInsets.zero,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.sync, size: 18),
                    label: const Text('Sync rosters'),
                    onPressed: zone.syncing ? null : notifier.sync,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.search, size: 18),
                    label: const Text('Check games'),
                    onPressed: _checking || roster == null
                        ? null
                        : () async {
                            setState(() => _checking = true);
                            await notifier.poll();
                            if (mounted) setState(() => _checking = false);
                          },
                  ),
                  TextButton(
                    onPressed: () {
                      _username.clear();
                      notifier.link('');
                    },
                    child: const Text('Unlink'),
                  ),
                ],
              ),
              if (zone.games.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final row in zone.games) _GameRow(row),
              ] else if (zone.message != null) ...[
                const SizedBox(height: 12),
                Text(
                  zone.message!,
                  style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
                ),
              ],
            ],
            if (zone.error != null) ...[
              const SizedBox(height: 12),
              Text(
                zone.error!,
                style: const TextStyle(fontSize: 12, color: AppTheme.errorColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One game with the user's players in it, and the channel it maps to. The
/// point is to see a missing match before kickoff, not during the game.
class _GameRow extends StatelessWidget {
  final ZoneGameRow row;

  const _GameRow(this.row);

  @override
  Widget build(BuildContext context) {
    final game = row.game;
    final channel = row.channelName;
    final done = game.state == GameState.post;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: context.isTv ? 120 : 96,
            child: Text(
              game.label,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.players.map((p) => p.name).join(', '),
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  done
                      ? game.detail
                      : '${game.detail} - '
                          '${channel ?? 'no matching channel'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: channel == null && !done
                        ? AppTheme.warningColor
                        : AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
