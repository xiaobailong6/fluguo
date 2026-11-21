import 'dart:async';
import 'dart:convert';

import 'package:media_kit/media_kit.dart';

import 'models.dart';

String playbackEpisodeIdentity(
  Drama drama,
  Episode episode,
  int quality,
  bool online,
  int epoch,
) => jsonEncode([
  epoch,
  drama.source,
  drama.id,
  episode.number,
  episode.raw,
  quality,
  online,
]);

DateTime playbackPlanExpiry(PlaybackPlan plan, DateTime obtained) {
  var expiry = obtained.add(const Duration(minutes: 2));
  if (plan.expiresAt > 0) {
    final authorization = DateTime.fromMillisecondsSinceEpoch(
      plan.expiresAt,
    ).subtract(const Duration(seconds: 5));
    if (authorization.isBefore(expiry)) expiry = authorization;
  }
  return expiry;
}

/// 一个计划只有一个所有者：当前会话或邻集窗口。转移不重新计算 expires。
class PlaybackEpisodeEntry {
  PlaybackEpisodeEntry({
    required this.identity,
    required this.index,
    required this.plan,
    required this.expires,
  });
  final String identity;
  final int index;
  final PlaybackPlan plan;
  final DateTime expires;
  Player? player;
  Future<void>? preparing;
  StreamSubscription<String>? errors;
  int preparation = 0;
  Completer<void>? outputCancelled;
  bool ready = false;
  // 同集暂停回零可继续显示已有帧；换文件时则必须遮住槽位残留画面。
  bool frameRetained = false;
  Object? outputIdentity;
  bool failed = false;
  // 单集的临时输出失败不代表设备永久失去多解码器能力。
  bool outputUnavailable = false;
  bool released = false;
}

/// 当前集由 PlaybackSession 持有，本对象最多保留其两个邻集。
/// 淘汰同步撤销所有权，异步清理无法复活 entry；只转移完整身份匹配的计划。
class PlaybackEpisodeWindow {
  PlaybackEpisodeWindow({required this.release, DateTime Function()? now})
    : now = now ?? DateTime.now;
  final void Function(PlaybackEpisodeEntry) release;
  final DateTime Function() now;
  final Map<int, PlaybackEpisodeEntry> _entries = {};
  Map<int, String> _allowed = {};

  List<PlaybackEpisodeEntry> get entries => List.unmodifiable(_entries.values);
  int get length => _entries.length;

  void move(
    DramaDetail detail,
    int center,
    int quality,
    bool online,
    int epoch,
  ) {
    _allowed = {
      for (final index in [center - 1, center + 1])
        if (index >= 0 && index < detail.episodes.length)
          index: playbackEpisodeIdentity(
            detail.drama,
            detail.episodes[index],
            quality,
            online,
            epoch,
          ),
    };
    for (final entry in entries) {
      if (_allowed[entry.index] != entry.identity || !valid(entry)) {
        evict(entry);
      }
    }
  }

  bool valid(PlaybackEpisodeEntry entry) =>
      !entry.released && !entry.failed && now().isBefore(entry.expires);
  bool owns(PlaybackEpisodeEntry entry) =>
      identical(_entries[entry.index], entry) && !entry.released;

  PlaybackEpisodeEntry? find(int index, String identity) {
    final entry = _entries[index];
    if (entry == null) return null;
    if (entry.identity != identity || !valid(entry)) {
      evict(entry);
      return null;
    }
    return entry;
  }

  bool add(PlaybackEpisodeEntry entry) {
    if (_allowed[entry.index] != entry.identity || !valid(entry)) {
      _release(entry);
      return false;
    }
    final old = _entries[entry.index];
    if (identical(old, entry)) return true;
    if (old != null) evict(old);
    _entries[entry.index] = entry;
    return true;
  }

  PlaybackEpisodeEntry? take(int index, String identity) {
    final entry = find(index, identity);
    if (entry != null) _entries.remove(index);
    return entry;
  }

  void evict(PlaybackEpisodeEntry entry) {
    if (identical(_entries[entry.index], entry)) _entries.remove(entry.index);
    _release(entry);
  }

  void _release(PlaybackEpisodeEntry entry) {
    if (entry.released) return;
    entry.released = true;
    entry.ready = false;
    if (entry.outputCancelled?.isCompleted == false) {
      entry.outputCancelled!.complete();
    }
    release(entry);
  }

  void clear() {
    for (final entry in entries) {
      evict(entry);
    }
    _allowed = {};
  }
}
