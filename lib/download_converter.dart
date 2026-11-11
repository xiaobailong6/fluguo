import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'media_trace.dart';
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
  bool _retiring = false;
  MediaTrace? _trace;

  double? progressOf(String id) => id == _current ? _progress : null;
  String? errorOf(String id) => _errors[id];

  void retry(String id) {
    if (_disposed || _retiring || _current == id) return;
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
    if (_suspended || _disposed || _retiring) return;
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
    final trace = MediaTrace('下载转换');
    _trace = trace;
    trace.start('剧名=${job.drama.title}，第 ${job.episode.number} 集，站源=${job.drama.source}，下载大小=${job.bytes}B');
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
        trace.event('待办保存失败', '$error');
        _skipped.add(job.id);
        return;
      }
      if (_cancelled) return;
      final DownloadConversion work;
      try {
        work = await repository.beginConversion(job.id);
        begun = true;
        trace.event('转换占用', '取得原生占用，输入类型=${path.extension(work.input)}，需解密=${work.key.isNotEmpty}');
      } catch (_) {
        _errors[job.id] = '无法开始处理，请重试或重新下载';
        _skipped.add(job.id);
        rethrow;
      }
      if (_cancelled) return;
      final duration = await _duration(work.input);
      trace.event('输入探测', '时长=$duration 秒；MP4 流复制转封装');
      if (_cancelled) return;
      result = 'failed';
      await executor.run(
        arguments(work),
        duration: duration,
        progress: (value) {
          _progress = value;
          trace.progress('转封装进度', value);
          if (!_disposed) notifyListeners();
        },
      );
      verifyMediaDuration(await executor.probe(work.output), duration);
      trace.event('输出校验', '视频轨和时长校验通过');
      result = _cancelled ? 'cancel' : 'done';
    } catch (error) {
      // 失败与取消必须分清：初值是 cancel，若在这里不显式改成 failed，
      // 原生侧会把真实失败当成用户取消，既不记录也不再重试。
      if (_cancelled) {
        result = 'cancel';
      } else {
        result = 'failed';
        trace.event('转换失败', '$error');
      }
    } finally {
      try {
        if (executor case MediaExitAware aware) await aware.waitForIdle();
      } catch (error) {
        _retiring = true;
        trace.event('退出未确认', '$error；保留输入文件');
        _skipped.add(job.id);
        _errors[job.id] = '媒体处理尚未退出，原文件已保留：$error';
        _current = null;
        _progress = null;
        unawaited(_finishAfterExit(job.id, begun));
        if (!_disposed) {
          notifyListeners();
          await downloads.refresh();
          _sync();
        }
        return;
      }
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
        trace.event('提交失败', '$error');
      }
      trace.end('结果=$result，已开始=$begun');
      if (identical(_trace, trace)) _trace = null;
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

  Future<void> _finishAfterExit(String id, bool begun) async {
    while (true) {
      try {
        if (executor case MediaExitAware aware) await aware.waitForIdle();
        if (begun) await repository.finishConversion(id, 'cancel');
        _trace?.event('退出后收尾', '原生已退出，取消结果已提交');
        _trace?.end('取消收尾完成');
        _trace = null;
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    _skipped.remove(id);
    _errors.remove(id);
    _retiring = false;
    if (!_disposed) {
      await downloads.refresh();
      _sync();
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
    _trace?.event('取消请求', '停止当前分集媒体处理');
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
