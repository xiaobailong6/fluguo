import 'package:flutter/foundation.dart';

import 'models.dart';

/// 进度、已传输字节和总大小只影响下载行；完成记录的大小仍属于归档数据。
/// 文件版本、元数据、状态和错误必须立即使结构失效，不能混入进度节流。
bool sameDownloadStructure(DownloadJob a, DownloadJob b) =>
    identical(a, b) ||
    a.sameFileVersion(b) &&
        a.state == b.state &&
        a.quality == b.quality &&
        a.actualQuality == b.actualQuality &&
        a.error == b.error &&
        a.archived == b.archived &&
        (!a.completed ||
            (a.bytes == b.bytes &&
                a.total == b.total &&
                a.progress == b.progress)) &&
        _sameDrama(a.drama, b.drama) &&
        (identical(a.episode, b.episode) ||
            a.episode.number == b.episode.number &&
                _sameJson(a.episode.raw, b.episode.raw));

bool sameDownload(DownloadJob a, DownloadJob b) =>
    identical(a, b) ||
    a.progress == b.progress &&
        a.bytes == b.bytes &&
        a.total == b.total &&
        sameDownloadStructure(a, b);

bool _sameDrama(Drama a, Drama b) =>
    identical(a, b) ||
    (
              a.id,
              a.source,
              a.sourceId,
              a.title,
              a.description,
              a.cover,
              a.episodes,
              a.category,
              a.vipStatus,
              a.heat,
              a.views,
              a.onlineDate,
              a.score,
              a.releaseStatus,
              a.badge,
            ) ==
            (
              b.id,
              b.source,
              b.sourceId,
              b.title,
              b.description,
              b.cover,
              b.episodes,
              b.category,
              b.vipStatus,
              b.heat,
              b.views,
              b.onlineDate,
              b.score,
              b.releaseStatus,
              b.badge,
            ) &&
        listEquals(a.tags, b.tags);

bool _sameJson(Object? a, Object? b) {
  if (identical(a, b) || a == b) return true;
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_sameJson(a[i], b[i])) return false;
    }
    return true;
  }
  return false;
}
