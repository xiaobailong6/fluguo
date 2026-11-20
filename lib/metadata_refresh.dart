import 'package:flutter/foundation.dart';

import 'follow_state.dart';
import 'hongguo_series.dart';
import 'models.dart';

/// 只比较持久化字段，不生成 JSON；空字段的补充规则仍由 Drama.merge 决定。
bool sameDramaMetadata(Drama a, Drama b) =>
    identical(a, b) ||
    a.id == b.id &&
        a.source == b.source &&
        a.sourceId == b.sourceId &&
        a.title == b.title &&
        a.description == b.description &&
        a.cover == b.cover &&
        a.episodes == b.episodes &&
        a.category == b.category &&
        a.vipStatus == b.vipStatus &&
        a.heat == b.heat &&
        a.views == b.views &&
        a.onlineDate == b.onlineDate &&
        a.score == b.score &&
        listEquals(a.tags, b.tags) &&
        a.releaseStatus == b.releaseStatus &&
        a.badge == b.badge;

Drama mergeDramaMetadata(Drama previous, Drama incoming) {
  if (sameDramaMetadata(previous, incoming)) return previous;
  final merged = previous.merge(incoming);
  return sameDramaMetadata(previous, merged) ? previous : merged;
}

/// 可选的操作计数器：测试性能契约，不依赖机器速度或绝对耗时。
class MetadataRefreshStats {
  int batches = 0;
  int dramaIds = 0;
  int mapCopies = 0;
  int encodedGroups = 0;
  int parsedCandidates = 0;

  void reset() {
    batches = dramaIds = mapCopies = encodedGroups = parsedCandidates = 0;
  }
}

class MetadataUpdate {
  MetadataUpdate(this.drama, {required bool cacheCandidate})
    : candidate = cacheCandidate ? drama : null,
      startsWithoutEpisodes = drama.episodes <= 0,
      peakEpisodes = drama.episodes,
      firstEpisodes = drama.episodes > 0 ? drama.episodes : null;

  Drama drama;
  Drama? candidate;
  int peakEpisodes;
  final bool startsWithoutEpisodes;
  int? firstEpisodes;

  void add(Drama incoming, {required bool cacheCandidate}) {
    drama = mergeDramaMetadata(drama, incoming);
    // 集数可能先升后降；合并元数据不能抹掉 observe 曾见到的最高值或首次基线。
    if (incoming.episodes > peakEpisodes) peakEpisodes = incoming.episodes;
    if (incoming.episodes > 0) firstEpisodes ??= incoming.episodes;
    if (cacheCandidate) {
      candidate = candidate == null
          ? incoming
          : mergeDramaMetadata(candidate!, incoming);
    }
  }
}

/// 四个库各自写时复制；null 代表该分类完全不需要复制、编码或落盘。
class MetadataRefresh {
  Map<String, Drama>? favorites;
  Map<String, WatchEntry>? history;
  Map<String, FollowState>? states;
  Map<String, Drama>? candidates;
}

MetadataRefresh prepareMetadataRefresh({
  required Map<String, MetadataUpdate> updates,
  required Map<String, Drama> favorites,
  required Map<String, WatchEntry> history,
  required Map<String, FollowState> states,
  required Map<String, Drama> candidates,
  MetadataRefreshStats? stats,
}) {
  final result = MetadataRefresh();
  if (stats != null) {
    stats.batches++;
    stats.dramaIds += updates.length;
  }
  Map<String, T> copy<T>(Map<String, T> values) {
    if (stats != null) stats.mapCopies++;
    return Map.of(values);
  }

  for (final update in updates.values) {
    final drama = update.drama;
    final candidate = update.candidate;
    if (candidate != null && candidate.source == SourceSite.hongguo.id) {
      final previous = candidates[drama.id];
      final merged = previous == null
          ? candidate
          : mergeDramaMetadata(previous, candidate);
      if (!identical(previous, merged)) {
        (result.candidates ??= copy(candidates))[drama.id] = merged;
      }
    }
    final favorite = favorites[drama.id];
    if (favorite != null) {
      final merged = mergeDramaMetadata(favorite, drama);
      if (!identical(merged, favorite)) {
        (result.favorites ??= copy(favorites))[drama.id] = merged;
      }
      final before = states[drama.id]!;
      // 首次 observe 使用当时的合并集数，而不是本批最后一次的集数。
      final initial = update.startsWithoutEpisodes
          ? favorite.episodes
          : update.firstEpisodes ?? 0;
      final baseline = before.knownEpisodes > initial
          ? before.knownEpisodes
          : initial;
      final known = baseline > update.peakEpisodes
          ? baseline
          : update.peakEpisodes;
      final read =
          before.readEpisodes ??
          (baseline > 0 ? baseline : update.firstEpisodes);
      if (known != before.knownEpisodes || read != before.readEpisodes) {
        (result.states ??= copy(states))[drama.id] = FollowState(
          knownEpisodes: known,
          readEpisodes: read,
          seriesSeasons: before.seriesSeasons,
        );
      }
    }
    final watched = history[drama.id];
    if (watched != null) {
      final merged = mergeDramaMetadata(watched.drama, drama);
      if (!identical(merged, watched.drama)) {
        (result.history ??= copy(history))[drama.id] = WatchEntry(
          drama: merged,
          episode: watched.episode,
          position: watched.position,
          duration: watched.duration,
          updatedAt: watched.updatedAt,
        );
      }
    }
  }

  // 保持原有按 ID 截断的 2000 条本机预算。被预算丢弃的新增项不触发空写。
  final changedCandidates = result.candidates;
  if (changedCandidates != null) {
    final ids = changedCandidates.keys.toList()..sort();
    if (stats != null) stats.mapCopies++;
    result.candidates = {
      for (final id in ids.take(2000)) id: changedCandidates[id]!,
    };
    if (result.candidates!.length == candidates.length &&
        result.candidates!.entries.every(
          (entry) => identical(candidates[entry.key], entry.value),
        )) {
      result.candidates = null;
    }
  }

  final nextFavorites = result.favorites ?? favorites;
  final anchors = nextFavorites.values.where(
    (drama) => drama.source == SourceSite.hongguo.id,
  );
  if (anchors.isNotEmpty) {
    // 不省略无元数据变化批次的系列观察：收藏关系、已读状态可能刚刚改变。
    // 候选来源与旧实现相同；本机候选缓存仍仅用于 seriesDramasFor。
    final series = <String, Drama>{
      for (final entry in (result.history ?? history).values)
        if (entry.drama.source == SourceSite.hongguo.id)
          entry.drama.id: entry.drama,
      for (final drama in anchors) drama.id: drama,
      for (final update in updates.values)
        if (update.drama.source == SourceSite.hongguo.id)
          update.drama.id: update.drama,
    };
    for (final state in (result.states ?? states).values) {
      for (final notice in state.seriesSeasons.values) {
        series.putIfAbsent(
          notice.id,
          () => Drama(
            id: notice.id,
            source: SourceSite.hongguo.id,
            sourceId: notice.id.substring(SourceSite.hongguo.id.length + 1),
            title: notice.title,
          ),
        );
      }
    }
    final index = HongguoSeriesIndex(series.values);
    if (stats != null) stats.parsedCandidates += series.length;
    final favoriteIds = nextFavorites.keys.toSet();
    for (final anchor in anchors) {
      final before = (result.states ?? states)[anchor.id];
      if (before == null) continue;
      final after = observeHongguoSeriesSeasons(
        anchor: anchor,
        state: before,
        candidates: const [],
        favoriteIds: favoriteIds,
        index: index,
      );
      if (!identical(before, after)) {
        (result.states ??= copy(states))[anchor.id] = after;
      }
    }
  }
  return result;
}
