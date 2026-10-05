import '../../data/models/fantasy.dart';

/// Why a game is worth watching right now. Ordered by urgency.
enum ZoneReason { live, redZone, bigPlay, score }

/// A game ranked by how much the user would want to be watching it.
class ZoneCandidate {
  final NflGame game;
  final ZoneReason reason;
  final List<FantasyPlayer> players;
  final int score;
  final String headline;

  const ZoneCandidate({
    required this.game,
    required this.reason,
    required this.players,
    required this.score,
    required this.headline,
  });
}

/// Something that just happened to one of the user's players. Stays "hot" for
/// a while, so the game holds its rank long enough to be switched to and
/// watched, instead of only for the one poll that saw the play.
class _HotEvent {
  final ZoneReason reason;
  final List<FantasyPlayer> players;
  final String headline;
  final int score;
  final DateTime until;

  const _HotEvent(this.reason, this.players, this.headline, this.score, this.until);
}

/// Decides which game the Fantasy Zone should be showing.
///
/// Fed one ESPN scoreboard per poll. Pure Dart with an injected clock so the
/// switching rules are unit-testable without a network or a player.
///
/// The ranking is RedZone's: a touchdown by one of your players beats a big
/// play, which beats a drive inside the 20, which beats just being on. The
/// switching rules exist to stop it bouncing: a game is held for [minDwell]
/// unless something strictly more urgent happens, and a quiet game is never
/// left for another quiet one.
class FantasyZoneEngine {
  static const scoreHold = Duration(seconds: 90);
  static const bigPlayHold = Duration(seconds: 45);
  static const minDwell = Duration(seconds: 30);
  static const bigPlayYards = 20;

  final DateTime Function() _now;

  FantasyZoneEngine({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final Map<String, _HotEvent> _hot = {};
  final Map<String, String> _lastPlayId = {};
  final Map<String, (int, int)> _lastScore = {};

  String? currentGameId;
  DateTime? _lastSwitch;

  /// Every game with at least one of [players] in it that is worth showing,
  /// best first.
  List<ZoneCandidate> rank(List<NflGame> games, List<FantasyPlayer> players) {
    final now = _now();
    _hot.removeWhere((_, e) => !e.until.isAfter(now));

    final candidates = <ZoneCandidate>[];
    for (final game in games) {
      if (game.state != GameState.live) {
        _forget(game.id);
        continue;
      }
      final mine = [for (final p in players) if (game.involves(p.teamKey)) p];
      if (mine.isEmpty) continue;

      _observe(game, mine, now);

      final hot = _hot[game.id];
      final attackers = [
        for (final p in mine)
          if (p.isOffense && p.teamKey == game.possessionKey) p,
      ];

      final ZoneCandidate candidate;
      if (hot != null) {
        candidate = ZoneCandidate(
          game: game,
          reason: hot.reason,
          players: hot.players,
          score: hot.score,
          headline: hot.headline,
        );
      } else if (game.isRedZone && attackers.isNotEmpty) {
        candidate = ZoneCandidate(
          game: game,
          reason: ZoneReason.redZone,
          players: attackers,
          score: 50 + 5 * attackers.length,
          headline: 'Red zone - ${_names(attackers)}'
              '${game.downDistance == null ? '' : ' - ${game.downDistance}'}',
        );
      } else {
        candidate = ZoneCandidate(
          game: game,
          reason: ZoneReason.live,
          players: mine,
          score: mine.length,
          headline: _names(mine),
        );
      }
      candidates.add(candidate);
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    return candidates;
  }

  /// The candidate to switch to now, or null to stay put.
  ///
  /// [hasChannel] filters out games the playlist has no channel for - ranking
  /// one first would otherwise pin the zone to a game it cannot show.
  ZoneCandidate? decide(
    List<ZoneCandidate> ranked, {
    required bool Function(NflGame game) hasChannel,
  }) {
    final showable = [for (final c in ranked) if (hasChannel(c.game)) c];
    if (showable.isEmpty) return null;
    final best = showable.first;
    final now = _now();

    ZoneCandidate? current;
    for (final c in showable) {
      if (c.game.id == currentGameId) current = c;
    }

    final bool switchNow;
    if (current == null) {
      // Nothing showing, or the game on screen ended or lost all its players.
      switchNow = true;
    } else if (best.game.id == current.game.id) {
      switchNow = false;
    } else if (best.reason == ZoneReason.live) {
      // Never leave one quiet game for another.
      switchNow = false;
    } else if (best.score <= current.score) {
      switchNow = false;
    } else {
      final dwelt = _lastSwitch == null ||
          now.difference(_lastSwitch!) >= minDwell;
      switchNow = dwelt || best.reason == ZoneReason.score;
    }

    if (!switchNow) return null;
    currentGameId = best.game.id;
    _lastSwitch = now;
    return best;
  }

  /// The game on screen, after the user picked it themselves.
  void showing(String? gameId) {
    currentGameId = gameId;
    _lastSwitch = _now();
  }

  void reset() {
    _hot.clear();
    _lastPlayId.clear();
    _lastScore.clear();
    currentGameId = null;
    _lastSwitch = null;
  }

  /// Turns a new play or score change into a hot event.
  ///
  /// The first sighting of a game only records where it stands: a touchdown
  /// that happened before the zone was opened is not news.
  void _observe(NflGame game, List<FantasyPlayer> mine, DateTime now) {
    final play = game.lastPlay;
    final previousPlay = _lastPlayId[game.id];
    final previousScore = _lastScore[game.id];
    if (play != null) _lastPlayId[game.id] = play.id;
    _lastScore[game.id] = (game.homeScore, game.awayScore);
    if (previousScore == null) return;

    if (play != null && play.id != previousPlay) {
      final involved = [for (final p in mine) if (_involved(p, play)) p];
      if (involved.isNotEmpty && play.isTouchdown) {
        _hot[game.id] = _HotEvent(
          ZoneReason.score,
          involved,
          'TOUCHDOWN - ${_names(involved)}',
          100 + 10 * involved.length,
          now.add(scoreHold),
        );
        return;
      }
      if (involved.isNotEmpty && (play.yards ?? 0) >= bigPlayYards) {
        _hot[game.id] = _HotEvent(
          ZoneReason.bigPlay,
          involved,
          'Big play - ${_names(involved)}, ${play.yards} yds',
          60 + 5 * involved.length,
          now.add(bigPlayHold),
        );
        return;
      }
    }

    // A touchdown the play feed did not pin on anyone - polled between the
    // score and the extra point, or ESPN left out the athletes. Credited to
    // the team, so it ranks below a touchdown known to be one of yours.
    for (final team in [game.homeKey, game.awayKey]) {
      final before =
          team == game.homeKey ? previousScore.$1 : previousScore.$2;
      if (game.scoreOf(team) - before < 6) continue;
      if (_hot[game.id]?.reason == ZoneReason.score) continue;
      final onTeam = [
        for (final p in mine)
          if (p.teamKey == team && p.isOffense) p,
      ];
      if (onTeam.isEmpty) continue;
      _hot[game.id] = _HotEvent(
        ZoneReason.score,
        onTeam,
        'Touchdown $team - ${_names(onTeam)}',
        80 + 5 * onTeam.length,
        now.add(scoreHold),
      );
    }
  }

  void _forget(String gameId) {
    _hot.remove(gameId);
    _lastPlayId.remove(gameId);
    _lastScore.remove(gameId);
  }

  static bool _involved(FantasyPlayer player, NflPlay play) {
    final espnId = player.espnId;
    if (espnId != null && play.athleteEspnIds.contains(espnId)) return true;
    if (player.isDefense) return false;
    // ESPN writes `J.Allen pass short right to D.Kincaid`. Only a fallback:
    // the id is exact, and two players can share an initial and surname.
    if (play.athleteEspnIds.isNotEmpty && espnId != null) return false;
    final text = play.text.toUpperCase();
    return text.contains(player.playTextName.toUpperCase()) ||
        text.contains(player.name.toUpperCase());
  }

  static String _names(List<FantasyPlayer> players) {
    if (players.length <= 2) return players.map((p) => p.name).join(', ');
    return '${players.take(2).map((p) => p.name).join(', ')} '
        '+${players.length - 2}';
  }
}
