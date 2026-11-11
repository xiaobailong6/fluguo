import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'core_bridge.dart';
import 'download_merge.dart';
import 'media_cleanup.dart';
import 'models.dart';

class MergedVideo {
  MergedVideo({
    required this.id,
    required this.drama,
    required List<int> episodes,
    required this.bytes,
    required this.createdAt,
    required this.fileName,
  }) : episodes = List.unmodifiable(episodes.toSet().toList()..sort());

  final String id;
  final Drama drama;
  final List<int> episodes;
  final int bytes;
  final DateTime createdAt;
  final String fileName;
}

/// 用户取消不是库损坏；保留独立类型以免正常取消污染库级健康提示。
class _MergedWriteCancelled extends AppFailure {
  _MergedWriteCancelled() : super('已取消合并');
}

/// 独立于分集下载和外部导出的私有成品库。directory 是库根目录，便于无插件测试。
class MergedLibrary extends ChangeNotifier {
  MergedLibrary({Directory? directory, DateTime Function()? now})
    : _directory = directory,
      _now = now ?? DateTime.now;

  static const _maxIndexBytes = 4 * 1024 * 1024;
  static const _maxVideos = 2000;
  static const _maxMediaBytes = 8 * 1024 * 1024 * 1024 * 1024;
  static const _owner = 'fluguo-merged-video-v1';
  static final _idPattern = RegExp(r'^[a-f0-9]{32}$');
  static final _random = Random.secure();

  Directory? _directory;
  final DateTime Function() _now;
  Future<void>? _initialization;
  Future<void> _tail = Future<void>.value();
  List<MergedVideo> _videos = const [];
  Object? _error;
  bool _loaded = false, _writable = false, _disposed = false;

  List<MergedVideo> get videos => _videos;
  Object? get error => _error;

  Future<void> ensureInitialized() =>
      _initialization ??= Future<void>.microtask(_initialize);

  String _at(String name) => path.join(_directory!.path, name);
  String _media() => _at('media');
  String _folder(String id) {
    if (!_idPattern.hasMatch(id)) throw AppFailure('合并成品 ID 无效');
    return path.join(_media(), id);
  }

  String _file(String id, String name) => path.join(_folder(id), name);
  FileSystemEntityType _type(String file) =>
      FileSystemEntity.typeSync(file, followLinks: false);

  void _directoryOnly(String file) {
    if (_type(file) != FileSystemEntityType.directory) {
      throw AppFailure('合并库目录不存在或不是普通目录：$file');
    }
  }

  void _rootSafe() {
    _directoryOnly(_directory!.path);
    _directoryOnly(_media());
  }

  void _regularOrAbsent(String file) {
    final type = _type(file);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw AppFailure('合并库拒绝链接或非普通文件：$file');
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _problem(Object error) {
    _error = error;
    _notify();
  }

  Future<void> _initialize() async {
    try {
      _directory ??= Directory(
        path.join((await getApplicationSupportDirectory()).path, 'merged_videos'),
      );
      // 只规范化库根；库根和其内部的任何链接都不接受。
      _directory = Directory(path.normalize(path.absolute(_directory!.path)));
      if (_type(_directory!.path) == FileSystemEntityType.notFound) {
        await _directory!.create(recursive: true);
      }
      _directoryOnly(_directory!.path);
      for (final name in ['index.json', 'index.json.tmp', 'index.json.bak']) {
        _regularOrAbsent(_at(name));
      }
      final index = File(_at('index.json'));
      final temporary = File(_at('index.json.tmp'));
      final backup = File(_at('index.json.bak'));
      var readOnly = false;
      if (index.existsSync()) {
        try {
          _videos = _readIndex(index);
        } catch (error) {
          // 损坏主索引不能视为新安装。备份仅用于只读救援，绝不清扫成品。
          if (backup.existsSync()) {
            _videos = _readIndex(backup);
            readOnly = true;
            _error = AppFailure('合并库索引损坏，已只读载入备份；原文件未改动：$error');
          } else {
            rethrow;
          }
        }
      } else if (backup.existsSync()) {
        _videos = _readIndex(backup);
        // 上次在 index -> bak 后中断：回滚到上一个已提交版本。
        backup.renameSync(index.path);
      } else if (temporary.existsSync()) {
        _videos = _readIndex(temporary);
        temporary.renameSync(index.path);
      } else {
        // 缺失索引但留有媒体，也不是新安装，不能以空库覆盖用户文件。
        if (_type(_media()) != FileSystemEntityType.notFound) {
          _directoryOnly(_media());
          if (Directory(_media()).listSync(followLinks: false).isNotEmpty) {
            throw AppFailure('合并库索引丢失，已保留全部文件；请恢复索引后重试');
          }
        }
      }
      if (_type(_media()) == FileSystemEntityType.notFound) {
        Directory(_media()).createSync();
      }
      _rootSafe();
      _loaded = true;
      _writable = !readOnly;
      if (!readOnly) {
        if (!index.existsSync()) await _persist(_videos);
        if (temporary.existsSync()) temporary.deleteSync();
        _recoverOwnedDirectories();
      }
      for (final video in _videos) {
        try {
          _checkedFile(video);
        } catch (error) {
          _error ??= AppFailure('部分合并成品不可用，记录已保留：$error');
        }
      }
    } catch (error) {
      _writable = false;
      _error = AppFailure('无法读取合并库，未重置索引或删除成品：$error');
    }
    _notify();
  }

  static String _text(Object? value, int limit, {bool empty = false}) {
    if (value is! String ||
        value.length > limit ||
        (!empty && value.trim().isEmpty)) {
      throw const FormatException('合并库文本字段无效');
    }
    return value;
  }

  static List<int> _episodes(List<int> numbers) {
    if (numbers.length > 10000) throw AppFailure('合并分集数量超过上限');
    final result = numbers.toSet().toList()..sort();
    if (result.length < 2 ||
        result.length > 10000 ||
        result.any((number) => number < 1 || number > 100000)) {
      throw AppFailure('至少需要 2 个有效且不同的分集');
    }
    return result;
  }

  static Drama _identity(Drama drama) {
    // 不持久化 cover、sourceId、播放地址等可能携带签名/临时 URL 的字段。
    final id = _text(drama.id, 512);
    final source = _text(drama.source, 80);
    if (id.contains('://') || source.contains('://')) {
      throw AppFailure('剧集标识不能使用临时地址');
    }
    return Drama(
      id: id,
      source: source,
      title: _text(drama.title, 512),
      category: _text(drama.category, 256, empty: true),
      episodes: drama.episodes.clamp(0, 100000).toInt(),
    );
  }

  Map<String, Object> _encode(MergedVideo video) => {
    'id': video.id,
    'drama': {
      'id': video.drama.id,
      'source': video.drama.source,
      'title': video.drama.title,
      'category': video.drama.category,
      'episodes': video.drama.episodes,
    },
    'episodes': video.episodes,
    'bytes': video.bytes,
    'createdAt': video.createdAt.toUtc().toIso8601String(),
    'fileName': video.fileName,
    // 固定 POSIX 相对键，不将任何平台的绝对目录写进索引。
    'file': 'media/${video.id}/video.mp4',
  };

  List<MergedVideo> _readIndex(File file) {
    if (file.lengthSync() > _maxIndexBytes) {
      throw const FormatException('合并库索引超过限额');
    }
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final rows = data['videos'] as List;
    if (data['version'] != 1 || rows.length > _maxVideos) {
      throw const FormatException('合并库索引版本或条目数无效');
    }
    final ids = <String>{};
    final videos = <MergedVideo>[];
    for (final row in rows) {
      final value = row as Map<String, dynamic>;
      final id = _text(value['id'], 32);
      final bytes = value['bytes'];
      final name = _text(value['fileName'], 1024);
      final numbers = (value['episodes'] as List).cast<int>();
      if (!_idPattern.hasMatch(id) ||
          !ids.add(id) ||
          value['file'] != 'media/$id/video.mp4' ||
          bytes is! int || bytes <= 0 || bytes > _maxMediaBytes ||
          name.contains('/') || name.contains('\\') ||
          !name.endsWith('.mp4') || numbers.length > 10000) {
        throw const FormatException('合并库条目或相对路径无效');
      }
      videos.add(MergedVideo(
        id: id,
        drama: _identity(Drama.fromJson(value['drama'] as Map<String, dynamic>)),
        episodes: _episodes(numbers),
        bytes: bytes,
        createdAt: DateTime.parse(_text(value['createdAt'], 64)).toUtc(),
        fileName: name,
      ));
    }
    return _ordered(videos);
  }

  List<MergedVideo> _ordered(List<MergedVideo> videos) => List.unmodifiable(
    List<MergedVideo>.of(videos)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
  );

  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then<T>((_) async {
      await ensureInitialized();
      return action();
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  void _requireWritable() {
    if (_disposed) throw AppFailure('合并库已关闭');
    if (!_writable) throw AppFailure('合并库不可写：${_error ?? "尚未初始化"}');
    _rootSafe();
  }

  /// 提交点为最后一次同步 rename；检查取消后不再让出执行权。
  Future<void> _persist(
    List<MergedVideo> videos, {
    void Function()? check,
  }) async {
    _rootSafe();
    final index = File(_at('index.json'));
    final temporary = File(_at('index.json.tmp'));
    final backup = File(_at('index.json.bak'));
    for (final file in [index, temporary, backup]) {
      _regularOrAbsent(file.path);
    }
    final encoded = jsonEncode({
      'version': 1,
      'videos': videos.map(_encode).toList(),
    });
    if (utf8.encode(encoded).length > _maxIndexBytes) {
      throw AppFailure('合并库索引已达到容量上限');
    }
    var rotated = false;
    try {
      check?.call();
      await temporary.writeAsString(encoded, flush: true);
      check?.call();
      _rootSafe();
      for (final file in [index, temporary, backup]) {
        _regularOrAbsent(file.path);
      }
      if (backup.existsSync()) backup.deleteSync();
      if (index.existsSync()) {
        index.renameSync(backup.path);
        rotated = true;
      }
      temporary.renameSync(index.path);
    } catch (_) {
      try {
        _rootSafe();
        for (final file in [index, temporary, backup]) {
          _regularOrAbsent(file.path);
        }
        if (rotated && !index.existsSync()) backup.renameSync(index.path);
        if (temporary.existsSync()) temporary.deleteSync();
      } catch (error) {
        // 无法回滚时冻结写入，避免下一次提交掩盖需要恢复的事务。
        _writable = false;
        _problem(AppFailure('合并库事务回滚失败，请重启恢复：$error'));
      }
      rethrow;
    }
  }

  bool _owned(String id) {
    _rootSafe();
    _directoryOnly(_folder(id));
    final marker = _file(id, '.owner');
    if (_type(marker) != FileSystemEntityType.file ||
        File(marker).lengthSync() != _owner.length) {
      return false;
    }
    return File(marker).readAsStringSync() == _owner;
  }

  String _checkedFile(MergedVideo video) {
    if (!_owned(video.id)) throw AppFailure('合并成品目录不属于本应用');
    final file = _file(video.id, 'video.mp4');
    if (_type(file) != FileSystemEntityType.file ||
        File(file).lengthSync() != video.bytes) {
      throw AppFailure('合并成品文件丢失、不是普通文件或大小异常：${video.fileName}');
    }
    return file;
  }

  Future<String> fileFor(MergedVideo video) async {
    await ensureInitialized();
    try {
      if (!_loaded || _disposed) throw AppFailure('合并库不可用');
      final stored = _videos.where((item) => item.id == video.id).firstOrNull;
      if (stored == null) throw AppFailure('合并成品记录不存在');
      return _checkedFile(stored);
    } catch (error) {
      _problem(error);
      rethrow;
    }
  }

  void _deleteOwnedDirectory(String id, {bool includeVideo = true}) {
    _rootSafe();
    if (_type(_folder(id)) == FileSystemEntityType.notFound) return;
    if (!_owned(id)) throw AppFailure('拒绝删除非本应用的成品目录');
    final children = Directory(_folder(id)).listSync(followLinks: false);
    final allowed = {
      '.owner',
      '.pending',
      'writing.mp4',
      if (includeVideo) 'video.mp4',
    };
    // 完整预检后才删除；不递归，不跟随链接，也不碰未知子项。
    for (final child in children) {
      if (!allowed.contains(path.basename(child.path)) ||
          _type(child.path) != FileSystemEntityType.file) {
        throw AppFailure('成品目录含链接或未知文件，已保留：$id');
      }
    }
    // 先删媒体，后删事务标记；媒体删除失败仍可在重启时识别暂存事务。
    for (final name in ['writing.mp4', 'video.mp4', '.pending']) {
      if (allowed.contains(name) &&
          _type(_file(id, name)) == FileSystemEntityType.file) {
        File(_file(id, name)).deleteSync();
      }
    }
    // 归属标记最后删除；若空目录删除失败，恢复标记以供重试。
    final marker = File(_file(id, '.owner'));
    marker.deleteSync();
    try {
      Directory(_folder(id)).deleteSync(recursive: false);
    } catch (_) {
      if (_type(_folder(id)) == FileSystemEntityType.directory &&
          _type(marker.path) == FileSystemEntityType.notFound) {
        marker.writeAsStringSync(_owner, flush: true);
      }
      rethrow;
    }
  }

  void _recoverOwnedDirectories() {
    final ids = _videos.map((video) => video.id).toSet();
    for (final child in Directory(_media()).listSync(followLinks: false)) {
      final id = path.basename(child.path);
      if (!_idPattern.hasMatch(id) || ids.contains(id)) continue;
      try {
        // 仅清扫有未提交标记的自有目录，不推测删除已提交但失联的文件。
        if (_type(child.path) != FileSystemEntityType.directory ||
            !_owned(id)) {
          continue;
        }
        final pending = File(_file(id, '.pending'));
        if (_type(pending.path) != FileSystemEntityType.file ||
            pending.lengthSync() != _owner.length ||
            pending.readAsStringSync() != _owner) {
          continue;
        }
        _deleteOwnedDirectory(id);
      } catch (error) {
        _error ??= AppFailure('未完成事务的目录已保留：$error');
      }
    }
  }

  Future<MergedVideo> create(
    Drama drama,
    List<int> episodes,
    Future<void> Function(String path) write, {
    bool Function()? cancelled,
  }) => _serial(() async {
    var id = '';
    int? expectedBytes;
    var committed = false, allocated = false, promoted = false;
    void check() {
      _requireWritable();
      if (cancelled?.call() ?? false) throw _MergedWriteCancelled();
      if (allocated && !_owned(id)) {
        throw AppFailure('合并输出目录的归属发生变化');
      }
      if (promoted && (_type(_file(id, 'video.mp4')) != FileSystemEntityType.file ||
          File(_file(id, 'video.mp4')).lengthSync() != expectedBytes)) {
        throw AppFailure('提交前合并输出丢失或发生变化');
      }
    }
    try {
      check();
      if (_videos.length >= _maxVideos) throw AppFailure('合并库条目已达到上限');
      final identity = _identity(drama);
      final numbers = _episodes(episodes);
      do {
        id = List.generate(
          16,
          (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join();
      } while (_type(_folder(id)) != FileSystemEntityType.notFound);
      Directory(_folder(id)).createSync();
      allocated = true;
      File(_file(id, '.owner')).writeAsStringSync(_owner, flush: true);
      File(_file(id, '.pending')).writeAsStringSync(_owner, flush: true);
      final temporary = _file(id, 'writing.mp4');
      check();
      await write(temporary);
      check();
      if (_type(temporary) != FileSystemEntityType.file) {
        throw AppFailure('合并输出不是普通文件');
      }
      final bytes = File(temporary).lengthSync();
      expectedBytes = bytes;
      if (bytes <= 0 || bytes > _maxMediaBytes) throw AppFailure('合并输出大小无效');
      final title = identity.title.length > 160
          ? identity.title.substring(0, 160)
          : identity.title;
      final video = MergedVideo(
        id: id,
        drama: identity,
        episodes: numbers,
        bytes: bytes,
        createdAt: _now().toUtc(),
        fileName: mergeFileName(title, numbers),
      );
      final destination = _file(id, 'video.mp4');
      if (_type(destination) != FileSystemEntityType.notFound) {
        throw AppFailure('合并目标已存在，拒绝覆盖');
      }
      check();
      File(temporary).renameSync(destination);
      promoted = true;
      final next = _ordered([..._videos, video]);
      await _persist(next, check: check);
      committed = true;
      _videos = next;
      // 提交后移除暂存标记；失败不影响已提交成品，索引仍是唯一提交依据。
      try {
        File(_file(id, '.pending')).deleteSync();
      } catch (_) {}
      _notify();
      return video;
    } catch (error) {
      if (error is MediaCleanupPending) {
        // 不在 _serial 内等待原生退出；仅该暂存目录隔离，其他成品仍可删除。
        unawaited(() async {
          try {
            await error.whenSafe();
            await _serial(() async { if (allocated) _deleteOwnedDirectory(id); });
          } catch (cleanup) {
            _problem(AppFailure('合并临时目录已保留，待退出后清理：$cleanup'));
          }
        }());
        rethrow;
      }
      var cleanCancellation = error is _MergedWriteCancelled ||
          (cancelled?.call() ?? false);
      Object failure = error;
      if (!committed && allocated) {
        try {
          if (!_owned(id) &&
              Directory(_folder(id)).listSync(followLinks: false).isEmpty) {
            Directory(_folder(id)).deleteSync();
          } else {
            _deleteOwnedDirectory(id, includeVideo: promoted);
          }
        } catch (cleanup) {
          failure = AppFailure('$error；待恢复目录 $id 未能清理：$cleanup');
          cleanCancellation = false;
        }
      }
      // 清理失败会被包装为普通故障，仍需展示；干净取消只交给任务状态。
      if (!cleanCancellation) _problem(failure);
      throw failure;
    }
  });

  /// 每条独立提交；删除失败或索引失败时保留该记录，允许重试。
  Future<Map<String, String>> remove(Set<String> ids) => _serial(() async {
    final failures = <String, String>{};
    for (final id in ids) {
      try {
        _requireWritable();
        if (!_idPattern.hasMatch(id)) throw AppFailure('合并成品 ID 无效');
        if (!_videos.any((video) => video.id == id)) continue;
        // 先删自有媒体再提交索引：失败最多留下可见的缺失记录，不丢失败项。
        _deleteOwnedDirectory(id);
        final next = _videos.where((video) => video.id != id).toList();
        await _persist(next);
        _videos = _ordered(next);
        _notify();
      } catch (error) {
        failures[id] = '$error';
        _problem(error);
      }
    }
    return failures;
  });

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
