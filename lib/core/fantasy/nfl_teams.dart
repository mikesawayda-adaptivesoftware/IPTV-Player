/// The 32 NFL teams, and how each one is spelled by Sleeper, by ESPN and in
/// IPTV channel names.
///
/// Sleeper and ESPN disagree on a few abbreviations (`WAS` / `WSH`), and
/// channel names use whatever their provider felt like: `BUF @ MIA`,
/// `Bills vs Dolphins`, `Buffalo Bills at Miami Dolphins`. Everything is
/// resolved to [NflTeam.key] (the ESPN abbreviation) before it is compared.
class NflTeam {
  /// ESPN's abbreviation. The canonical key everywhere in Fantasy Zone.
  final String key;

  /// Other abbreviations that mean this team (Sleeper's, and older ones).
  final List<String> aliases;

  final String nickname;

  /// Null where the city alone is ambiguous: two teams play in New York and
  /// two in Los Angeles.
  final String? city;

  const NflTeam(this.key, this.nickname, this.city, [this.aliases = const []]);
}

const nflTeams = <NflTeam>[
  NflTeam('ARI', 'Cardinals', 'Arizona'),
  NflTeam('ATL', 'Falcons', 'Atlanta'),
  NflTeam('BAL', 'Ravens', 'Baltimore'),
  NflTeam('BUF', 'Bills', 'Buffalo'),
  NflTeam('CAR', 'Panthers', 'Carolina'),
  NflTeam('CHI', 'Bears', 'Chicago'),
  NflTeam('CIN', 'Bengals', 'Cincinnati'),
  NflTeam('CLE', 'Browns', 'Cleveland'),
  NflTeam('DAL', 'Cowboys', 'Dallas'),
  NflTeam('DEN', 'Broncos', 'Denver'),
  NflTeam('DET', 'Lions', 'Detroit'),
  NflTeam('GB', 'Packers', 'Green Bay', ['GNB']),
  NflTeam('HOU', 'Texans', 'Houston'),
  NflTeam('IND', 'Colts', 'Indianapolis'),
  NflTeam('JAX', 'Jaguars', 'Jacksonville', ['JAC']),
  NflTeam('KC', 'Chiefs', 'Kansas City', ['KAN']),
  NflTeam('LV', 'Raiders', 'Las Vegas', ['LVR', 'OAK']),
  NflTeam('LAC', 'Chargers', null, ['SD']),
  NflTeam('LAR', 'Rams', null, ['LA', 'STL']),
  NflTeam('MIA', 'Dolphins', 'Miami'),
  NflTeam('MIN', 'Vikings', 'Minnesota'),
  NflTeam('NE', 'Patriots', 'New England', ['NWE']),
  NflTeam('NO', 'Saints', 'New Orleans', ['NOR']),
  NflTeam('NYG', 'Giants', null),
  NflTeam('NYJ', 'Jets', null),
  NflTeam('PHI', 'Eagles', 'Philadelphia'),
  NflTeam('PIT', 'Steelers', 'Pittsburgh'),
  NflTeam('SF', '49ers', 'San Francisco', ['SFO']),
  NflTeam('SEA', 'Seahawks', 'Seattle'),
  NflTeam('TB', 'Buccaneers', 'Tampa Bay', ['TAM']),
  NflTeam('TEN', 'Titans', 'Tennessee'),
  NflTeam('WSH', 'Commanders', 'Washington', ['WAS']),
];

final Map<String, String> _byAbbreviation = {
  for (final team in nflTeams) ...{
    team.key: team.key,
    for (final alias in team.aliases) alias: team.key,
  },
};

/// The canonical key for an abbreviation from Sleeper or ESPN, or null when it
/// is not an NFL team (a free agent's Sleeper `team` is null or empty).
String? nflTeamKey(String? abbreviation) {
  if (abbreviation == null) return null;
  return _byAbbreviation[abbreviation.trim().toUpperCase()];
}

NflTeam? nflTeam(String key) {
  for (final team in nflTeams) {
    if (team.key == key) return team;
  }
  return null;
}

/// Phrases that name a team on their own: nicknames everywhere, plus the city
/// where only one team plays there. Longest first, so `Green Bay` is consumed
/// before anything shorter could match inside it.
final List<(RegExp, String)> _namePatterns = () {
  final phrases = <(String, String)>[
    for (final team in nflTeams) ...[
      (team.nickname, team.key),
      if (team.city != null) (team.city!, team.key),
    ],
    // "Football Team" and "Redskins" are long gone; "Niners" is not.
    ('Niners', 'SF'),
    ('Bucs', 'TB'),
    ('Pats', 'NE'),
    ('Jags', 'JAX'),
  ]..sort((a, b) => b.$1.length.compareTo(a.$1.length));
  return [
    for (final (phrase, key) in phrases)
      (
        RegExp(
          '(?<![A-Z0-9])${RegExp.escape(phrase.toUpperCase())}(?![A-Z0-9])',
        ),
        key,
      ),
  ];
}();

/// `BUF @ MIA`, `NYJ vs. NE`, `KC-LV`, `SF x SEA`.
///
/// Bare abbreviations only count inside a matchup like this. On their own they
/// collide with ordinary words far too often - `NO`, `NE`, `TEN`, `DAL` -
/// and a channel called `NFL 03: NO EVENT` must not become a Saints game.
final RegExp _abbreviationMatchup = RegExp(
  r'(?<![A-Z0-9])([A-Z]{2,3})(?:\s*[@-]\s*|\s+(?:VS\.?|V\.?|AT|X)\s+)'
  r'([A-Z]{2,3})(?![A-Z0-9])',
);

/// Every team named in [text] - a channel name or a programme title.
///
/// Superscript and accented letters are not handled: channel names carrying a
/// matchup are plain ASCII in practice, and missing a channel only costs a
/// switch, where matching the wrong one would show the wrong game.
Set<String> teamsNamedIn(String text) {
  var upper = text.toUpperCase();
  final found = <String>{};

  for (final (pattern, key) in _namePatterns) {
    if (pattern.hasMatch(upper)) {
      found.add(key);
      upper = upper.replaceAll(pattern, ' ');
    }
  }

  for (final match in _abbreviationMatchup.allMatches(upper)) {
    final a = _byAbbreviation[match.group(1)];
    final b = _byAbbreviation[match.group(2)];
    if (a != null && b != null && a != b) found.addAll([a, b]);
  }
  return found;
}

/// Whether [text] names exactly this game's two teams and no others.
///
/// Exactly, because a channel naming a third team is a doubleheader listing or
/// a studio show, and either way not reliably this game.
bool namesGame(String text, String homeKey, String awayKey) {
  final teams = teamsNamedIn(text);
  return teams.length == 2 &&
      teams.contains(homeKey) &&
      teams.contains(awayKey);
}
