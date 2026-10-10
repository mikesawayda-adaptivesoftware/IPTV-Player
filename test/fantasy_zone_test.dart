import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/fantasy/fantasy_zone.dart';
import 'package:iptv_player/core/fantasy/game_channels.dart';
import 'package:iptv_player/core/fantasy/nfl_teams.dart';
import 'package:iptv_player/data/models/channel.dart';
import 'package:iptv_player/data/models/fantasy.dart';
import 'package:iptv_player/data/services/espn_service.dart';

const allen = FantasyPlayer(
  sleeperId: '4984',
  name: 'Josh Allen',
  position: 'QB',
  teamKey: 'BUF',
  espnId: '3918298',
);
const hill = FantasyPlayer(
  sleeperId: '3321',
  name: 'Tyreek Hill',
  position: 'WR',
  teamKey: 'MIA',
  espnId: '3116406',
);
const lamb = FantasyPlayer(
  sleeperId: '6786',
  name: 'CeeDee Lamb',
  position: 'WR',
  teamKey: 'DAL',
  espnId: '4241389',
);
const bufDefense = FantasyPlayer(
  sleeperId: 'BUF',
  name: 'Bills D/ST',
  position: 'DEF',
  teamKey: 'BUF',
);

NflGame game(
  String id,
  String away,
  String home, {
  GameState state = GameState.live,
  String? possession,
  bool redZone = false,
  int awayScore = 0,
  int homeScore = 0,
  NflPlay? play,
}) {
  return NflGame(
    id: id,
    homeKey: home,
    awayKey: away,
    homeScore: homeScore,
    awayScore: awayScore,
    state: state,
    possessionKey: possession,
    isRedZone: redZone,
    downDistance: redZone ? '1st & Goal at $home 4' : null,
    lastPlay: play,
  );
}

Channel channel(String name, {String? group, String? epg}) => Channel(
      id: name,
      name: name,
      streamUrl: 'http://x/$name',
      groupTitle: group,
      epgChannelId: epg,
    );

void main() {
  group('teamsNamedIn', () {
    test('reads the ways providers name a matchup', () {
      expect(teamsNamedIn('NFL 03: BUF @ MIA'), {'BUF', 'MIA'});
      expect(teamsNamedIn('NFL | Bills vs Dolphins 1:00 PM'), {'BUF', 'MIA'});
      expect(teamsNamedIn('Buffalo Bills at Miami Dolphins'), {'BUF', 'MIA'});
      expect(teamsNamedIn('NFL GAME 7 - KC-LV'), {'KC', 'LV'});
      expect(teamsNamedIn('NYJ vs. NE (HD)'), {'NYJ', 'NE'});
      expect(teamsNamedIn('Green Bay Packers @ Chicago Bears'), {'GB', 'CHI'});
      expect(teamsNamedIn('49ers at Seahawks'), {'SF', 'SEA'});
    });

    test('maps Sleeper and ESPN abbreviations to one key', () {
      expect(nflTeamKey('WAS'), 'WSH');
      expect(nflTeamKey('WSH'), 'WSH');
      expect(nflTeamKey('JAC'), 'JAX');
      expect(nflTeamKey('LA'), 'LAR');
      expect(nflTeamKey(null), isNull);
      expect(nflTeamKey('XYZ'), isNull);
    });

    test('does not read ordinary words as teams', () {
      // NO, NE, TEN and DAL are words or parts of names; bare abbreviations
      // only count inside a matchup.
      expect(teamsNamedIn('NFL 03: NO EVENT'), isEmpty);
      expect(teamsNamedIn('US: TEN NETWORK'), isEmpty);
      expect(teamsNamedIn('UK: SKY SPORTS NFL'), isEmpty);
      expect(teamsNamedIn('BUFATMIA'), isEmpty);
      // Ambiguous cities alone name nobody.
      expect(teamsNamedIn('New York Knicks at Los Angeles Lakers'), isEmpty);
    });

    test('namesGame wants exactly the two teams', () {
      expect(namesGame('BUF @ MIA', 'MIA', 'BUF'), isTrue);
      expect(namesGame('BUF @ MIA', 'MIA', 'NE'), isFalse);
      expect(namesGame('Bills', 'MIA', 'BUF'), isFalse);
      // A doubleheader listing is not reliably this game.
      expect(
        namesGame('Bills vs Dolphins, then Jets vs Patriots', 'MIA', 'BUF'),
        isFalse,
      );
    });
  });

  group('GameChannelMatcher', () {
    final buf = game('1', 'BUF', 'MIA');

    GameChannelMatcher matcher(List<Channel> channels,
            [Map<String, String> guide = const {}]) =>
        GameChannelMatcher(
          channels: channels,
          categoryNames: const {},
          currentProgramme: (id) => guide[id],
        );

    test('finds a per-game channel by name, preferring the NFL category', () {
      final m = matcher([
        channel('Bills vs Dolphins Classic', group: 'Replays'),
        channel('NFL 03: BUF @ MIA', group: 'NFL Game Pass'),
      ]);
      expect(m.channelFor(buf)?.name, 'NFL 03: BUF @ MIA');
    });

    test('falls back to the guide for placeholder names and networks', () {
      final m = matcher(
        [
          channel('NFL 03', group: 'NFL Game Pass', epg: 'nfl3'),
          channel('US: CBS', epg: 'cbs'),
          channel('Cooking Channel', epg: 'cook'),
        ],
        {'nfl3': 'Buffalo Bills at Miami Dolphins'},
      );
      expect(m.channelFor(buf)?.name, 'NFL 03');

      final network = matcher(
        [
          channel('Cooking Channel', epg: 'cook'),
          channel('US: CBS', epg: 'cbs'),
        ],
        {
          'cook': 'Bills vs Dolphins Tailgate Recipes',
          'cbs': 'NFL Football: Bills at Dolphins',
        },
      );
      expect(network.channelFor(buf)?.name, 'US: CBS');
    });

    test('finds nothing rather than the wrong game', () {
      final m = matcher([
        channel('NFL 01: BUF @ NE', group: 'NFL'),
        channel('NFL 02: NO EVENT', group: 'NFL'),
      ]);
      expect(m.channelFor(buf), isNull);
    });
  });

  group('EspnService.parseScoreboard', () {
    test('reads teams, state, situation and the last play', () {
      final games = EspnService.parseScoreboard({
        'events': [
          {
            'id': '401',
            'competitions': [
              {
                'competitors': [
                  {
                    'homeAway': 'home',
                    'score': '14',
                    'team': {'id': '15', 'abbreviation': 'MIA'},
                  },
                  {
                    'homeAway': 'away',
                    'score': '10',
                    'team': {'id': '2', 'abbreviation': 'BUF'},
                  },
                ],
                'status': {
                  'type': {'state': 'in', 'shortDetail': '2nd 3:41'},
                },
                'situation': {
                  'possession': '2',
                  'isRedZone': true,
                  'downDistanceText': '1st & Goal at MIA 4',
                  'lastPlay': {
                    'id': '9',
                    'text': 'J.Allen pass short right to D.Kincaid for 21 yards',
                    'type': {'text': 'Pass Reception'},
                    'statYardage': 21,
                    'athletesInvolved': [
                      {'id': '3918298'},
                      {'id': '4430027'},
                    ],
                  },
                },
              },
            ],
          },
          // Malformed entries are dropped, not thrown on.
          {'id': '402'},
          'nonsense',
        ],
      });

      expect(games, hasLength(1));
      final g = games.single;
      expect(g.label, 'BUF @ MIA');
      expect(g.state, GameState.live);
      expect(g.homeScore, 14);
      expect(g.awayScore, 10);
      expect(g.possessionKey, 'BUF');
      expect(g.isRedZone, isTrue);
      expect(g.lastPlay?.yards, 21);
      expect(g.lastPlay?.athleteEspnIds, contains('3918298'));
    });
  });

  group('FantasyZoneEngine', () {
    late DateTime now;
    late FantasyZoneEngine engine;
    const roster = [allen, hill, lamb, bufDefense];

    setUp(() {
      now = DateTime(2026, 10, 4, 13);
      engine = FantasyZoneEngine(now: () => now);
    });

    ZoneCandidate? step(List<NflGame> games, {Set<String>? channels}) {
      final ranked = engine.rank(games, roster);
      return engine.decide(
        ranked,
        hasChannel: (g) => channels == null || channels.contains(g.id),
      );
    }

    test('opens on the live game with the most of your players', () {
      final pick = step([
        game('1', 'BUF', 'MIA'),
        game('2', 'DAL', 'NYG'),
        game('3', 'KC', 'LV'),
      ]);
      expect(pick?.game.id, '1');
      expect(pick?.reason, ZoneReason.live);
    });

    test('ignores games not on, and games without your players', () {
      expect(step([game('3', 'KC', 'LV')]), isNull);
      expect(step([game('1', 'BUF', 'MIA', state: GameState.pre)]), isNull);
    });

    test('switches to a red zone drive after the dwell, not before', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);

      final redZone = [
        game('1', 'BUF', 'MIA'),
        game('2', 'DAL', 'NYG', possession: 'DAL', redZone: true),
      ];
      now = now.add(const Duration(seconds: 10));
      expect(step(redZone), isNull);

      now = now.add(FantasyZoneEngine.minDwell);
      final pick = step(redZone);
      expect(pick?.game.id, '2');
      expect(pick?.reason, ZoneReason.redZone);
      expect(pick?.headline, contains('CeeDee Lamb'));
    });

    test('a red zone only counts for the team with the ball', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(minutes: 1));
      // NYG in the red zone: Lamb is on the sideline.
      expect(
        step([
          game('1', 'BUF', 'MIA'),
          game('2', 'DAL', 'NYG', possession: 'NYG', redZone: true),
        ]),
        isNull,
      );
    });

    test('never leaves one quiet game for another', () {
      step([game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(minutes: 5));
      // Game 1 has more of your players, but nothing is happening in it.
      expect(step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]), isNull);
    });

    test('a touchdown by your player cuts in immediately', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(seconds: 5));
      final pick = step([
        game('1', 'BUF', 'MIA'),
        game(
          '2',
          'DAL',
          'NYG',
          awayScore: 6,
          play: const NflPlay(
            id: 'p1',
            text: 'D.Prescott pass to C.Lamb for 12 yards, TOUCHDOWN',
            scoreValue: 6,
            athleteEspnIds: {'2577417', '4241389'},
          ),
        ),
      ]);
      expect(pick?.game.id, '2');
      expect(pick?.reason, ZoneReason.score);
      expect(pick?.headline, 'TOUCHDOWN - CeeDee Lamb');
    });

    test('a touchdown from before the zone opened is not news', () {
      final pick = step([
        game(
          '2',
          'DAL',
          'NYG',
          awayScore: 6,
          play: const NflPlay(
            id: 'p1',
            text: 'C.Lamb 12 yd TOUCHDOWN',
            scoreValue: 6,
            athleteEspnIds: {'4241389'},
          ),
        ),
      ]);
      expect(pick?.reason, ZoneReason.live);
    });

    test('a team touchdown the feed did not attribute still counts', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(seconds: 5));
      final pick = step([
        game('1', 'BUF', 'MIA'),
        game('2', 'DAL', 'NYG', awayScore: 7),
      ]);
      expect(pick?.game.id, '2');
      expect(pick?.reason, ZoneReason.score);
    });

    test('falls back to name matching when ESPN ids are missing', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(minutes: 1));
      final pick = step([
        game('1', 'BUF', 'MIA'),
        game(
          '2',
          'DAL',
          'NYG',
          play: const NflPlay(
            id: 'p2',
            text: 'D.Prescott pass deep left to C.Lamb for 41 yards',
            yards: 41,
          ),
        ),
      ]);
      expect(pick?.reason, ZoneReason.bigPlay);
      expect(pick?.headline, contains('41 yds'));
    });

    test('holds a scoring game against a red zone elsewhere', () {
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(seconds: 5));
      step([game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG', awayScore: 7)]);

      now = now.add(const Duration(seconds: 40));
      expect(
        step([
          game('1', 'BUF', 'MIA', possession: 'BUF', redZone: true),
          game('2', 'DAL', 'NYG', awayScore: 7),
        ]),
        isNull,
      );

      // Once the hold runs out, the red zone wins.
      now = now.add(FantasyZoneEngine.scoreHold);
      expect(
        step([
          game('1', 'BUF', 'MIA', possession: 'BUF', redZone: true),
          game('2', 'DAL', 'NYG', awayScore: 7),
        ])?.game.id,
        '1',
      );
    });

    test('moves on when the game on screen ends', () {
      step([game('2', 'DAL', 'NYG')]);
      now = now.add(const Duration(seconds: 5));
      final pick = step([
        game('1', 'BUF', 'MIA'),
        game('2', 'DAL', 'NYG', state: GameState.post),
      ]);
      expect(pick?.game.id, '1');
    });

    test('skips games with no channel', () {
      final pick = step(
        [game('1', 'BUF', 'MIA'), game('2', 'DAL', 'NYG')],
        channels: {'2'},
      );
      expect(pick?.game.id, '2');
    });
  });

  test('FantasyPlayer reads Sleeper player records', () {
    final player = FantasyPlayer.fromSleeper('4984', {
      'full_name': 'Josh Allen',
      'position': 'QB',
      'team': 'BUF',
      'espn_id': 3918298,
    })!;
    expect(player.teamKey, 'BUF');
    expect(player.espnId, '3918298');
    expect(player.playTextName, 'J.Allen');

    final defense = FantasyPlayer.fromSleeper('WAS', {
      'position': 'DEF',
      'team': 'WAS',
      'first_name': 'Washington',
      'last_name': 'Commanders',
    })!;
    expect(defense.teamKey, 'WSH');
    expect(defense.name, 'Commanders D/ST');
    expect(defense.isOffense, isFalse);
  });
}
