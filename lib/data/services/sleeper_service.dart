import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/fantasy.dart';

/// Sleeper's public, read-only API. No login: a username is enough to read
/// that user's leagues and rosters.
///
/// https://docs.sleeper.com - Sleeper asks that `/players/nfl` (about 5 MB)
/// be fetched at most once a day, so the caller caches it.
class SleeperService {
  static const _base = 'https://api.sleeper.app/v1';

  final Dio _dio;

  SleeperService({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ));

  /// The current NFL season, e.g. `2026`.
  Future<String> currentSeason() async {
    final response = await _dio.get<Map<String, dynamic>>('$_base/state/nfl');
    return response.data!['season'].toString();
  }

  /// The user's id, or null when there is no such user. Sleeper answers an
  /// unknown username with a literal `null` body, not a 404.
  Future<String?> userId(String username) async {
    final response = await _dio.get<dynamic>(
      '$_base/user/${Uri.encodeComponent(username.trim())}',
    );
    final data = response.data;
    if (data is! Map) return null;
    return data['user_id']?.toString();
  }

  /// `(id, name)` of each league the user is in this season.
  Future<List<(String, String)>> leagues(String userId, String season) async {
    final response = await _dio.get<List<dynamic>>(
      '$_base/user/$userId/leagues/nfl/$season',
    );
    return [
      for (final league in response.data ?? const [])
        (
          league['league_id'].toString(),
          league['name']?.toString() ?? 'League',
        ),
    ];
  }

  /// The player ids on the user's roster in one league, or null when the user
  /// owns no roster there. Co-owned teams count.
  Future<List<String>?> rosterPlayerIds(
    String leagueId,
    String userId, {
    required bool startersOnly,
  }) async {
    final response =
        await _dio.get<List<dynamic>>('$_base/league/$leagueId/rosters');
    for (final roster in response.data ?? const []) {
      final coOwners = (roster['co_owners'] as List?) ?? const [];
      if (roster['owner_id']?.toString() != userId &&
          !coOwners.map((e) => e.toString()).contains(userId)) {
        continue;
      }
      final ids = (startersOnly ? roster['starters'] : roster['players'])
              as List? ??
          const [];
      // An empty starting slot is the string "0".
      return [
        for (final id in ids)
          if (id != null && id.toString() != '0') id.toString(),
      ];
    }
    return null;
  }

  /// Every player Sleeper knows, cut down to [ids]. Parsed off the UI isolate:
  /// it is several megabytes of JSON, which is a visible stall on a TV box.
  Future<Map<String, FantasyPlayer>> players(Set<String> ids) async {
    final response = await _dio.get<String>(
      '$_base/players/nfl',
      options: Options(responseType: ResponseType.plain),
    );
    return compute(_extractPlayers, (response.data!, ids));
  }
}

Map<String, FantasyPlayer> _extractPlayers((String, Set<String>) args) {
  final (body, ids) = args;
  final all = jsonDecode(body) as Map<String, dynamic>;
  final result = <String, FantasyPlayer>{};
  for (final id in ids) {
    final json = all[id];
    if (json is! Map) continue;
    final player =
        FantasyPlayer.fromSleeper(id, json.cast<String, dynamic>());
    if (player != null) result[id] = player;
  }
  return result;
}
