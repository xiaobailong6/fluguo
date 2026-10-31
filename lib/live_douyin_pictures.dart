import 'dart:async';
import 'dart:convert';

import 'live_douyin_http.dart';
import 'live_models.dart';

/// 抖音不为所有分区下发图标，以对应分区当前直播封面作为动态背景。
/// 只保存图片地址（不保存媒体地址），最多两路并发、64项短时缓存。
class DouyinCategoryPictures {
  DouyinCategoryPictures(this.client, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final DouyinClient client;
  final DateTime Function() clock;
  final _cache = <String, ({String url, DateTime expires})>{};
  final _pending = <String, Future<String>>{};
  final _queue = <void Function()>[];
  int _active = 0;

  Future<String> load(LiveCategory category) {
    if (category.picture.isNotEmpty) return Future.value(category.picture);
    final key = category.areaId == '0' ? category.parentId : category.areaId;
    if (!category.hot && !RegExp(r'^\d+,\d+$').hasMatch(key)) {
      return Future.value('');
    }
    final cached = _cache[key];
    if (cached != null && clock().isBefore(cached.expires)) {
      return Future.value(cached.url);
    }
    if (_pending[key] case final request?) return request;
    if (_pending.length >= 32) return Future.value('');
    final completer = Completer<String>();
    _pending[key] = completer.future;
    _queue.add(() {
      unawaited(() async {
        var url = '';
        try {
          final Map<String, dynamic> data;
          if (category.hot) {
            data = await client.json('/webcast/feed/', {
              'need_map': '1',
              'is_draw': '1',
              'count': '1',
              'enter_source': 'web_homepage_hot_web_live_card',
              'source_key': 'web_homepage_hot_web_live_card',
            });
          } else {
            final ids = key.split(',');
            data = await client.json('/webcast/web/partition/detail/room/v2/', {
              'partition': ids[0],
              'partition_type': ids[1],
              'count': '1',
              'offset': '0',
              'req_from': '2',
            });
          }
          url = parsePicture(data);
        } catch (_) {
          // 图片失败不能让整个分区页失败；一分钟后可重试而非每帧请求。
        } finally {
          _cache.remove(key);
          _cache[key] = (
            url: url,
            expires: clock().add(
              url.isEmpty
                  ? const Duration(minutes: 1)
                  : const Duration(minutes: 10),
            ),
          );
          while (_cache.length > 64) {
            _cache.remove(_cache.keys.first);
          }
          _pending.remove(key);
          completer.complete(url);
          _active--;
          _drain();
        }
      }());
    });
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_active < 2 && _queue.isNotEmpty) {
      _active++;
      _queue.removeAt(0)();
    }
  }

  static String parsePicture(Map<String, dynamic> json) {
    if (json['status_code'] != null && '${json['status_code']}' != '0') {
      return '';
    }
    dynamic rows = json['data'];
    if (rows is Map) rows = rows['data'];
    if (rows is! List) return '';
    for (final entry in rows.whereType<Map>()) {
      dynamic room = entry['room'] ?? entry['data'];
      if (room is String) {
        try {
          room = jsonDecode(room);
        } catch (_) {
          continue;
        }
      }
      if (room is! Map) continue;
      final cover = room['cover'];
      final urls = cover is Map ? cover['url_list'] : null;
      if (urls is! List) continue;
      for (final value in urls) {
        if (value is! String) continue;
        final uri = Uri.tryParse(value);
        if (uri != null &&
            uri.host.isNotEmpty &&
            const {'http', 'https'}.contains(uri.scheme)) {
          return value.startsWith('http:')
              ? value.replaceFirst('http:', 'https:')
              : value;
        }
      }
    }
    return '';
  }
}
