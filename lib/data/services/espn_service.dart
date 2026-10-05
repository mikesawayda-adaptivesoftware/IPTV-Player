import 'package:dio/dio.dart';

import '../../core/fantasy/nfl_teams.dart';
import '../models/fantasy.dart';

/// ESPN's public NFL scoreboard: every game this week, with live field
/// position and the latest play.
///
/// Unofficial and undocumented. It has been stable for years and needs no key,
/// but nothing promises it, so [parseScoreboard] reads every field defensively
/// and drops a game rather than throwing.
class EspnService {
  static const _scoreboard =
      'https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard';

  final Dio _dio;

  EspnService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));

  Future<List<NflGame>> scoreboard() async {
    final response = await _dio.get<Map<String, dynamic>>(_scoreboard);
    return parseScoreboard(response.data ?? const {});
  }

  static List<NflGame> parseScoreboard(Map<String, dynamic> json) {
    final games = <NflGame>[];
    for (final event in (json['events'] as List?) ?? const []) {
      if (event is! Map) continue;
      final game = _parseEvent(event);
      if (game != null) games.add(game);
    }
    return games;
  }

  static NflGame? _parseEvent(Map event) {
    final competition = (event['competitions'] as List?)?.firstOrNull;
    if (competition is! Map) return null;

    String? homeKey, awayKey;
    var homeScore = 0, awayScore = 0;
    // ESPN refers to teams by numeric id inside `situation`.
    final keyById = <String, String>{};
    for (final competitor in (competition['competitors'] as List?) ?? const []) {
      if (competitor is! Map) continue;
      final team = competitor['team'];
      if (team is! Map) continue;
      final key = nflTeamKey(team['abbreviation']?.toString());
      if (key == null) continue;
      keyById[team['id'].toString()] = key;
      final score = int.tryParse(competitor['score']?.toString() ?? '') ?? 0;
      if (competitor['homeAway'] == 'home') {
        homeKey = key;
        homeScore = score;
      } else {
        awayKey = key;
        awayScore = score;
      }
    }
    if (homeKey == null || awayKey == null) return null;

    final status = (competition['status'] ?? event['status']) as Map?;
    final type = status?['type'] as Map?;
    final state = switch (type?['state']) {
      'in' => GameState.live,
      'post' => GameState.post,
      _ => GameState.pre,
    };

    final situation = competition['situation'] as Map?;
    final lastPlay = situation?['lastPlay'] as Map?;

    return NflGame(
      id: event['id'].toString(),
      homeKey: homeKey,
      awayKey: awayKey,
      homeScore: homeScore,
      awayScore: awayScore,
      state: state,
      detail: type?['shortDetail']?.toString() ?? '',
      possessionKey: keyById[situation?['possession']?.toString()],
      isRedZone: situation?['isRedZone'] == true,
      downDistance: situation?['downDistanceText']?.toString() ??
          situation?['shortDownDistanceText']?.toString(),
      lastPlay: lastPlay == null ? null : _parsePlay(lastPlay),
    );
  }

  static NflPlay? _parsePlay(Map play) {
    final id = play['id']?.toString();
    if (id == null) return null;
    return NflPlay(
      id: id,
      text: play['text']?.toString() ?? '',
      typeText: (play['type'] as Map?)?['text']?.toString(),
      scoreValue: int.tryParse(play['scoreValue']?.toString() ?? '') ?? 0,
      yards: int.tryParse(play['statYardage']?.toString() ?? ''),
      athleteEspnIds: {
        for (final athlete in (play['athletesInvolved'] as List?) ?? const [])
          if (athlete is Map && athlete['id'] != null) athlete['id'].toString(),
      },
    );
  }
}
