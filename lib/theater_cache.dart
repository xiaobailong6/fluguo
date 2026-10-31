import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'theater_recommendations.dart';

/// 只落盘展示元数据，不保存剧集 raw、播放地址或会话凭据。
class TheaterCandidateCache {
  TheaterCandidateCache(this.preferences, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final SharedPreferences preferences;
  final DateTime Function() clock;
  static const limit = 48;
  static const maxBytes = 128 * 1024;
  static const lifetime = Duration(days: 2);
  String key(String profile) => 'theater.candidates.$profile';

  List<Drama> read(String profile) {
    try {
      final raw = preferences.getString(key(profile));
      if (raw == null || raw.length > maxBytes) return [];
      final data = jsonDecode(raw) as Map;
      final time = DateTime.fromMillisecondsSinceEpoch(data['savedAt'] as int);
      final age = clock().difference(time);
      if (age.isNegative || age > lifetime || data['version'] != 1) return [];
      final rows = data['items'];
      if (rows is! List || rows.length > limit) return [];
      final result = <String, Drama>{};
      for (final row in rows.whereType<Map>()) {
        final drama = Drama.fromJson(Map<String, dynamic>.from(row));
        if (drama.id.isEmpty ||
            drama.title.isEmpty ||
            !SourceSite.isKnown(drama.source)) {
          continue;
        }
        result[theaterIdentity(drama)] = drama;
      }
      return result.values.toList();
    } catch (_) {
      return [];
    }
  }

  String encode(Iterable<Drama> dramas) {
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};
    var size = 128;
    for (final drama in dramas) {
      if (!seen.add(theaterIdentity(drama))) continue;
      // 白名单避免未来模型增加敏感字段时意外进入缓存；同时约束单项大小。
      final row = <String, dynamic>{
        'id': _text(drama.id, 512),
        'source': drama.source,
        'sourceId': _text(drama.sourceId, 512),
        'title': _text(drama.title, 160),
        'cover': _text(drama.cover, 2048),
        'episodes': drama.episodes,
        'category': _text(drama.category, 80),
        'tags': drama.tags.take(12).map((tag) => _text(tag, 80)).toList(),
        'vip': drama.vipStatus,
        'metadataSchema': 1,
        'releaseStatus': _text(drama.releaseStatus, 32),
      };
      final bytes = utf8.encode(jsonEncode(row)).length;
      if (size + bytes > maxBytes) break;
      rows.add(row);
      size += bytes + 1;
      if (rows.length == limit) break;
    }
    return jsonEncode({
      'version': 1,
      'savedAt': clock().millisecondsSinceEpoch,
      'items': rows,
    });
  }

  static String _text(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);
}

/// 只在内存中保留三部详情、十分钟有效期；主请求和下一部预读合并。
class TheaterDetailCache {
  TheaterDetailCache(this.repository, this.store, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final AppRepository repository;
  final LocalStore store;
  final DateTime Function() clock;
  final _entries = <String, ({DramaDetail detail, DateTime expires})>{};
  final _pending = <String, Future<DramaDetail>>{};
  int _generation = 0;
  bool _disposed = false;

  Future<DramaDetail> load(Drama drama) {
    if (_disposed || !store.allowsSource(drama.source)) {
      return Future.error(StateError('预读已失效'));
    }
    final id = theaterIdentity(drama);
    final cached = _entries[id];
    if (cached != null && clock().isBefore(cached.expires)) {
      return Future.value(cached.detail);
    }
    final pendingKey = '$_generation:$id';
    if (_pending[pendingKey] case final request?) return request;
    final generation = _generation;
    final epoch = store.profileEpoch;
    late final Future<DramaDetail> request;
    request = Future<DramaDetail>.sync(() => repository.detail(drama))
        .then((detail) {
          if (detail.drama.source != drama.source ||
              detail.drama.id != drama.id ||
              detail.episodes.isEmpty) {
            throw StateError('剧集详情无效');
          }
          if (!_disposed &&
              generation == _generation &&
              epoch == store.profileEpoch &&
              store.allowsSource(drama.source)) {
            _entries.remove(id);
            _entries[id] = (
              detail: detail,
              expires: clock().add(const Duration(minutes: 10)),
            );
            while (_entries.length > 3) {
              _entries.remove(_entries.keys.first);
            }
          }
          return detail;
        })
        .whenComplete(() {
          _pending.remove(pendingKey);
        });
    _pending[pendingKey] = request;
    return request;
  }

  Future<void> warm(Drama drama) async {
    // 在途详情仍占槽，快滑/换用户不以超时假释放来突破后台请求上限。
    if (_disposed || _pending.isNotEmpty) return;
    try {
      await load(drama);
    } catch (_) {
      /* 预读失败不影响当前播放。 */
    }
  }

  void invalidate() {
    _generation++;
    _entries.clear();
  }

  void forget(Drama drama) => _entries.remove(theaterIdentity(drama));
  void dispose() {
    _disposed = true;
    invalidate();
  }
}
