import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'app_device.dart';
import 'diary_service.dart';
import 'download_export.dart';
import 'background_downloads.dart';
import 'download_overview.dart';
import 'models.dart';

typedef DownloadExportAction = Future<void> Function(
  DownloadJob job,
  bool delete,
  void Function() beforeDelete,
);

/// 只记录开启自动导出后新完成的分集，不追溯导出全部历史下载。
/// 待办先写盘再提交转换，进程退出后可补导出；失败每次启动只尝试一次。
class DownloadAutoExporter extends ChangeNotifier {
  DownloadAutoExporter(
    this.repository,
    this.downloads, {
    this.inUse,
    bool? supported,
    DownloadExportAction? export,
  }) : _supported = supported ?? Platform.isAndroid,
       _export = export {
    _epoch = downloads.store.profileEpoch;
    _key = 'downloadAutoExport.v1.${downloads.store.profile.id}';
    try {
      final raw = downloads.store.preferences.getString(_key);
      if (raw != null) {
        final rows = jsonDecode(raw) as Map<String, dynamic>;
        for (final entry in rows.entries) {
          final value = Map<String, dynamic>.from(entry.value as Map);
          if (value['identity'] is! String || value['delete'] is! bool) {
            throw const FormatException('自动导出待办字段无效');
          }
          _pending[entry.key] = value;
        }
      }
    } catch (error) {
      _invalidStorage = true;
      _storageError = '无法读取自动导出待办，原记录已保留，请恢复数据后重启：$error';
    }
    downloads.addListener(_sync);
    downloads.store.addListener(_sync);
    _sync();
  }

  final AppRepository repository;
  final DownloadOverview downloads;
  final bool Function(String id)? inUse;
  final bool _supported;
  final DownloadExportAction? _export;
  late final int _epoch;
  late final String _key;
  final _pending = <String, Map<String, dynamic>>{};
  final _attempted = <String>{};
  Future<void> _writes = Future<void>.value();
  bool _running = false, _disposed = false;
  bool _invalidStorage = false;
  String? _storageError;
  String? _current;

  static String _identity(DownloadJob job) =>
      '${job.id}|${job.created}|${job.revision}';

  bool get _allowed =>
      !_disposed &&
      _supported &&
      downloads.store.profileEpoch == _epoch &&
      downloads.store.canDownload &&
      downloads.store.autoExport;

  String? get error => _storageError ?? _pending.values
      .map((row) => row['error'])
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .firstOrNull;
  bool get exporting => _current != null;

  Future<void> _persist() {
    if (_invalidStorage) return Future.error(AppFailure(_storageError!));
    final value = jsonEncode(_pending);
    final result = _writes.then((_) async {
      if (!await downloads.store.preferences.setString(_key, value)) {
        throw AppFailure('无法保存自动导出待办');
      }
    });
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> queue(DownloadJob job) async {
    if (!_allowed || !downloads.store.allowsSource(job.drama.source)) return;
    if (_invalidStorage) throw AppFailure(_storageError!);
    _pending[job.id] = {
      'identity': _identity(job),
      'delete': downloads.store.deleteAfterAutoExport,
      'error': '',
    };
    _attempted.remove(job.id);
    try {
      await _persist();
      _storageError = null;
    } catch (error) {
      _storageError = '$error';
      DiaryService.add('[下载] 自动导出待办保存失败：$error');
      _notify();
      rethrow;
    }
  }

  Future<void> retry() async {
    if (!_allowed || _running || _invalidStorage) return;
    try {
      await _persist();
      _storageError = null;
      _attempted.clear();
      for (final row in _pending.values) {
        row['error'] = '';
      }
      _sync();
    } catch (error) {
      _storageError = '$error';
    }
    _notify();
  }

  void _sync() {
    if (_running || !_allowed || _storageError != null) return;
    final job = downloads.jobs.where((job) =>
        job.completed &&
        downloads.store.allowsSource(job.drama.source) &&
        !_attempted.contains(job.id) &&
        _pending[job.id]?['identity'] == _identity(job)).firstOrNull;
    if (job != null) unawaited(_run(job));
  }

  Future<void> _run(DownloadJob job) async {
    _running = true;
    _current = job.id;
    _attempted.add(job.id);
    _notify();
    var leased = false;
    final pending = _pending[job.id]!;
    void checkAccess() {
      if (!_allowed || !downloads.store.allowsSource(job.drama.source)) {
        throw AppFailure('用户或权限已变更，已停止自动导出');
      }
      final current = downloads.jobs.where((item) => item.id == job.id).firstOrNull;
      if (current == null || !current.completed ||
          _identity(current) != _identity(job) ||
          _pending[job.id]?['identity'] != _identity(job)) {
        throw AppFailure('分集已变化，已保留当前下载，请刷新后重试');
      }
      if (pending['delete'] == true && (inUse?.call(job.id) ?? false)) {
        throw AppFailure('该分集正在合并，请结束合并后重试导出');
      }
    }
    try {
      checkAccess();
      await BackgroundDownloads.ensureStarted();
      await repository.workLease('export', 'start');
      leased = true;
      checkAccess();
      final delete = pending['delete'] as bool;
      if (_export case final export?) {
        await export(job, delete, checkAccess);
      } else {
        if (!await AppDevice.requestVideoExport()) {
          throw AppFailure('未获得存储权限，无法自动导出');
        }
        checkAccess();
        await exportDownload(repository, job, delete: delete,
            checkAccess: checkAccess, beforeDelete: checkAccess);
      }
      if (_pending[job.id]?['identity'] == _identity(job)) {
        _pending.remove(job.id);
        await _persist();
      }
    } catch (error) {
      if (_pending[job.id] == null ||
          _pending[job.id]?['identity'] == _identity(job)) {
        _pending[job.id] = pending..['error'] = '$error';
      }
      DiaryService.add('[下载] ${job.drama.title} 第 ${job.episode.number} 集自动导出失败：$error');
      try {
        await _persist();
      } catch (saveError) {
        _storageError = '$saveError';
      }
    } finally {
      if (leased) {
        try {
          await repository.workLease('export', 'end');
        } catch (error) {
          DiaryService.add('[下载] 释放自动导出占用失败：$error');
        }
      }
      _running = false;
      _current = null;
      _notify();
      if (!_disposed) {
        await downloads.refresh();
        _sync();
      }
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    downloads.removeListener(_sync);
    downloads.store.removeListener(_sync);
    super.dispose();
  }
}
