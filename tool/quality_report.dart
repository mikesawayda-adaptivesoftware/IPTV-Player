// Reports what the quality-sibling heuristics actually find in a real playlist.
//
// The rules in core/player/stream_quality.dart are deliberately biased toward
// false negatives, so the question that matters is not "are they safe" but "do
// they still find anything". That cannot be answered from unit tests - only
// from a provider's real 50k-channel naming. This prints the groups it found,
// and the near-misses it refused, so a rule can be judged before it is loosened.
//
//     curl -s '<xtream>/player_api.php?...&action=get_live_streams' > live.json
//     dart run tool/quality_report.dart live.json
//
// Takes the get_live_streams JSON. Stream URLs are synthesised from stream_id
// rather than built for real, so nothing here can print a subscription
// credential - the ids are unique per channel, which is all the de-duplication
// rule needs.
import 'dart:convert';
import 'dart:io';

import 'package:iptv_player/core/player/stream_quality.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/quality_report.dart '
        '<get_live_streams.json> [name substring]');
    exit(64);
  }

  // Optional case-insensitive filter, for answering "does <X> have a ladder?".
  final filter = args.length > 1 ? args[1].toLowerCase() : null;

  final raw = jsonDecode(File(args.first).readAsStringSync()) as List<dynamic>;
  final candidates = <QualityCandidate>[];
  for (final entry in raw) {
    final json = entry as Map<String, dynamic>;
    final id = json['stream_id'].toString();
    candidates.add(QualityCandidate(
      id: id,
      name: (json['name'] ?? '').toString(),
      url: 'http://host/live/x/x/$id.ts',
      tvgId: json['epg_channel_id']?.toString(),
      category: json['category_id']?.toString() ?? json['category_name']?.toString(),
    ));
  }

  final index = QualityIndex.build(candidates);

  // Re-derive the raw groups so the rejections can be attributed. The three
  // rules mirrored here are the ones inside QualityIndex.build; the kept count
  // is cross-checked against index.groupCount below, which is what proves the
  // mirror is faithful.
  final rawGroups = <String, List<QualityCandidate>>{};
  var keyless = 0;
  var viaTvg = 0;
  for (final candidate in candidates) {
    final key = qualityGroupKey(candidate);
    if (key == null) {
      keyless++;
      continue;
    }
    if (key.startsWith('tvg:')) viaTvg++;
    rawGroups.putIfAbsent(key, () => []).add(candidate);
  }

  var kept = 0, rejectedSingleton = 0, rejectedDuplicateUrl = 0;
  var rejectedOversized = 0, rejectedNoTierSpread = 0, rejectedBaseDisagree = 0;
  final keptGroups = <List<QualityCandidate>>[];
  final oversized = <List<QualityCandidate>>[];
  final noSpread = <List<QualityCandidate>>[];
  final baseDisagree = <List<QualityCandidate>>[];

  for (final group in rawGroups.values) {
    if (group.length < 2) {
      rejectedSingleton++;
      continue;
    }
    final unique = <String, QualityCandidate>{};
    for (final candidate in group) {
      unique.putIfAbsent(candidate.url, () => candidate);
    }
    final members = unique.values.toList();
    if (members.length < 2) {
      rejectedDuplicateUrl++;
      continue;
    }
    if (members.length > maxQualityGroupSize) {
      rejectedOversized++;
      oversized.add(members);
      continue;
    }
    final tiers = members.map((m) => qualityRank(m.name)).whereType<int>().toSet();
    if (tiers.length < 2) {
      rejectedNoTierSpread++;
      noSpread.add(members);
      continue;
    }
    kept++;
    keptGroups.add(members);
  }

  void heading(String text) => print('\n$text\n${'-' * text.length}');

  print('channels                     ${candidates.length}');
  print('  no usable group key        $keyless');
  print('  keyed via tvg-id           $viaTvg');
  print('  keyed via name+category    ${candidates.length - keyless - viaTvg}');

  heading('groups');
  print('kept (usable ladders)        $kept');
  print('  index.groupCount           ${index.groupCount}'
      '${index.groupCount == kept ? '  (agrees)' : '  <-- MISMATCH'}');
  print('channels inside a ladder     '
      '${keptGroups.fold<int>(0, (sum, g) => sum + g.length)}');
  print('rejected: only one member    $rejectedSingleton');
  print('rejected: duplicate URLs     $rejectedDuplicateUrl');
  print('rejected: oversized (>$maxQualityGroupSize)     $rejectedOversized');
  print('rejected: names disagree     $rejectedBaseDisagree');
  print('rejected: no tier spread     $rejectedNoTierSpread');

  final histogram = <int, int>{};
  for (final group in keptGroups) {
    histogram[group.length] = (histogram[group.length] ?? 0) + 1;
  }
  heading('ladder sizes');
  for (final size in histogram.keys.toList()..sort()) {
    print('  $size channels: ${histogram[size]} ladders');
  }

  keptGroups.sort((a, b) => b.length.compareTo(a.length));

  final shown = filter == null
      ? keptGroups.take(25).toList()
      : keptGroups
          .where((g) => g.any((c) => c.name.toLowerCase().contains(filter)))
          .toList();

  heading(filter == null
      ? 'sample ladders found (best first within each)'
      : 'ladders matching "$filter" (${shown.length} of $kept)');
  for (final group in shown) {
    final sorted = group.toList()
      ..sort((a, b) => (qualityRank(b.name) ?? -1).compareTo(qualityRank(a.name) ?? -1));
    print('  ${sorted.map((c) => c.name).join('  ->  ')}');
  }

  heading('near-misses refused as oversized (possible false negatives)');
  for (final group in oversized.take(8)) {
    print('  ${group.length} members: '
        '${group.take(7).map((c) => c.name).join(' | ')}'
        '${group.length > 7 ? ' | ...' : ''}');
  }

  heading('refused because the names disagree (the tvg-id gate at work)');
  for (final group in baseDisagree.take(12)) {
    print('  ${group.map((c) => c.name).join(' | ')}');
  }

  heading('near-misses refused for no tier spread');
  for (final group in noSpread.take(8)) {
    print('  ${group.map((c) => c.name).join(' | ')}');
  }
}
