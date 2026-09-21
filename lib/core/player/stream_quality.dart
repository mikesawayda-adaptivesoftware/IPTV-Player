/// Quality degradation - trading picture quality for continuity when the
/// connection (or the decoder) cannot keep up.
///
/// This is the layer that answers "what else could we play instead?". It is
/// deliberately pure: no Flutter, no media_kit, no models from `data/`, so the
/// grouping heuristics can be tested against real playlist names directly.
/// The provider layer adapts [Channel] into [QualityCandidate].
///
/// Three mechanisms, in descending order of how much they actually help:
///
/// 1. **Sibling channels** ([QualityKind.sibling]). Providers routinely list the
///    same channel at several bitrates as separate playlist entries - `ESPN
///    FHD`, `ESPN HD`, `ESPN SD`. Switching between them is the only mechanism
///    here that genuinely reduces bytes on the wire, so it is the primary one.
///
/// 2. **HLS variant cap** ([QualityKind.hlsCap]). Asks the HLS demuxer for the
///    lowest rendition rather than the highest. Only does anything when the
///    provider serves a real master playlist; many Xtream panels serve a
///    single-variant media playlist where there is nothing to choose from.
///
/// 3. **Audio only** ([QualityKind.audioOnly]). Saves decode CPU, and on a real
///    HLS master with an audio-only rendition it saves bandwidth too - but on a
///    muxed MPEG-TS it saves *no* bandwidth at all, because the demuxer still
///    has to read the whole transport stream to keep audio current and simply
///    discards the video packets. It is therefore never auto-selected; see
///    [QualityOption.autoSelectable].
///
/// ## Why the grouping rules are so conservative
///
/// Switching the user to the wrong channel is a much worse failure than failing
/// to find a sibling. A missed sibling means the stream keeps stuttering, which
/// is what was already happening; a false match silently changes what they are
/// watching - possibly the language, possibly the sport. Every rule below is
/// biased toward false negatives, and no rule anywhere does fuzzy or
/// edit-distance matching.
library;

/// How much latitude the player has to change quality by itself.
enum QualityPolicy {
  auto(
    'Automatic',
    'Drop to a lower-bitrate version when the connection struggles, and go '
        'back up when it recovers',
  ),
  manual(
    'Manual only',
    'Never change quality on its own - pick it from the player menu',
  );

  final String label;
  final String description;

  const QualityPolicy(this.label, this.description);
}

/// Which mechanism an option uses to reduce load.
enum QualityKind {
  /// The channel as the user selected it - the top of every ladder.
  source,

  /// A different playlist entry carrying the same channel at a lower bitrate.
  sibling,

  /// The same URL, asking the HLS demuxer for its lowest rendition.
  hlsCap,

  /// The same URL with video decoding switched off.
  audioOnly,
}

/// Largest group the name heuristic is allowed to produce.
///
/// Real channels come in at most a handful of quality variants. A "group" with
/// twenty members is not a quality ladder, it is a normalisation failure that
/// has collapsed unrelated channels together - so refuse it outright rather
/// than pick a victim out of it.
const int maxQualityGroupSize = 6;

/// Shortest acceptable normalised base name.
///
/// Dumped playlists contain bare `HD` / `4K` / `SD` entries used as section
/// headers. Stripping the tier token leaves those empty, which would otherwise
/// collapse every one of them into a single group.
const int minBaseNameLength = 3;

/// Tier tokens and their relative quality, higher being better.
///
/// The numbers only need to order correctly against each other; they are not
/// bitrates. Deliberately absent:
///
/// - `360`, which collides with real channel names (`CNN 360`, `Sky Sport 360`,
///   `Ligue 1 360`) far more often than it marks a rendition.
/// - `H265` / `HEVC` / `H264`, which are codecs rather than tiers. HEVC 1080p
///   is a *lower* bitrate but a much heavier decode, and this app force-disables
///   hardware acceleration, so calling it a downgrade would often be the wrong
///   direction.
/// - `RAW`, which describes the container, and `BACKUP` / `ALT`, which describe
///   a different origin at the *same* quality. Switching origin is
///   `StreamTuning.alternateUrl`'s job, not this file's.
///
/// Because none of those are tier tokens, a name containing one simply keeps it
/// in its base name and therefore never groups with a name that lacks it.
/// Spaced in tens so a new tier can be slotted between two existing ones
/// without renumbering, and so distinct resolutions never tie. They tied at
/// first, which let a real ladder come out ordered `720 -> 480 -> 576` - a
/// "downgrade" that steps back up.
const Map<String, int> _tierTokens = {
  '8K': 80,
  '4320': 80,
  'UHD': 70,
  '4K': 70,
  '2160': 70,
  'FHD': 60,
  '1080': 60,
  'HD': 50,
  '720': 50,
  'HQ': 50,
  // `SD` is imprecise by nature - anywhere from 480 to 576 - so it sits above
  // both of the explicit resolutions rather than pretending to equal one.
  'SD': 40,
  '576': 35,
  '480': 30,
  'LQ': 20,
};

/// A word: a maximal run of letters and digits.
///
/// Matching on word boundaries rather than substrings is what keeps `HDNet`,
/// `SDTV`, `MTV 80s` and `CNN 360` intact. A `replaceAll('HD', '')` would eat
/// the middle of all of them.
final RegExp _wordPattern = RegExp(r'[A-Za-z0-9]+');

/// A resolution written with a scan-type suffix: `1080p`, `720i`.
final RegExp _scanSuffixPattern = RegExp(r'^(\d+)[PI]$');

/// Superscript and modifier-letter forms, folded to ASCII before anything else
/// looks at a name.
///
/// Real providers write tiers in these rather than plain letters - `SKY SPORTS
/// NEWS ᴴᴰ`, `LA 1 ᵁᴴᴰ ³⁸⁴⁰ᴾ`, `SPORTSNET ONE ᴿᴬᵂ`, `SKY SPORTS MIX ᴴᴰ ʰᵉᵛᶜ`.
/// Unfolded, `[A-Za-z0-9]+` cannot see them at all, so every one of those reads
/// as untagged. Each of these is a single UTF-16 code unit, so folding is
/// position-preserving and the offset arithmetic below still works.
const Map<String, String> _asciiFolds = {
  'ᴬ': 'A', 'ᴮ': 'B', 'ᶜ': 'C', 'ᴰ': 'D', 'ᴱ': 'E', 'ᶠ': 'F', 'ᴳ': 'G',
  'ᴴ': 'H', 'ᴵ': 'I', 'ᴶ': 'J', 'ᴷ': 'K', 'ᴸ': 'L', 'ᴹ': 'M', 'ᴺ': 'N',
  'ᴼ': 'O', 'ᴾ': 'P', 'ᴿ': 'R', 'ˢ': 'S', 'ᵀ': 'T', 'ᵁ': 'U', 'ⱽ': 'V',
  'ᵂ': 'W',
  'ᵃ': 'A', 'ᵇ': 'B', 'ᵈ': 'D', 'ᵉ': 'E', 'ᵍ': 'G', 'ʰ': 'H', 'ⁱ': 'I',
  'ʲ': 'J', 'ᵏ': 'K', 'ˡ': 'L', 'ᵐ': 'M', 'ⁿ': 'N', 'ᵒ': 'O', 'ᵖ': 'P',
  'ʳ': 'R', 'ᵗ': 'T', 'ᵘ': 'U', 'ᵛ': 'V', 'ʷ': 'W', 'ˣ': 'X', 'ʸ': 'Y',
  'ᶻ': 'Z',
  '⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4',
  '⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9',
  '⁽': '(', '⁾': ')',
};

/// A leading bouquet label: `IT:`, `CA EN:`, `SKYGO:`, `BE-VIP:`, `|US|`, `[UK]`.
///
/// Tier words are never taken from here, because providers name their *bouquets*
/// after quality too. This subscription has 154 channels prefixed `4K:` or
/// `8K:` - the provider is literally called "World 8K" - and without this every
/// one of them ranked as a 4K/8K rendition of whatever followed.
final RegExp _bracketedPrefixPattern =
    RegExp(r'^\s*[|\[(]([^|\])]{1,14})[|\])]');

/// A timeshift channel: `ITV 2+1`, `HGTV +1`, `... +24`.
///
/// Not a quality variant - a different point in the schedule. Switching someone
/// from `ITV 2 HD` to `ITV 2+1` would move them an hour through the programme,
/// which is a far worse outcome than a stutter, so these are excluded from
/// grouping entirely. 78 channels here carry one.
final RegExp _timeshiftPattern = RegExp(r'\+\s*\d+');

final RegExp _emptyBracketsPattern = RegExp(r'\(\s*\)|\[\s*\]|\{\s*\}');
final RegExp _whitespacePattern = RegExp(r'\s+');
final RegExp _edgeJunkPattern = RegExp(r'^[\s\-:,.]+|[\s\-:,.]+$');

/// One playlist entry, reduced to just what quality grouping needs.
///
/// The provider layer builds these from `Channel`. Keeping `core/` free of
/// `data/` models is the existing convention here, and it also means the tests
/// for this file need no Hive.
class QualityCandidate {
  /// The originating `Channel.id`. Opaque - only ever compared, never parsed.
  ///
  /// Note this is not stable across playlist reloads for M3U sources, where
  /// `M3UParser` assigns a fresh uuid on every parse. That is fine because the
  /// index is rebuilt on every load and nothing here is persisted.
  final String id;

  /// The display name exactly as the playlist gave it.
  final String name;

  final String url;

  /// `tvg-id` for M3U, `epg_channel_id` for Xtream. Empty strings are treated
  /// as absent, because providers return `""` at least as often as `null`.
  final String? tvgId;

  /// `categoryId` or `groupTitle` - whichever the source populates.
  final String? category;

  const QualityCandidate({
    required this.id,
    required this.name,
    required this.url,
    this.tvgId,
    this.category,
  });
}

/// One concrete thing that can be played instead of the source.
class QualityOption {
  /// What to show the user. For siblings this is the target's real playlist
  /// name, because these labels lie often enough that paraphrasing them would
  /// mislead - `ESPN SD` is frequently the same feed renamed.
  final String label;

  final QualityKind kind;

  /// URL to open. Equal to the current URL for [QualityKind.hlsCap] and
  /// [QualityKind.audioOnly], which change how it is played rather than what.
  final String url;

  /// Value for mpv's `hls-bitrate`. `min` asks for the lowest rendition.
  ///
  /// This is a two-position switch, not a ladder: neither mpv nor FFmpeg
  /// exposes the variant list as a readable property, so there is no way to
  /// compute "one step down".
  final String hlsBitrate;

  /// Whether to decode video at all.
  final bool videoDisabled;

  /// `Channel.id` of the target, for siblings. Null for the other kinds, which
  /// stay on the current channel.
  final String? channelId;

  /// Relative tier, higher being better. Null when the name carried no tier
  /// token, which makes the option usable as a source but never as an
  /// automatic downgrade - see [QualityIndex.optionsFor].
  final int? rank;

  /// Whether the automatic path may select this without the user asking.
  ///
  /// False for [QualityKind.audioOnly]: it saves no bandwidth on a muxed
  /// transport stream, and a black video area with sound still playing is
  /// indistinguishable from the freeze it was supposed to fix.
  final bool autoSelectable;

  const QualityOption({
    required this.label,
    required this.kind,
    required this.url,
    this.hlsBitrate = 'max',
    this.videoDisabled = false,
    this.channelId,
    this.rank,
    this.autoSelectable = true,
  });

  bool get isSource => kind == QualityKind.source;

  @override
  String toString() => 'QualityOption($label, ${kind.name})';
}

/// A channel name split into the parts grouping cares about.
class NameAnalysis {
  /// The name with its tier token removed, cleaned up and lowercased. This is
  /// the grouping key - note it deliberately *keeps* any country or bouquet
  /// prefix, see [analyzeName].
  final String base;

  /// Relative tier from the token that was removed, or null if there was none.
  final int? rank;

  /// How many words followed the tier token.
  ///
  /// Part of the group key, which is what separates `UHD Movies` from
  /// `Movies HD`: both reduce to the base `movies`, but a real variant pair
  /// puts its tier token in the same place. Untagged names count as 0, so
  /// `ESPN` still groups with `ESPN HD`.
  final int wordsAfterTier;

  const NameAnalysis({
    required this.base,
    required this.rank,
    required this.wordsAfterTier,
  });

  bool get hasTier => rank != null;
}

/// Splits [name] into a base name and a quality tier.
///
/// The tier token is taken from the *last* tier word in the name, since variant
/// tags are written as suffixes far more often than prefixes.
///
/// Country and bouquet prefixes (`|US|`, `[UK]`, `US:`) are deliberately left
/// in the base name. `|US| ESPN` and `|AR| ESPN` are different languages, and
/// `|US| Sky Sports` and `|UK| Sky Sports` carry different rights and
/// blackouts - stripping the prefix would group them and make "lower quality"
/// silently mean "different feed". Strip it for display if you like; never for
/// the key.
NameAnalysis analyzeName(String rawName) {
  final name = _foldToAscii(rawName);
  final words = _wordPattern.allMatches(name).toList();
  final contentStart = _contentStart(name);

  int? rank;
  int tierIndex = -1;
  for (var i = 0; i < words.length; i++) {
    // Words inside a leading bouquet label are not tier candidates.
    if (words[i].start < contentStart) continue;
    final candidateRank = _tierTokens[_normalizeWord(words[i].group(0)!)];
    if (candidateRank != null) {
      rank = candidateRank;
      tierIndex = i;
    }
  }

  if (rank == null) {
    return NameAnalysis(
      base: _cleanup(name),
      rank: null,
      wordsAfterTier: 0,
    );
  }

  final tier = words[tierIndex];
  final withoutTier =
      name.substring(0, tier.start) + name.substring(tier.end);

  return NameAnalysis(
    base: _cleanup(withoutTier),
    rank: rank,
    wordsAfterTier: words.length - tierIndex - 1,
  );
}

/// Relative tier for [name], or null if it carries no tier token.
int? qualityRank(String name) => analyzeName(name).rank;

/// Index at which the channel's own name starts, past any bouquet label.
int _contentStart(String name) {
  final bracketed = _bracketedPrefixPattern.firstMatch(name);
  if (bracketed != null) return bracketed.end;

  // `IT:`, `CA EN:`, `SKYGO:`, `ENGLISH:`. Bounded so a colon later in a real
  // name (`24/7: The Matrix HD`) cannot swallow the whole thing.
  final colon = name.indexOf(':');
  if (colon > 0 && colon <= 14) return colon + 1;

  return 0;
}

String _foldToAscii(String value) {
  if (value.isEmpty) return value;
  final buffer = StringBuffer();
  for (final character in value.split('')) {
    buffer.write(_asciiFolds[character] ?? character);
  }
  return buffer.toString();
}

String _normalizeWord(String word) {
  final upper = word.toUpperCase();
  final scan = _scanSuffixPattern.firstMatch(upper);
  return scan?.group(1) ?? upper;
}

String _cleanup(String value) {
  return value
      .replaceAll(_emptyBracketsPattern, ' ')
      .replaceAll(_whitespacePattern, ' ')
      .replaceAll(_edgeJunkPattern, '')
      .toLowerCase();
}

/// Grouping key for [candidate], or null when it cannot be grouped safely.
///
/// Two paths, in priority order:
///
/// 1. `tvg-id`, when present. Two entries carrying the same id is the provider
///    asserting they are the same channel - a far stronger signal than anything
///    that can be inferred from a name.
/// 2. The normalised base name *plus* the category. Names alone collide
///    (`UHD Movies` / `Movies HD`), so the name path additionally requires the
///    entries to sit in the same category, which quality variants essentially
///    always do.
String? qualityGroupKey(QualityCandidate candidate) {
  final folded = _foldToAscii(candidate.name);

  // Checked before the tvg-id path, because a timeshift feed routinely carries
  // the same tvg-id as the live one.
  if (_timeshiftPattern.hasMatch(folded)) return null;

  // A name that is nothing but a bouquet label is a section header, not a
  // channel - `[SD]`, `4K:`, `--- FHD ---`. These are real playlist entries and
  // they must not be groupable with anything.
  if (_cleanup(folded.substring(_contentStart(folded))).length <
      minBaseNameLength) {
    return null;
  }

  final analysis = analyzeName(candidate.name);
  final base = analysis.base;

  final tvgId = candidate.tvgId?.trim();
  if (tvgId != null && tvgId.isNotEmpty) {
    // The base name is part of the key rather than a rule applied to the group
    // afterwards, so a bad tvg-id *partitions* instead of poisoning. Rejecting
    // any group whose names disagreed also threw away the good half of it: the
    // real playlist has `US: TNT HD`, `US: TNT SD` and `US: TNT WEST 4K` under
    // one id, and TNT WEST is a different feed while HD/SD are a genuine pair.
    // Partitioning keeps the pair and drops WEST as a singleton.
    //
    // What the tvg-id path still buys over the name path below: it does not
    // require the same category or the same tier-word position, so it catches
    // variants filed apart or tagged inconsistently.
    return 'tvg:${tvgId.toLowerCase()}|base:$base';
  }
  if (base.length < minBaseNameLength) return null;

  // Refuse a normalisation that ate most of the name. Catches the bare-tier
  // section headers that survive the length check because of surrounding
  // punctuation, without rejecting ordinary `Channel HD` -> `channel`.
  if (base.length * 2 < candidate.name.trim().length) return null;

  final category = candidate.category?.trim().toLowerCase() ?? '';
  return 'name:$base|after:${analysis.wordsAfterTier}|cat:$category';
}

class _Member {
  final QualityCandidate candidate;
  final int? rank;

  /// Normalised base name, kept so [QualityIndex._usableGroup] can require a
  /// group to agree on it without re-running the regexes.
  final String base;

  const _Member(this.candidate, this.rank, this.base);
}

/// Sibling lookup for one playlist, built once per load.
///
/// Building this is O(n) over the channel list with a handful of regex passes
/// per name, which is why it is built in `ChannelStateNotifier.loadChannels`
/// and carried in `ChannelState` rather than derived on demand - `markAsWatched`
/// rebuilds the channel list on every channel open, and re-normalising forty
/// thousand names at that moment would stall the UI isolate.
class QualityIndex {
  /// Group key -> members, best quality first.
  final Map<String, List<_Member>> _groups;

  /// Channel id -> its group key.
  final Map<String, String> _keyOf;

  const QualityIndex._(this._groups, this._keyOf);

  const QualityIndex.empty()
      : _groups = const {},
        _keyOf = const {};

  /// Number of usable sibling groups. Diagnostics only.
  int get groupCount => _groups.length;

  factory QualityIndex.build(Iterable<QualityCandidate> candidates) {
    final grouped = <String, List<_Member>>{};

    for (final candidate in candidates) {
      final key = qualityGroupKey(candidate);
      if (key == null) continue;
      final analysis = analyzeName(candidate.name);
      grouped
          .putIfAbsent(key, () => <_Member>[])
          .add(_Member(candidate, analysis.rank, analysis.base));
    }

    final groups = <String, List<_Member>>{};
    final keyOf = <String, String>{};

    for (final entry in grouped.entries) {
      final members = _usableGroup(entry.value);
      if (members == null) continue;

      groups[entry.key] = members;
      for (final member in members) {
        keyOf[member.candidate.id] = entry.key;
      }
    }

    return QualityIndex._(groups, keyOf);
  }

  /// Vets one raw group and returns it sorted best-first, or null if it is not
  /// a usable quality ladder.
  static List<_Member>? _usableGroup(List<_Member> raw) {
    // Duplicate entries pointing at one URL are endemic in dumped playlists.
    // Left in, they would burn a recovery rung "switching" to the same stream.
    final seenUrls = <String>{};
    final members = <_Member>[];
    for (final member in raw) {
      if (seenUrls.add(member.candidate.url)) members.add(member);
    }

    if (members.length < 2) return null;
    if (members.length > maxQualityGroupSize) return null;

    // No base-name check is needed here: the base is part of every group key,
    // so members of a group already agree on it by construction. That is what
    // keeps a placeholder tvg-id harmless - this playlist uses `TS` on 444
    // unrelated channels and `01TV.fr` on 18.

    // Needs at least two *different* known tiers to be a ladder at all. This is
    // the guard that makes a same-tvg-id group of `|US| ESPN` and `|AR| ESPN`
    // harmless: both are untagged, so the group yields no downgrade.
    final ranks = members.map((m) => m.rank).whereType<int>().toSet();
    if (ranks.length < 2) return null;

    members.sort((a, b) {
      // Untagged entries sort last: usable as a source, never as a downgrade.
      final left = a.rank;
      final right = b.rank;
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });

    return List<_Member>.unmodifiable(members);
  }

  /// The descending ladder for the channel identified by [channelId].
  ///
  /// [currentUrl] is the URL actually playing, which may differ from the
  /// channel's own because `StreamTuning.alternateUrl` can have flipped the
  /// container. It decides whether an HLS cap is worth offering.
  List<QualityOption> optionsFor({
    required String channelId,
    required String sourceLabel,
    required String currentUrl,
  }) {
    final options = <QualityOption>[];
    final key = _keyOf[channelId];
    final members = key == null ? null : _groups[key];
    _Member? self;
    if (members != null) {
      for (final member in members) {
        if (member.candidate.id == channelId) {
          self = member;
          break;
        }
      }
    }

    options.add(QualityOption(
      label: sourceLabel,
      kind: QualityKind.source,
      url: currentUrl,
      rank: self?.rank,
    ));

    // Siblings strictly below the current tier. An untagged current entry has
    // no tier to be below, so it offers no siblings - deliberately, since
    // "ESPN" next to "ESPN SD" gives no evidence about which is better.
    final selfRank = self?.rank;
    if (members != null && selfRank != null) {
      // Providers repeat a tier under one name - this playlist has
      // `US: FOX NEWS HD` three times and `US: FOX SPORTS 1 HD` twice, at
      // distinct URLs so the build-time URL de-duplication does not catch
      // them. Three identical rows in the picker are unusable, and since they
      // are offered as interchangeable there is nothing to choose between
      // them. The cost is losing them as fallbacks if the kept one is dead,
      // which the recovery ladder and the useless-option list already cover.
      final seenLabels = <String>{};

      for (final member in members) {
        final rank = member.rank;
        if (rank == null || rank >= selfRank) continue;
        if (member.candidate.url == currentUrl) continue;
        if (!seenLabels.add(member.candidate.name)) continue;
        options.add(QualityOption(
          label: member.candidate.name,
          kind: QualityKind.sibling,
          url: member.candidate.url,
          channelId: member.candidate.id,
          rank: rank,
        ));
      }
    }

    // `hls-bitrate` is read by the demuxer at open time and only means anything
    // for a playlist, so this is offered on `.m3u8` only. A `.ts` stream can
    // still reach it later: the watchdog's alternate-format rung may flip the
    // container, after which the option appears.
    if (_isHlsUrl(currentUrl)) {
      options.add(QualityOption(
        label: 'Lowest available bitrate',
        kind: QualityKind.hlsCap,
        url: currentUrl,
        hlsBitrate: 'min',
      ));
    }

    options.add(QualityOption(
      label: 'Audio only',
      kind: QualityKind.audioOnly,
      url: currentUrl,
      videoDisabled: true,
      autoSelectable: false,
    ));

    return List<QualityOption>.unmodifiable(options);
  }

  static bool _isHlsUrl(String url) {
    final query = url.indexOf('?');
    final path = query == -1 ? url : url.substring(0, query);
    return path.toLowerCase().endsWith('.m3u8');
  }
}
