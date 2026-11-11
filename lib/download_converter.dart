import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'diary_service.dart';
import 'download_auto_export.dart';
import 'download_overview.dart';
import 'media_pipeline.dart';
import 'models.dart';

class DownloadConverter extends ChangeNotifier {
  DownloadConverter(
    this.repository,
    this.downloads, {
    MediaExecutor? executor,
    this.inUse,
  }) : executor = executor ?? FFmpegExecutor() {
    autoExporter = DownloadAutoExporter(repository, downloads, inUse: inUse);
    autoExporter.addListener(_exportChanged);
    downloads.addListener(_sync);
    if (Platform.isIOS) {
      _lifecycle = AppLifecycleListener(onPause: _suspend, onResume: _resume);
    }
    _sync();
  }

  final AppRepository repository;
  final DownloadOverview downloads;
  final MediaExecutor executor;
  final bool Function(String id)? inUse;
  late final DownloadAutoExporter autoExporter;

  void _exportChanged() {
    if (!_disposed) notifyListeners();
  }
  AppLifecycleListener? _lifecycle;
  final _skipped = <String>{};
  final _errors = <String, String>{};
  String? _current;
  double? _progress;
  bool _cancelled = false, _suspended = false, _disposed = false;

  double? progressOf(String id) => id == _current ? _progress : null;
  String? errorOf(String id) => _errors[id];

  void retry(String id) {
    if (_disposed || _current == id) return;
    _skipped.remove(id);
    _errors.remove(id);
    _sync();
  }

  static List<String> arguments(DownloadConversion work) => [
    if (work.key.isNotEmpty) ...['-decryption_key', work.key],
    if (path.extension(work.input).toLowerCase() == '.m3u8') ...[
      '-allowed_extensions',
      'ALL',
      '-extension_picky',
      '0',
    ],
    '-i',
    work.input,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c',
    'copy',
    '-movflags',
    '+faststart',
    work.output,
  ];

  void _sync() {
    _skipped.removeWhere(
      (id) => !downloads.jobs.any((job) => job.id == id && job.converting),
    );
    _errors.removeWhere(
      (id, _) => !downloads.jobs.any((job) => job.id == id && job.converting),
    );
    final current = _current;
    if (current != null) {
      if (!downloads.jobs.any((job) => job.id == current && job.converting)) {
        _cancel();
      }
      return;
    }
    if (_suspended || _disposed) return;
    DownloadJob? next;
    for (final job in downloads.jobs) {
      if (!job.converting || _skipped.contains(job.id)) continue;
      if (next == null ||
          job.created < next.created ||
          job.created == next.created &&
              job.episode.number < next.episode.number) {
        next = job;
      }
    }
    if (next != null) unawaited(_convert(next));
  }

  Future<void> _convert(DownloadJob job) async {
    _current = job.id;
    _progress = 0;
    _cancelled = false;
    notifyListeners();
    var result = 'cancel';
    var begun = false;
    try {
      try {
        await autoExporter.queue(job);
      } catch (error) {
        _errors[job.id] = '自动导出待办无法保存，处理已暂停：$error';
        _skipped.add(job.id);
        return;
      }
      if (_cancelled) return;
      final DownloadConversion work;
      try {
        work = await repository.beginConversion(job.id);
        begun = true;
      } catch (_) {
        _errors[job.id] = '无法开始处理，请重试或重新下载';
        _skipped.add(job.id);
        rethrow;
      }
      if (_cancelled) return;
      final duration = await _duration(work.input);
      if (_cancelled) return;
      result = 'failed';
      await executor.run(
        arguments(work),
        duration: duration,
        progress: (value) {
          _progress = value;
          if (!_disposed) notifyListeners();
        },
      );
      verifyMediaDuration(await executor.probe(work.output), duration);
      result = _cancelled ? 'cancel' : 'done';
    } catch (error) {
      // 失败与取消必须分清：初值是 cancel，若在这里不显式改成 failed，
      // 原生侧会把真实失败当成用户取消，既不记录也不再重试。
      if (_cancelled) {
        result = 'cancel';
      } else {
        result = 'failed';
        DiaryService.add(
          '[下载] ${job.drama.title} 第 ${job.episode.number} 集转换失败：$error',
        );
      }
    } finally {
      if (executor case MediaExitAware aware) await aware.waitForIdle();
      try {
        try {
          if (begun) await repository.finishConversion(job.id, result);
        } catch (_) {
          // rename 后索引提交失败时，原生支持幂等补交，不必重新转换视频。
          if (begun && result == 'done') {
            await repository.finishConversion(job.id, result);
          } else {
            rethrow;
          }
        }
      } catch (error) {
        // 提交失败可能尚未 rename，也可能只差索引补交；不能无休止地重新转码。
        _skipped.add(job.id);
        result = 'failed';
        _errors[job.id] = '$error';
        DiaryService.add(
          '[下载] ${job.drama.title} 第 ${job.episode.number} 集处理结果保存失败：$error',
        );
      }
      _current = null;
      _progress = null;
      if (!_disposed) {
        notifyListeners();
        await downloads.refresh();
        if (!_disposed) notifyListeners();
        _sync();
      }
    }
  }

  Future<double> _duration(String input) async {
    try {
      return (await executor.probe(input)).duration;
    } catch (_) {
      return 0;
    }
  }

  void _cancel() {
    if (_current == null || _cancelled) return;
    _cancelled = true;
    unawaited(executor.cancel());
  }

  void _suspend() {
    _suspended = true;
    _cancel();
  }

  void _resume() {
    _suspended = false;
    _sync();
  }

  @override
  void dispose() {
    _disposed = true;
    autoExporter.removeListener(_exportChanged);
    autoExporter.dispose();
    downloads.removeListener(_sync);
    _lifecycle?.dispose();
    _cancel();
    super.dispose();
  }
}
