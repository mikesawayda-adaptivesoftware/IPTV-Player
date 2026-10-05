import '../../core/fantasy/nfl_teams.dart';

/// One player on the user's Sleeper rosters.
class FantasyPlayer {
  /// Sleeper's id. A team defence's id is its abbreviation (`BUF`).
  final String sleeperId;
  final String name;
  final String position;

  /// Canonical [NflTeam.key], or null for a free agent.
  final String? teamKey;

  /// ESPN's athlete id, which Sleeper carries. Lets a play be attributed by id
  /// instead of by guessing at `J.Allen` in the play text.
  final String? espnId;

  const FantasyPlayer({
    required this.sleeperId,
    required this.name,
    required this.position,
    this.teamKey,
    this.espnId,
  });

  bool get isDefense => position == 'DEF';

  /// Players whose team having the ball is good news: everyone but a defence.
  bool get isOffense => !isDefense;

  /// `Josh Allen` -> `J.Allen`, the form ESPN play text uses.
  String get playTextName {
    final parts = name.split(' ');
    if (parts.length < 2) return name;
    return '${parts.first[0]}.${parts.sublist(1).join(' ')}';
  }

  /// From one entry of Sleeper's `/players/nfl` map.
  static FantasyPlayer? fromSleeper(String id, Map<String, dynamic> json) {
    final position = json['position'] as String? ??
        (json['fantasy_positions'] as List?)?.firstOrNull as String?;
    if (position == null) return null;
    final first = json['first_name'] as String? ?? '';
    final last = json['last_name'] as String? ?? '';
    final full = json['full_name'] as String? ?? '$first $last'.trim();
    final teamKey = nflTeamKey(json['team'] as String?);
    final name = position == 'DEF' && teamKey != null
        ? '${nflTeam(teamKey)?.nickname ?? teamKey} D/ST'
        : full;
    final espnId = json['espn_id'];
    return FantasyPlayer(
      sleeperId: id,
      name: name,
      position: position,
      teamKey: teamKey,
      espnId: espnId?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': sleeperId,
        'name': name,
        'position': position,
        'team': teamKey,
        'espn': espnId,
      };

  factory FantasyPlayer.fromJson(Map<String, dynamic> json) => FantasyPlayer(
        sleeperId: json['id'] as String,
        name: json['name'] as String,
        position: json['position'] as String,
        teamKey: json['team'] as String?,
        espnId: json['espn'] as String?,
      );
}

/// Everyone the user cares about, across all their leagues this season.
class FantasyRoster {
  final List<String> leagueNames;
  final List<FantasyPlayer> players;
  final DateTime syncedAt;

  const FantasyRoster({
    required this.leagueNames,
    required this.players,
    required this.syncedAt,
  });

  Map<String, dynamic> toJson() => {
        'leagues': leagueNames,
        'players': [for (final p in players) p.toJson()],
        'syncedAt': syncedAt.toIso8601String(),
      };

  factory FantasyRoster.fromJson(Map<String, dynamic> json) => FantasyRoster(
        leagueNames: (json['leagues'] as List).cast<String>(),
        players: [
          for (final p in json['players'] as List)
            FantasyPlayer.fromJson((p as Map).cast<String, dynamic>()),
        ],
        syncedAt: DateTime.parse(json['syncedAt'] as String),
      );
}

enum GameState { pre, live, post }

/// The latest play in a game, as ESPN's scoreboard reports it.
class NflPlay {
  final String id;
  final String text;
  final String? typeText;

  /// Points the play scored; 0 for an ordinary play.
  final int scoreValue;

  /// Yards gained, when ESPN says.
  final int? yards;

  final Set<String> athleteEspnIds;

  const NflPlay({
    required this.id,
    required this.text,
    this.typeText,
    this.scoreValue = 0,
    this.yards,
    this.athleteEspnIds = const {},
  });

  bool get isTouchdown =>
      scoreValue >= 6 ||
      (typeText?.toUpperCase().contains('TOUCHDOWN') ?? false) ||
      text.toUpperCase().contains('TOUCHDOWN');
}

class NflGame {
  final String id;
  final String homeKey;
  final String awayKey;
  final int homeScore;
  final int awayScore;
  final GameState state;

  /// `Q2 3:41`, `Final`, `Sun 1:00 PM` - for display.
  final String detail;

  /// The team with the ball, while the game is live.
  final String? possessionKey;
  final bool isRedZone;

  /// `1st & Goal at MIA 4`.
  final String? downDistance;

  final NflPlay? lastPlay;

  const NflGame({
    required this.id,
    required this.homeKey,
    required this.awayKey,
    this.homeScore = 0,
    this.awayScore = 0,
    required this.state,
    this.detail = '',
    this.possessionKey,
    this.isRedZone = false,
    this.downDistance,
    this.lastPlay,
  });

  String get label => '$awayKey @ $homeKey';

  bool involves(String? teamKey) =>
      teamKey != null && (teamKey == homeKey || teamKey == awayKey);

  int scoreOf(String teamKey) => teamKey == homeKey ? homeScore : awayScore;
}
