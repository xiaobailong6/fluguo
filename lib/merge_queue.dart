import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_device.dart';
import 'background_downloads.dart';
import 'core_bridge.dart';
import 'diary_service.dart';
import 'download_merge.dart';
import 'local_store.dart';
import 'media_pipeline.dart';
import 'merged_library.dart';
import 'models.dart';

export 'merged_library.dart';

enum MergeState { queued, running, done, failed, cancelled }

typedef MergeSave =
    Future<String> Function(DownloadMerge merge, MergeTask task);

class MergeTask {
  MergeTask._(this.id, List<DownloadJob> jobs, this.file)
    : jobs = List.unmodifiable(
        List.of(jobs)
          ..sort((a, b) => a.episode.number.compareTo(b.episode.number)),
      );

  final int id;
  final List<DownloadJob> jobs;
  final String? file;
  MergeState state = MergeState.queued;
  String status = '等待合并';
  double? progress;
  Duration? remaining;
  String message = '';
  String? outputId;

  Drama get drama => jobs.first.drama;
  String get fileName => mergeJobsFileName(jobs);
  bool get finished => state.index >= MergeState.done.index;
}

class MergeQueue extends ChangeNotifier {
  MergeQueue(
    this.repository, {
    MediaExecutor Function()? executor,
    MergeSave? save,
    DateTime Function()? now,
    MergedLibrary? library,
    LocalStore? store,
  }) : library = library ?? MergedLibrary(),
       _ownsLibrary = library == null,
       _executor = executor ?? FFmpegExecutor.new,
       _now = now ?? DateTime.now,
       _store = store,
       _epoch = store?.profileEpoch {
    _save = save ?? _saveManaged;
    this.library.addListener(_notify);
    _store?.addListener(_accessChanged);
    unawaited(this.library.ensureInitialized());
  }

  final AppRepository repository;
  final MediaExecutor Function() _executor;
  late final MergeSave _save;
  final DateTime Function() _now;
  final MergedLibrary library;
  final bool _ownsLibrary;
  final LocalStore? _store;
  final int? _epoch;
  final tasks = <MergeTask>[];
  ValueChanged<MergeTask>? onFinished;
  DownloadMerge? _merge;
  int _nextId = 0;
  bool _running = false, _disposed = false;

  int get active => tasks.where((task) => !task.finished).length;

  bool _allowed(Drama drama) => _store == null ||
      _store.profileEpoch == _epoch &&
      _store.canDownload &&
      _store.allowsSource(drama.source);

  void _accessChanged() {
    if (_disposed) return;
    for (final task in tasks) {
      if (task.finished || _allowed(task.drama)) continue;
      if (task.state == MergeState.running) {
        _merge?.cancel();
      } else {
        task
          ..state = MergeState.cancelled
          ..message = '用户或权限已变更，已取消合并';
      }
    }
    _notify();
  }

  void add(List<DownloadJob> jobs, {String? file}) {
    if (_disposed) throw AppFailure('合并队列已关闭');
    final completed = jobs
        .where((job) => job.completed && job.episode.number > 0 &&
            job.episode.number <= 100000)
        .toList();
    if (completed.any((job) =>
        job.drama.id != completed.first.drama.id ||
        job.drama.source != completed.first.drama.source)) {
      throw AppFailure('只能合并同一部剧的分集');
    }
    final unique = <int, DownloadJob>{
      for (final job in completed) job.episode.number: job,
    }.values.toList()
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    if (unique.length < 2) throw AppFailure('至少选择 2 个已完成的不同分集');
    if (!_allowed(unique.first.drama)) throw AppFailure('当前用户没有此剧的合并权限');
    final numbers = unique.map((job) => job.episode.number).toList();
    if (tasks.any((task) =>
        !task.finished &&
        task.drama.id == unique.first.drama.id &&
        task.drama.source == unique.first.drama.source &&
        listEquals(
          task.jobs.map((job) => job.episode.number).toList(), numbers,
        ))) {
      throw AppFailure('相同分集合并任务已在队列中');
    }
    tasks.add(MergeTask._(++_nextId, unique, file));
    _notify();
    unawaited(_pump());
  }

  void cancel(MergeTask task) {
    if (task.state == MergeState.running) {
      _merge?.cancel();
    } else if (task.state == MergeState.queued) {
      task
        ..state = MergeState.cancelled
        ..message = '已取消合并';
      _notify();
    }
  }

  void clearFinished() {
    tasks.removeWhere((task) => task.finished);
    _notify();
  }

  Future<void> _pump() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      try {
        await BackgroundDownloads.ensureStarted();
      } catch (_) {}
      try {
        await repository.workLease('merge', 'start');
      } catch (error) {
        for (final task in tasks) {
          if (task.state != MergeState.queued) continue;
          task
            ..state = MergeState.failed
            ..message = '$error';
          if (!_disposed) onFinished?.call(task);
        }
        _notify();
        return;
      }
      try {
        while (!_disposed) {
          final task = tasks
              .where((task) => task.state == MergeState.queued)
              .firstOrNull;
          if (task == null) break;
          await _run(task);
        }
      } finally {
        try {
          await repository.workLease('merge', 'end');
        } catch (_) {}
      }
    } finally {
      _running = false;
    }
    if (tasks.any((task) => task.state == MergeState.queued)) {
      unawaited(_pump());
    }
  }

  Future<void> _run(MergeTask task) async {
    final merge = _merge = DownloadMerge(repository, executor: _executor());
    var phase = '';
    var phaseStart = _now();
    void sync() {
      if (merge.status != phase) {
        phase = merge.status;
        phaseStart = _now();
      }
      task
        ..status = merge.status
        ..progress = merge.progress
        ..remaining = mergeRemaining(
          merge.progress,
          _now().difference(phaseStart),
        );
      _notify();
    }

    task.state = MergeState.running;
    merge.addListener(sync);
    sync();
    try {
      if (!_allowed(task.drama)) {
        merge.cancel();
        throw AppFailure('用户或权限已变更，已取消合并');
      }
      await merge.prepare(task.jobs);
      if (merge.cancelled || _disposed) throw AppFailure('已取消合并');
      task.message = await _save(merge, task);
      if (task.outputId == null && (merge.cancelled || _disposed)) {
        throw AppFailure('已取消合并');
      }
      task.state = MergeState.done;
    } catch (error) {
      if (task.outputId != null) {
        // 已提交的内部成品不会因为后续外部导出失败/取消而变成失败任务。
        task
          ..state = MergeState.done
          ..message = '已保存到合并成品库；外部导出未完成：$error';
      } else if (merge.cancelled || _disposed) {
        task
          ..state = MergeState.cancelled
          ..message = '已取消合并';
      } else {
        task
          ..state = MergeState.failed
          ..message = '$error';
        DiaryService.add('[下载] 合并「${task.fileName}」失败：$error');
      }
    } finally {
      merge
        ..removeListener(sync)
        ..dispose();
      _merge = null;
      task
        ..progress = null
        ..remaining = null;
      _notify();
      if (!_disposed) onFinished?.call(task);
    }
  }

  Future<String> _saveManaged(DownloadMerge merge, MergeTask task) async {
    bool stopped() => merge.cancelled || _disposed || !_allowed(task.drama);
    final video = await library.create(
      task.drama,
      task.jobs.map((job) => job.episode.number).toList(),
      (temporary) => merge.write(temporary, file: temporary),
      cancelled: stopped,
    );
    task.outputId = video.id;
    // 合并与导出是两个独立功能：默认只提交内部成品，导出由成品菜单单独触发。
    const saved = '已保存到合并成品库';
    if (task.file == null) return saved;
    // 只有显式给出目标位置时才顺带复制一份，复制失败也不移除内部成品。
    try {
      if (stopped()) return '$saved；已取消外部副本';
      final managed = await library.fileFor(video);
      if (stopped()) return '$saved；已取消外部副本';
      final destination = task.file!;
      final target = path.normalize(path.absolute(destination));
      final root = path.dirname(path.dirname(path.dirname(managed)));
      if (path.equals(target, root) || path.isWithin(root, target)) {
        throw AppFailure('外部导出位置不能位于成品库内');
      }
      if (FileSystemEntity.typeSync(target, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw AppFailure('导出目标已存在，未覆盖原文件');
      }
      await File(managed).copy(target);
      return stopped()
          ? '$saved；外部副本已保存到 $destination（取消时已完成）'
          : '$saved；已导出到 $destination';
    } catch (error) {
      return '$saved；外部导出失败，可从成品库播放：$error';
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _merge?.cancel();
    _store?.removeListener(_accessChanged);
    library.removeListener(_notify);
    if (_ownsLibrary) library.dispose();
    super.dispose();
  }
}

String mergeJobsFileName(List<DownloadJob> jobs) {
  final numbers = [for (final job in jobs) job.episode.number]..sort();
  return mergeFileName(jobs.first.drama.title, numbers);
}

Duration? mergeRemaining(double? progress, Duration elapsed) {
  if (progress == null ||
      progress < .03 ||
      progress >= 1 ||
      elapsed < const Duration(seconds: 2)) {
    return null;
  }
  return elapsed * ((1 - progress) / progress);
}

Future<String> saveMerge(DownloadMerge merge, MergeTask task) async {
  if (task.file case final file?) {
    await merge.write(file, file: file);
    return '已保存到 $file';
  }
  if (Platform.isIOS) {
    final directory = Directory(
      path.join((await getApplicationDocumentsDirectory()).path, '合并视频'),
    );
    await directory.create(recursive: true);
    final file = unusedMergeFile(directory.path, merge.fileName);
    await merge.write(file, file: file);
    return '已保存到「文件」App 里本应用的「合并视频」文件夹';
  }
  if (!Platform.isAndroid) throw AppFailure('没有选择保存位置');
  final folder = safeFileName(task.drama.title);
  final temporary = await (await getTemporaryDirectory()).createTemp('merge');
  try {
    final file = path.join(temporary.path, merge.fileName);
    await merge.write(file, file: file);
    await AppDevice.exportVideo(file, folder, merge.fileName);
  } finally {
    try {
      await temporary.delete(recursive: true);
    } catch (_) {}
  }
  return '已保存到 Movies/$folder';
}

String unusedMergeFile(String directory, String name) {
  final stem = path.basenameWithoutExtension(name);
  var file = path.join(directory, name);
  for (var attempt = 2; File(file).existsSync(); attempt++) {
    file = path.join(directory, '$stem ($attempt).mp4');
  }
  return file;
}
