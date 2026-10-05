import '../../data/models/channel.dart';
import '../../data/models/fantasy.dart';
import 'nfl_teams.dart';

/// Finds the channel showing an NFL game.
///
/// In order of trust:
///  1. A channel whose own name is the matchup - providers' per-game channels
///     (`NFL 03: BUF @ MIA`). Ones in an NFL category win ties.
///  2. A channel in an NFL category, or a network channel (CBS, FOX, ESPN...),
///     whose current guide programme names both teams - for per-game channels
///     that keep a placeholder name, and for national broadcasts.
///
/// Like the quality grouping, biased toward false negatives: both teams and
/// no third must be named. Not finding a channel costs a switch; finding the
/// wrong one shows the user a different game.
class GameChannelMatcher {
  /// Words that mark a channel worth checking the guide for. Checking every
  /// channel's guide would be tens of thousands of lookups per poll on a big
  /// playlist.
  static final RegExp _guideWorthy = RegExp(
    r'(?<![A-Z])(NFL|CBS|FOX|NBC|ESPN|ABC|PRIME|AMAZON|PEACOCK|NETFLIX|'
    r'SUNDAY TICKET|REDZONE|RED ZONE)(?![A-Z])',
  );

  static final RegExp _nfl = RegExp(r'(?<![A-Z])NFL(?![A-Z])');

  final List<Channel> channels;

  /// Category name by id, for Xtream channels (M3U ones carry `groupTitle`).
  final Map<String, String> categoryNames;

  /// The title of what is on now, by the channel's EPG id, or null.
  final String? Function(String epgChannelId) currentProgramme;

  GameChannelMatcher({
    required this.channels,
    required this.categoryNames,
    required this.currentProgramme,
  });

  /// Matches by name are cached: channel names do not change between polls,
  /// and the scan is over every channel in the playlist.
  final Map<String, Channel?> _byName = {};

  Channel? channelFor(NflGame game) {
    final named = _byName.putIfAbsent(game.id, () => _matchByName(game));
    return named ?? _matchByGuide(game);
  }

  Channel? _matchByName(NflGame game) {
    final home = _hints(game.homeKey);
    Channel? fallback;
    for (final channel in channels) {
      final name = channel.name.toUpperCase();
      // Cheap prefilter before the full tokenising match.
      if (!home.any(name.contains)) continue;
      if (!namesGame(channel.name, game.homeKey, game.awayKey)) continue;
      if (_isNflCategory(channel)) return channel;
      fallback ??= channel;
    }
    return fallback;
  }

  /// The channels worth a guide lookup, NFL categories first. Picked once:
  /// this runs every poll for every game without a named channel.
  late final List<Channel> _guideCandidates = () {
    final nfl = <Channel>[];
    final networks = <Channel>[];
    for (final channel in channels) {
      final epgId = channel.epgChannelId;
      if (epgId == null || epgId.isEmpty) continue;
      if (_isNflCategory(channel)) {
        nfl.add(channel);
      } else if (_guideWorthy.hasMatch(channel.name.toUpperCase())) {
        networks.add(channel);
      }
    }
    return [...nfl, ...networks];
  }();

  Channel? _matchByGuide(NflGame game) {
    for (final channel in _guideCandidates) {
      final title = currentProgramme(channel.epgChannelId!);
      if (title != null && namesGame(title, game.homeKey, game.awayKey)) {
        return channel;
      }
    }
    return null;
  }

  bool _isNflCategory(Channel channel) {
    final category = channel.groupTitle ??
        (channel.categoryId == null ? null : categoryNames[channel.categoryId]);
    return category != null && _nfl.hasMatch(category.toUpperCase());
  }

  /// Substrings, one of which any channel naming this team must contain.
  static List<String> _hints(String key) {
    final team = nflTeam(key);
    if (team == null) return [key];
    return [
      key,
      ...team.aliases,
      team.nickname.toUpperCase(),
      if (team.city != null) team.city!.toUpperCase(),
      if (key == 'SF') 'NINERS',
      if (key == 'TB') 'BUCS',
      if (key == 'NE') 'PATS',
      if (key == 'JAX') 'JAGS',
    ];
  }
}
