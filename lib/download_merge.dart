import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'media_pipeline.dart';
import 'download_normalization.dart';
import 'media_trace.dart';
import 'media_cleanup.dart';
import 'models.dart';

String episodeRanges(List<int> numbers) {
  final parts = <String>[];
  for (var i = 0; i < numbers.length; i++) {
    final start = numbers[i];
    while (i + 1 < numbers.length && numbers[i + 1] == numbers[i] + 1) {
      i++;
    }
    parts.add(start == numbers[i] ? '$start' : '$start-${numbers[i]}');
  }
  return parts.join('、');
}

String safeFileName(String title) {
  var name = String.fromCharCodes(title.runes.take(60))
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'^[\s.]+|[\s.]+$'), '');
  if (RegExp(
    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
    caseSensitive: false,
  ).hasMatch(name)) {
    name = '_$name';
  }
  return name.isEmpty ? '未命名' : name;
}

String mergeFileName(String title, List<int> numbers) {
  final ranges = episodeRanges(numbers);
  final episodes = ranges.length <= 40
      ? '第$ranges集'
      : '第${numbers.first}-${numbers.last}集等${numbers.length}集';
  return '${safeFileName(title)} $episodes.mp4';
}

// concat 的流顺序与编码参数必须一致，不能只比较分辨率和编码名称。
String _signature(MediaProbe probe) => mergeMediaFormat(probe);

double? _frameRate(Object? value) {
  final parts = '$value'.split('/');
  if (parts.length != 2) return double.tryParse('$value');
  final numerator = double.tryParse(parts[0]);
  final denominator = double.tryParse(parts[1]);
  if (numerator == null || denominator == null || denominator == 0) return null;
  return numerator / denominator;
}

/// 只在分集格式不一致时统一编码；画面跟随参考集，声音统一且不丢有声分集。
List<String> unifyArguments(
  String source,
  String output,
  MediaProbe reference, {
  required MediaProbe input,
}) {
  final video = reference.video;
  final width = video['width'];
  final height = video['height'];
  final hasAudio = reference.audio.isNotEmpty;
  final needSilence = hasAudio && input.audio.isEmpty;
  final rate = _frameRate(video['r_frame_rate'] ?? video['avg_frame_rate']);
  final fps = rate != null && rate.isFinite && rate > 0 ? rate : 25.0;
  final filters = <String>[
    'scale=trunc(iw*sar/2)*2:ih,setsar=1',
    if (width is int && height is int && width > 0 && height > 0) ...[
      // 偶数画布与可被 2 整除的缩放结果，避免竖屏/奇数尺寸被 x264 拒绝。
      'scale=$width:$height:force_original_aspect_ratio=decrease:force_divisible_by=2',
      'pad=$width:$height:(ow-iw)/2:(oh-ih)/2',
    ],
    'setsar=1',
    'fps=$fps',
  ];
  return [
    '-threads', '2',
    '-i',
    source,
    if (needSilence) ...['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo'],
    '-map',
    '0:v:0',
    if (hasAudio) ...['-map', needSilence ? '1:a:0' : '0:a:0'],
    '-vf',
    filters.join(','),
    // 限制 Android 多核设备的编码线程，避免多集转码内存峰值过高。
    '-threads', '2', '-filter_threads', '1',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-video_track_timescale',
    '90000',
    if (hasAudio) ...[
      '-c:a', 'aac', '-b:a', '128k', '-ar', '48000', '-ac', '2',
      // 音轨比画面短时补静音，长时裁到原视频时长，避免集与集之间音画漂移。
      if (input.duration.isFinite && input.duration > 0) ...['-af', 'apad'],
    ],
    if (input.duration.isFinite && input.duration > 0) ...[
      '-t', '${input.duration}',
    ] else if (needSilence)
      '-shortest',
    '-map_metadata', '-1', '-f', 'mp4', output,
  ];
}

String _concatLine(String file) {
  if (file.contains('\n') || file.contains('\r')) {
    throw AppFailure('文件路径不能包含换行');
  }
  return "file '${file.replaceAll("'", "'\\''")}'";
}

class DownloadMerge extends ChangeNotifier {
  DownloadMerge(this.repository, {MediaExecutor? executor, bool? androidHevcFallback})
    : executor = executor ?? FFmpegExecutor(),
      _androidHevcFallback = androidHevcFallback ?? Platform.isAndroid;

  final AppRepository repository;
  final MediaExecutor executor;
  final bool _androidHevcFallback;
  String status = '读取分集';
  double? progress;
  String fileName = '';
  final _files = <String>[];
  final _probes = <int, MediaProbe>{};
  final _numbers = <int>[];
  double _duration = 0;
  bool _normalize = false;
  MediaProbe? _reference;
  bool _cancelled = false;
  bool _disposed = false;
  int _callbackEpoch = 0;
  final _trace = MediaTrace('合并');
  void traceEvent(String stage, String message) => _trace.event(stage, message);
  final _jobs = <DownloadJob>[];
  final _different = <int>[];
  bool get needsConversion => _different.isNotEmpty;
  int get conversionTotal => _different.length;
  int conversionCompleted = 0;
  double? conversionProgress;
  double? mergeProgress;
  String phase = 'checking';
  final _deferred = <Future<void> Function()>[];
  Future<void>? _settling;
  bool get cleanupPending => _deferred.isNotEmpty;
  Future<void> settleDeferred() => _settling ??= _settleDeferred();

  Future<void> _settleDeferred() async {
    _trace.event('清理', '等待原生退出并清理隔离文件');
    while (true) {
      try {
        await waitForIdle();
        break;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    while (_deferred.isNotEmpty) {
      final cleanup = _deferred.first;
      try {
        await cleanup();
        _deferred.removeAt(0);
      } catch (_) {
        // 清理失败保留回调，后台退避重试，不能缓存永久失败的 Future。
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
    _trace.event('清理完成', '输入占用可释放');
  }

  Future<void> normalize() async {
    if (_different.isNotEmpty && conversionCompleted < conversionTotal) await _unify();
  }

  void _report(double value) {
    if (!value.isFinite || _cancelled || _disposed) return;
    final next = value.clamp(0.0, .99).toDouble();
    if (next > (progress ?? -1)) progress = next;
    _notify();
  }

  static const _probeWeight = .10;
  static const _normalizeWeight = .65;
  static const _concatWeight = .25;

  bool get cancelled => _cancelled;

  Future<void> waitForIdle() async {
    if (executor case MediaExitAware aware) await aware.waitForIdle();
  }

  static List<String> arguments(
    String list,
    String output, {
    required bool faststart,
  }) => [
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    list,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c',
    'copy',
    if (faststart) ...['-movflags', '+faststart'],
    '-f',
    'mp4',
    output,
  ];

  Future<void> prepare(List<DownloadJob> selected) async {
    _check();
    _trace.start('剧名=${selected.firstOrNull?.drama.title ?? "未知"}，选中 ${selected.length} 集，站源=${selected.firstOrNull?.drama.source ?? "未知"}');
    _files.clear();
    _probes.clear();
    _jobs.clear();
    _different.clear();
    phase = 'checking';
    conversionCompleted = 0;
    conversionProgress = null;
    mergeProgress = null;
    _numbers.clear();
    _duration = 0;
    _normalize = false;
    _reference = null;

    final latest = {for (final job in await repository.downloads()) job.id: job};
    _check();
    final jobs = [for (final job in selected) latest[job.id] ?? job]
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final numbers = [for (final job in jobs) job.episode.number];
    if (jobs.length < 2) throw AppFailure('至少选择 2 集');
    _numbers.addAll(numbers);
    fileName = mergeFileName(jobs.first.drama.title, numbers);
    final groups = <String, List<int>>{};

    for (final job in jobs) {
      status = '读取分集（第 ${job.episode.number} 集，${_files.length + 1}/${jobs.length}）';
      _notify();
      _check();
      final plan = await repository.localPlayback(job.drama, job.episode);
      _check();
      if (plan == null || !plan.local || plan.decryptionKey.isNotEmpty) {
        throw AppFailure('第 ${job.episode.number} 集没有完整的本地文件');
      }
      final MediaProbe probe;
      try {
        probe = await executor.probe(plan.url);
      } catch (error) {
        throw AppFailure('读取分集（第 ${job.episode.number} 集）：$error');
      }
      _check();
      if (probe.videoCodec.isEmpty ||
          !probe.duration.isFinite ||
          probe.duration <= 0) {
        throw AppFailure('第 ${job.episode.number} 集无法读取有效的视频轨或时长');
      }
      _trace.event('格式检查', '第 ${job.episode.number} 集，大小=${job.bytes}B，${normalizationSummary(probe)}');
      final index = _files.length;
      _files.add(plan.url);
      _jobs.add(job);
      _probes[index] = probe;
      _duration += probe.duration;
      (groups[_signature(probe)] ??= []).add(index);
      status = '读取分集';
      _report(_probeWeight * _files.length / jobs.length);
    }

    _check();
    _normalize = groups.length > 1;
    if (_normalize) {
      final groupsBySize = groups.values.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      // 有声集不能因无声集占多数而被丢音，优先以有声组为目标。
      final withAudio = groupsBySize.where((group) => _probes[group.first]!.audio.isNotEmpty);
      final majority = withAudio.firstOrNull ?? groupsBySize.first;
      _reference = _probes[majority.first]!;
      for (var index = 0; index < _files.length; index++) {
        if (_signature(_probes[index]!) != _signature(_reference!)) _different.add(index);
      }
      conversionProgress = 0;
    }
    _trace.event('检查完成', '共 ${_files.length} 集，总时长=${_duration.toStringAsFixed(1)}秒，异常 $conversionTotal 集');
    if (_reference != null) _trace.event('转换目标', normalizationSummary(_reference!));
    mergeProgress = 0;
    _notify();
  }

  Future<void> write(String output, {String? file}) async {
    _check();
    final temporary = await Directory.systemTemp.createTemp('merge');
    try {
      await normalize();
      _check();
      status = '合并视频';
      phase = 'merging';
      _trace.event('拼接开始', '流复制，${_files.length} 集，总时长=${_duration.toStringAsFixed(1)}秒，faststart=${file != null}');
      final concatStart = _normalize
          ? _probeWeight + _normalizeWeight
          : _probeWeight;
      final concatWeight = _normalize ? _concatWeight : 1 - _probeWeight;
      _report(concatStart);

      final list = File(path.join(temporary.path, 'concat.txt'));
      await list.writeAsString(
        'ffconcat version 1.0\n${_files.map(_concatLine).join('\n')}\n',
        flush: true,
      );
      _check();
      final epoch = ++_callbackEpoch;
      try {
        await executor.run(
          arguments(list.path, output, faststart: file != null),
          duration: _duration,
          progress: (value) {
            if (epoch == _callbackEpoch && value.isFinite) {
              final next = value.clamp(0.0, .99).toDouble();
              if (next > (mergeProgress ?? 0)) mergeProgress = next;
              _report(concatStart + concatWeight * value.clamp(0.0, 1.0));
              _trace.progress('拼接进度', next);
            }
          },
        );
      } catch (error) {
        throw AppFailure('合并视频（第 ${episodeRanges(_numbers)} 集）：$error');
      } finally {
        _callbackEpoch++;
      }
      _check();
      status = '验证合并结果';
      mergeProgress = .99;
      _report(.99);
      _trace.event('校验合并结果', '预期时长=${_duration.toStringAsFixed(1)}秒');
      try {
        verifyMediaDuration(await executor.probe(file ?? output), _duration);
      } catch (error) {
        throw AppFailure('验证合并结果（第 ${episodeRanges(_numbers)} 集）：$error');
      }
      _check();
      status = '合并完成';
      progress = 1;
      _trace.event('拼接完成', '输出校验通过，等待保存成品');
      _notify();
    } catch (error) {
      _trace.event(_cancelled ? '拼接取消' : '拼接失败', '$error');
      status = _cancelled ? '正在取消，等待媒体处理退出' : '等待媒体处理退出后清理';
      _notify();
      try {
        await waitForIdle();
      } catch (error) {
        if (file != null) _deferred.add(() async {
          if (await File(file).exists()) await File(file).delete();
        });
        _trace.event('退出未确认', '隔离输出，$error');
        throw MediaCleanupPending('$error；原分集已保留，正在后台清理', settleDeferred);
      }
      if (file != null) {
        try {
          await File(file).delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        if (cleanupPending) throw AppFailure('媒体尚未退出');
        await waitForIdle();
        await temporary.delete(recursive: true);
        _trace.event('清理临时输出', '原生已退出，临时目录已删除');
      } catch (_) {
        _deferred.add(() async {
          if (await temporary.exists()) await temporary.delete(recursive: true);
        });
      }
    }
  }

  Future<void> _runNormalization(
    DownloadConversion work, MediaProbe input, MediaProbe reference,
    void Function(double) report,
  ) async {
    try {
      await executor.run(normalizationArguments(work.input, work.output, reference, input: input),
        duration: input.duration, progress: report);
    } catch (softwareError) {
      if (!_androidHevcFallback || _cancelled || _disposed ||
          !canRetryAndroidHevc(softwareError, input, reference)) rethrow;
      await waitForIdle();
      _check();
      status = 'x265 不支持目标 Main，改用设备 HEVC 编码';
      _trace.event('编码器兼容回退', 'libx265 Main 初始化被拒绝，尝试 Android MediaCodec；$softwareError');
      _notify();
      try {
        await executor.run(normalizationArguments(work.input, work.output, reference,
            input: input, androidHevc: true), duration: input.duration, progress: report);
        _trace.event('设备编码完成', '等待格式和时长校验，不放宽目标规格');
      } catch (hardwareError) {
        throw AppFailure('x265 无法生成目标8位 Main，设备 HEVC 编码也未完成。'
            '\n软件编码错误：$softwareError\n设备编码错误：$hardwareError\n原单集未替换。');
      }
    }
  }

  Future<void> _unify() async {
    phase = 'converting';
    status = '转换异常分集';
    _report(_probeWeight);
    final duration = _different.fold<double>(0, (sum, index) => sum + _probes[index]!.duration);
    var completedDuration = 0.0;
    for (final index in _different) {
      _check();
      final input = _probes[index]!;
      final job = _jobs[index];
      final mode = normalizationMode(input, _reference!);
      _trace.event('分集转换', '第 ${_numbers[index]} 集，$mode；输入=${normalizationSummary(input)}；目标=${normalizationSummary(_reference!)}');
      status = '$mode（第 ${_numbers[index]} 集，${conversionCompleted + 1}/$conversionTotal）';
      // 参数先验证，避免取得原生占用后才发现编码器无法生成目标规格。
      try {
        normalizationArguments(_files[index], '${_files[index]}.normalize.mp4', _reference!, input: input);
      } catch (error) {
        _trace.event('预检失败', '第 ${_numbers[index]} 集：$error');
        throw AppFailure('转换预检（第 ${_numbers[index]} 集，$mode）：$error'
            '\n输入：${normalizationSummary(input)}\n目标：${normalizationSummary(_reference!)}');
      }
      _notify();
      final work = await repository.beginNormalization(job);
      _trace.event('转换占用', '已取得第 ${_numbers[index]} 集占用');
      var finished = false;
      final epoch = ++_callbackEpoch;
      final start = completedDuration;
      try {
        _check();
        await _runNormalization(work, input, _reference!, (value) {
            if (epoch != _callbackEpoch || !value.isFinite) return;
            final next = ((start + input.duration * value.clamp(0.0, 1.0)) / duration).clamp(0.0, .99).toDouble();
            if (next > (conversionProgress ?? 0)) conversionProgress = next;
            _report(_probeWeight + _normalizeWeight * conversionProgress!);
            _trace.progress('第${_numbers[index]}集转换进度', value);
          },
        );
        _check();
        status = '校验并保存第 ${_numbers[index]} 集';
        _notify();
        final normalized = await executor.probe(work.output);
        verifyMediaDuration(normalized, input.duration);
        _trace.event('分集校验', '第 ${_numbers[index]} 集，输出=${normalizationSummary(normalized)}');
        if (_signature(normalized) != _signature(_reference!)) {
          throw AppFailure('第 ${_numbers[index]} 集转换后未匹配目标音视频格式，原文件未替换。'
              '\n${normalizationMismatch(normalized, _reference!)}');
        }
        _check();
        _jobs[index] = await repository.finishNormalization(job, 'done');
        finished = true;
        _trace.event('单集已替换', '第 ${_numbers[index]} 集，同名提交成功，修订号=${_jobs[index].revision}');
        _files[index] = work.input;
        _probes[index] = normalized;
        conversionCompleted++;
        completedDuration += input.duration;
        conversionProgress = completedDuration / duration;
        _report(_probeWeight + _normalizeWeight * conversionProgress!);
      } catch (error) {
        _trace.event(_cancelled ? '转换取消' : '转换失败', '第 ${_numbers[index]} 集：$error');
        throw AppFailure('转换异常分集（第 ${_numbers[index]} 集，$mode）：$error'
            '\n输入：${normalizationSummary(input)}\n目标：${normalizationSummary(_reference!)}');
      } finally {
        _callbackEpoch++;
        if (!finished) {
          try {
            await waitForIdle();
            await repository.finishNormalization(job, 'cancel');
            _trace.event('转换回滚', '第 ${_numbers[index]} 集已释放占用，保留原视频');
          } catch (_) {
            _deferred.add(() async { await repository.finishNormalization(job, 'cancel'); });
            _trace.event('延后清理', '第 ${_numbers[index]} 集，退出或提交尚未完成');
          }
        }
      }
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _trace.event('取消请求', '阶段=$phase，已转换 $conversionCompleted/$conversionTotal 集');
    status = '正在取消，等待媒体处理退出';
    _callbackEpoch++;
    _notify();
    unawaited(executor.cancel().catchError((Object _) {}));
  }

  void _check() {
    if (_cancelled || _disposed) throw AppFailure('已取消合并');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _callbackEpoch++;
    _disposed = true;
    super.dispose();
  }
}
