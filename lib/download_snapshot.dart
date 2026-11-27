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

/// 原生下载游标的本地镜像。进度变化只解析目标任务，并复用其它模型和排序。
class DownloadSnapshot {
  String fingerprint = '';
  List<DownloadJob> jobs = const [];
  Map<String, int> _indices = const {};

  bool apply(Map<String, dynamic> response) {
    final token = response['fingerprint'] as String? ?? '';
    if (response['jobs'] case final List rows) {
      final next = _parse(rows);
      _install(next);
    } else if (response.containsKey('changed')) {
      if (fingerprint.isEmpty ||
          response['base'] != fingerprint ||
          response['changed'] is! List ||
          response['removed'] is! List) {
        return false;
      }
      final changed = _parse(response['changed'] as List);
      final removed = (response['removed'] as List).cast<String>().toSet();
      final structural =
          removed.any(_indices.containsKey) ||
          changed.any((job) {
            final index = _indices[job.id];
            return index == null ||
                jobs[index].created != job.created ||
                jobs[index].episode.number != job.episode.number;
          });
      if (structural) {
        final byId = {for (final job in jobs) job.id: job}
          ..removeWhere((id, _) => removed.contains(id));
        for (final job in changed) {
          byId[job.id] = job;
        }
        _install(byId.values.toList());
      } else if (changed.isNotEmpty) {
        final next = List<DownloadJob>.of(jobs);
        for (final job in changed) {
          next[_indices[job.id]!] = job;
        }
        jobs = List.unmodifiable(next);
      }
    } else if (token.isNotEmpty && token != fingerprint) {
      return false;
    }
    fingerprint = token;
    return true;
  }

  List<DownloadJob> _parse(List rows) => [
    for (final row in rows)
      DownloadJob.fromJson(Map<String, dynamic>.from(row as Map)),
  ];

  void _install(List<DownloadJob> next) {
    next.sort((a, b) {
      final created = b.created.compareTo(a.created);
      if (created != 0) return created;
      final episode = a.episode.number.compareTo(b.episode.number);
      return episode != 0 ? episode : a.id.compareTo(b.id);
    });
    _indices = {for (final (index, job) in next.indexed) job.id: index};
    jobs = List.unmodifiable(next);
  }
}
