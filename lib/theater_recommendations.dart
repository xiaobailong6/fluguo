import 'dart:math';

import 'models.dart';

String theaterIdentity(Drama drama) => '${drama.source}:${drama.id}';
String theaterTag(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'\s+'), '').trim();

bool theaterCompleted(WatchEntry entry) =>
    entry.drama.episodes > 0 &&
    entry.episode >= entry.drama.episodes &&
    entry.finished;

/// 每部剧只贡献一次；通用标签降权，避免目录大类盖过真正题材。
Map<String, double> theaterInterests(List<WatchEntry> history, DateTime now) {
  final recent = [...history]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final seen = <String>{};
  final weights = <String, double>{};
  for (final entry in recent) {
    if (!seen.add(theaterIdentity(entry.drama))) continue;
    final age = max(0, now.difference(entry.updatedAt).inHours) / 24;
    final progress = entry.drama.episodes > 0
        ? (entry.episode / entry.drama.episodes).clamp(0.0, 1.0)
        : 0.0;
    final weight = pow(0.5, age / 14).toDouble() * (1 + progress * 0.3);
    for (final tag in {
      entry.drama.category,
      ...entry.drama.tags,
    }.map(theaterTag)) {
      if (tag.isEmpty || tag == '未分类' || tag == '全部') continue;
      final weak = {'短剧', '真人剧', '漫剧', 'ai剧', 'ai短剧', 'ai漫剧'}.contains(tag);
      weights[tag] = (weights[tag] ?? 0) + weight * (weak ? 0.1 : 1);
    }
    if (seen.length == 30) break;
  }
  return weights;
}

class TheaterPick {
  const TheaterPick(this.drama, this.reason);
  final Drama drama;
  final String reason;
}

/// 固定随机种子可重现；先按 70/30 配额抽样，池不足时只从另一池补足。
List<TheaterPick> theaterSample({
  required Iterable<Drama> candidates,
  required List<WatchEntry> history,
  required Set<String> allowedSources,
  required Set<String> excluded,
  required Random random,
  required DateTime now,
  int count = 12,
}) {
  final interests = theaterInterests(history, now);
  final completed = history
      .where(theaterCompleted)
      .map((e) => theaterIdentity(e.drama))
      .toSet();
  final unique = <String, Drama>{};
  for (final drama in candidates) {
    final id = theaterIdentity(drama);
    if (drama.id.isEmpty ||
        !allowedSources.contains(drama.source) ||
        excluded.contains(id) ||
        completed.contains(id)) {
      continue;
    }
    unique.update(id, (old) => old.merge(drama), ifAbsent: () => drama);
  }
  final matches = <(Drama, double, String)>[];
  final explore = <(Drama, double, String)>[];
  for (final drama in unique.values) {
    final tags = {drama.category, ...drama.tags}.map(theaterTag).toSet();
    final matching = tags.where((tag) => (interests[tag] ?? 0) > 0).toList()
      ..sort((a, b) => interests[b]!.compareTo(interests[a]!));
    if (matching.isEmpty) {
      explore.add((drama, 1, interests.isEmpty ? '默认推荐 · 暂无足够兴趣记录' : '探索不同题材'));
    } else {
      matches.add((
        drama,
        matching.fold<double>(1, (sum, tag) => sum + interests[tag]!),
        '因为你看过「${matching.first}」',
      ));
    }
  }
  final result = <TheaterPick>[];
  void draw(List<(Drama, double, String)> pool, int limit) {
    while (pool.isNotEmpty && limit-- > 0 && result.length < count) {
      var point =
          random.nextDouble() *
          pool.fold<double>(0, (sum, item) => sum + item.$2);
      var index = pool.length - 1;
      for (var i = 0; i < pool.length; i++) {
        point -= pool[i].$2;
        if (point <= 0) {
          index = i;
          break;
        }
      }
      final item = pool.removeAt(index);
      result.add(TheaterPick(item.$1, item.$3));
    }
  }

  draw(matches, (count * 0.7).round());
  draw(explore, count - result.length);
  draw(matches, count - result.length);
  result.shuffle(random);
  return result;
}
