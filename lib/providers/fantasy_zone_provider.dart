import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants/app_constants.dart';
import '../core/fantasy/fantasy_zone.dart';
import '../core/fantasy/game_channels.dart';
import '../core/utils/network_errors.dart';
import '../data/models/channel.dart';
import '../data/models/fantasy.dart';
import '../data/services/espn_service.dart';
import '../data/services/sleeper_service.dart';
import '../data/services/storage_service.dart';
import 'playlist_provider.dart';

/// Where the Fantasy Zone wants the player to be, and why.
class ZoneTarget {
  final Channel channel;
  final NflGame game;
  final ZoneReason reason;
  final String headline;

  /// Bumped on every announcement, so a new headline on the game already
  /// showing (a touchdown in it) still reaches the player's listener.
  final int serial;

  const ZoneTarget({
    required this.channel,
    required this.game,
    required this.reason,
    required this.headline,
    required this.serial,
  });
}

/// A game with the user's players in it, as Settings lists it on "Check
/// games" - mostly so a missing channel match is visible before kickoff.
class ZoneGameRow {
  final NflGame game;
  final List<FantasyPlayer> players;
  final String? channelName;

  const ZoneGameRow(this.game, this.players, this.channelName);
}

class FantasyZoneState {
  final String username;
  final bool startersOnly;
  final FantasyRoster? roster;
  final bool syncing;
  final bool following;
  final ZoneTarget? target;
  final List<ZoneGameRow> games;
  final String? message;
  final String? error;

  const FantasyZoneState({
    this.username = '',
    this.startersOnly = true,
    this.roster,
    this.syncing = false,
    this.following = false,
    this.target,
    this.games = const [],
    this.message,
    this.error,
  });

  bool get isLinked => username.isNotEmpty;

  /// Like every state class here, a copy clears [error] - and [message] -
  /// unless one is passed.
  FantasyZoneState copyWith({
    String? username,
    bool? startersOnly,
    FantasyRoster? roster,
    bool? syncing,
    bool? following,
    ZoneTarget? target,
    bool clearTarget = false,
    List<ZoneGameRow>? games,
    String? message,
    String? error,
  }) {
    return FantasyZoneState(
      username: username ?? this.username,
      startersOnly: startersOnly ?? this.startersOnly,
      roster: roster ?? this.roster,
      syncing: syncing ?? this.syncing,
      following: following ?? this.following,
      target: clearTarget ? null : (target ?? this.target),
      games: games ?? this.games,
      message: message,
      error: error,
    );
  }
}

final sleeperServiceProvider = Provider<SleeperService>((ref) => SleeperService());
final espnServiceProvider = Provider<EspnService>((ref) => EspnService());

final fantasyZoneProvider =
    StateNotifierProvider<FantasyZoneNotifier, FantasyZoneState>((ref) {
  return FantasyZoneNotifier(
    ref,
    ref.watch(sleeperServiceProvider),
    ref.watch(espnServiceProvider),
    ref.watch(playlistStorageProvider),
  );
});

/// Links Sleeper, polls ESPN while the zone is being watched, and publishes
/// [FantasyZoneState.target] for the live player to follow.
class FantasyZoneNotifier extends StateNotifier<FantasyZoneState> {
  /// Polled this often while a game is on. A play takes roughly 40 seconds
  /// snap to snap, so this sees most plays as ESPN's `lastPlay`.
  static const livePoll = Duration(seconds: 10);
  static const idlePoll = Duration(minutes: 1);

  /// Starters change through the week; re-read rosters this often when the
  /// zone opens. Cheap - it is the players file that is expensive.
  static const rosterMaxAge = Duration(hours: 1);
  static const playersMaxAge = Duration(hours: 24);

  final Ref _ref;
  final SleeperService _sleeper;
  final EspnService _espn;
  final StorageService _storage;
  final FantasyZoneEngine _engine = FantasyZoneEngine();

  Timer? _timer;
  int _serial = 0;
  String? _announced;

  GameChannelMatcher? _matcher;
  List<Channel>? _matcherChannels;

  FantasyZoneNotifier(this._ref, this._sleeper, this._espn, this._storage)
      : super(const FantasyZoneState()) {
    state = FantasyZoneState(
      username: _storage.getSetting<String>(
            AppConstants.settingSleeperUsername,
            defaultValue: '',
          ) ??
          '',
      startersOnly: _storage.getSetting<bool>(
            AppConstants.settingSleeperStartersOnly,
            defaultValue: true,
          ) ??
          true,
      roster: _loadRoster(),
    );
  }

  FantasyRoster? _loadRoster() {
    final raw = _storage.getSetting<String>(AppConstants.settingSleeperRoster);
    if (raw == null) return null;
    try {
      return FantasyRoster.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> link(String username) async {
    final trimmed = username.trim();
    await _storage.saveSetting(AppConstants.settingSleeperUsername, trimmed);
    if (trimmed.isEmpty) {
      await _storage.deleteSetting(AppConstants.settingSleeperRoster);
      state = const FantasyZoneState().copyWith(
        startersOnly: state.startersOnly,
      );
      return;
    }
    state = FantasyZoneState(
      username: trimmed,
      startersOnly: state.startersOnly,
    );
    await sync();
  }

  Future<void> setStartersOnly(bool value) async {
    await _storage.saveSetting(AppConstants.settingSleeperStartersOnly, value);
    state = state.copyWith(startersOnly: value);
    if (state.isLinked) await sync();
  }

  /// Re-reads the user's leagues and rosters from Sleeper.
  Future<void> sync() async {
    final username = state.username;
    if (username.isEmpty || state.syncing) return;
    state = state.copyWith(syncing: true);
    try {
      final userId = await _sleeper.userId(username);
      if (userId == null) {
        state = state.copyWith(
          syncing: false,
          error: 'Sleeper has no user called "$username".',
        );
        return;
      }
      final season = await _sleeper.currentSeason();
      final leagues = await _sleeper.leagues(userId, season);

      final names = <String>[];
      final ids = <String>{};
      for (final (id, name) in leagues) {
        final roster = await _sleeper.rosterPlayerIds(
          id,
          userId,
          startersOnly: state.startersOnly,
        );
        if (roster == null) continue;
        names.add(name);
        ids.addAll(roster);
      }

      final players = await _playerInfo(ids);
      final roster = FantasyRoster(
        leagueNames: names,
        players: [
          for (final id in ids)
            if (players[id] != null) players[id]!,
        ]..sort((a, b) => a.name.compareTo(b.name)),
        syncedAt: DateTime.now(),
      );
      await _storage.saveSetting(
        AppConstants.settingSleeperRoster,
        jsonEncode(roster.toJson()),
      );
      state = state.copyWith(syncing: false, roster: roster);
    } catch (e) {
      state = state.copyWith(syncing: false, error: userFacingError(e));
    }
  }

  /// Player details for [ids], from the cache when it has all of them and is
  /// under a day old. Sleeper asks that the full file be fetched at most daily.
  Future<Map<String, FantasyPlayer>> _playerInfo(Set<String> ids) async {
    final cached = <String, FantasyPlayer>{};
    final raw = _storage.getSetting<String>(AppConstants.settingSleeperPlayers);
    final fetchedAt = DateTime.tryParse(_storage.getSetting<String>(
          AppConstants.settingSleeperPlayersFetchedAt,
        ) ??
        '');
    if (raw != null) {
      try {
        final json = jsonDecode(raw) as Map<String, dynamic>;
        json.forEach((id, p) => cached[id] =
            FantasyPlayer.fromJson((p as Map).cast<String, dynamic>()));
      } catch (_) {}
    }
    final fresh = fetchedAt != null &&
        DateTime.now().difference(fetchedAt) < playersMaxAge;
    if (fresh && ids.every(cached.containsKey)) return cached;

    final fetched = await _sleeper.players(ids);
    await _storage.saveSetting(
      AppConstants.settingSleeperPlayers,
      jsonEncode({for (final e in fetched.entries) e.key: e.value.toJson()}),
    );
    await _storage.saveSetting(
      AppConstants.settingSleeperPlayersFetchedAt,
      DateTime.now().toIso8601String(),
    );
    return fetched;
  }

  /// Starts following. Returns where to tune first, or null with
  /// [FantasyZoneState.message] saying why there is nowhere to go.
  Future<ZoneTarget?> start() async {
    if (!state.isLinked) {
      state = state.copyWith(message: 'Link your Sleeper account in Settings.');
      return null;
    }
    _engine.reset();
    _announced = null;
    state = state.copyWith(clearTarget: true);
    final roster = state.roster;
    if (roster == null ||
        DateTime.now().difference(roster.syncedAt) > rosterMaxAge) {
      await sync();
    }
    await poll();
    final target = state.target;
    if (target == null) return null;
    state = state.copyWith(following: true);
    _schedule();
    return target;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    if (mounted) state = state.copyWith(following: false);
  }

  /// The user tuned away by hand. Following stops; the zone does not get to
  /// yank them back on the next poll.
  void pause() => stop();

  /// Resumes following. The user may have tuned anywhere meanwhile, so the
  /// engine forgets what it thought was on screen and the next poll announces
  /// the best game afresh.
  void resume() {
    _engine.currentGameId = null;
    state = state.copyWith(following: true);
    _schedule(immediately: true);
  }

  void _schedule({bool immediately = false}) {
    _timer?.cancel();
    if (!state.following) return;
    final anyLive = state.games.any((g) => g.game.state == GameState.live);
    _timer = Timer(
      immediately ? Duration.zero : (anyLive ? livePoll : idlePoll),
      () async {
        await poll();
        _schedule();
      },
    );
  }

  /// One look at the scoreboard. Also what Settings' "Check games" runs.
  Future<void> poll() async {
    final roster = state.roster;
    if (roster == null) return;
    List<NflGame> games;
    try {
      games = await _espn.scoreboard();
    } catch (e) {
      // A failed poll keeps the last picture; the next one may well succeed.
      if (mounted) state = state.copyWith(error: userFacingError(e));
      return;
    }
    if (!mounted) return;

    final matcher = _currentMatcher();
    final mine = roster.players;
    final rows = [
      for (final game in games)
        if (mine.any((p) => game.involves(p.teamKey)))
          ZoneGameRow(
            game,
            [for (final p in mine) if (game.involves(p.teamKey)) p],
            game.state == GameState.post
                ? null
                : matcher.channelFor(game)?.name,
          ),
    ];

    final ranked = _engine.rank(games, mine);
    final next = _engine.decide(
      ranked,
      hasChannel: (game) => matcher.channelFor(game) != null,
    );

    ZoneTarget? target = state.target;
    if (next != null) {
      target = _announce(next, matcher.channelFor(next.game)!);
    } else if (target != null) {
      // Same game, but something happened in it worth a banner.
      for (final c in ranked) {
        if (c.game.id == target!.game.id &&
            c.reason != ZoneReason.live &&
            '${c.game.id}|${c.headline}' != _announced) {
          target = _announce(c, target.channel);
        }
      }
    }

    String? message;
    if (target == null) {
      final live = rows.where((r) => r.game.state == GameState.live);
      message = live.isEmpty
          ? "None of your players' games are on right now."
          : 'Your players are on in ${live.map((r) => r.game.label).join(', ')}, '
              'but no channel in this playlist matches.';
    }
    state = state.copyWith(games: rows, target: target, message: message);
  }

  ZoneTarget _announce(ZoneCandidate candidate, Channel channel) {
    _announced = '${candidate.game.id}|${candidate.headline}';
    return ZoneTarget(
      channel: channel,
      game: candidate.game,
      reason: candidate.reason,
      headline: candidate.headline,
      serial: ++_serial,
    );
  }

  GameChannelMatcher _currentMatcher() {
    final channelState = _ref.read(channelStateProvider);
    if (_matcher == null || !identical(_matcherChannels, channelState.channels)) {
      final epg = _ref.read(epgStateProvider.notifier);
      _matcherChannels = channelState.channels;
      _matcher = GameChannelMatcher(
        channels: channelState.channels,
        categoryNames: {
          for (final c in channelState.categories) c.id: c.name,
        },
        currentProgramme: (id) => epg.getCurrentProgram(id)?.title,
      );
    }
    return _matcher!;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
