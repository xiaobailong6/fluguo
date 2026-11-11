import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'media_pipeline.dart';
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
String _signature(MediaProbe probe) => [
  for (final stream in probe.streams)
    '${stream['codec_type']}:${stream['codec_name']}',
  for (final key in const [
    'codec_name',
    'profile',
    'level',
    'width',
    'height',
    'pix_fmt',
    'sample_aspect_ratio',
    'time_base',
    'field_order',
    'color_range',
    'color_space',
    'color_transfer',
    'color_primaries',
  ])
    probe.video[key],
  // 平均帧率受时长/时间戳量化影响，不是 concat 的编码格式约束。
  for (final key in const [
    'codec_name',
    'profile',
    'sample_fmt',
    'sample_rate',
    'channels',
    'channel_layout',
  ])
    probe.audio[key],
  _rotation(probe.video),
].join('|');

double? _frameRate(Object? value) {
  final parts = '$value'.split('/');
  if (parts.length != 2) return double.tryParse('$value');
  final numerator = double.tryParse(parts[0]);
  final denominator = double.tryParse(parts[1]);
  if (numerator == null || denominator == null || denominator == 0) return null;
  return numerator / denominator;
}

double _rotation(Map<String, dynamic> video) {
  final sides = (video['side_data_list'] as List? ?? []).whereType<Map>();
  final value = sides.where((s) => s['rotation'] != null).firstOrNull?['rotation'] ??
      (video['tags'] as Map?)?['rotate'] ?? 0;
  final degrees = double.tryParse('$value') ?? 0;
  return degrees.isFinite ? (degrees % 360 + 360) % 360 : 0;
}

// FFmpeg 默认应用显示矩阵旋转；参考画布必须使用显示尺寸，而不是原始编码尺寸。
Map<String, dynamic> _displayVideo(MediaProbe probe) {
  final video = Map<String, dynamic>.of(probe.video);
  final width = video['width'], height = video['height'];
  if (width is! int || height is! int || width <= 0 || height <= 0) {
    throw AppFailure('无法读取分集画面尺寸，不能统一格式');
  }
  final sar = _frameRate(
    '${video['sample_aspect_ratio'] ?? '1:1'}'.replaceAll(':', '/'),
  );
  var displayWidth =
      (width * (sar != null && sar.isFinite && sar > 0 ? sar : 1)).round();
  var displayHeight = height;
  final rotation = _rotation(video);
  if ((rotation.abs() % 180 - 90).abs() < 1) {
    final previous = displayWidth;
    displayWidth = displayHeight;
    displayHeight = previous;
  }
  video['width'] = (displayWidth + 1) ~/ 2 * 2;
  video['height'] = (displayHeight + 1) ~/ 2 * 2;
  video['sample_aspect_ratio'] = '1:1';
  return video;
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
  DownloadMerge(this.repository, {MediaExecutor? executor})
    : executor = executor ?? FFmpegExecutor();

  final AppRepository repository;
  final MediaExecutor executor;
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
    _files.clear();
    _probes.clear();
    _numbers.clear();
    _duration = 0;
    _normalize = false;
    _reference = null;

    final jobs = List<DownloadJob>.of(selected)
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final numbers = [for (final job in jobs) job.episode.number];
    if (jobs.length < 2) throw AppFailure('至少选择 2 集');
    _numbers.addAll(numbers);
    fileName = mergeFileName(jobs.first.drama.title, numbers);
    final groups = <String, List<MediaProbe>>{};

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
      final index = _files.length;
      _files.add(plan.url);
      _probes[index] = probe;
      _duration += probe.duration;
      (groups[_signature(probe)] ??= []).add(probe);
      status = '读取分集';
      _report(_probeWeight * _files.length / jobs.length);
    }

    _check();
    _normalize = groups.length > 1;
    if (_normalize) {
      final ordered = groups.values.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      final video = _displayVideo(ordered.first.first);
      final audio = _probes.values.any((probe) => probe.audio.isNotEmpty);
      _reference = MediaProbe({
        'streams': [
          video,
          if (audio) {'codec_type': 'audio', 'codec_name': 'aac'},
        ],
      });
    }
  }

  Future<void> write(String output, {String? file}) async {
    _check();
    final temporary = await Directory.systemTemp.createTemp('merge');
    try {
      if (_normalize) await _unify(temporary);
      _check();
      status = '合并视频';
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
              _report(concatStart + concatWeight * value.clamp(0.0, 1.0));
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
      _report(.99);
      try {
        verifyMediaDuration(await executor.probe(file ?? output), _duration);
      } catch (error) {
        throw AppFailure('验证合并结果（第 ${episodeRanges(_numbers)} 集）：$error');
      }
      _check();
      status = '合并完成';
      progress = 1;
      _notify();
    } catch (_) {
      status = _cancelled ? '正在取消，等待媒体处理退出' : '等待媒体处理退出后清理';
      _notify();
      await waitForIdle();
      if (file != null) {
        try {
          await File(file).delete();
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        await temporary.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _unify(Directory temporary) async {
    status = '统一格式';
    _report(_probeWeight);
    final total = _files.length;
    var completedDuration = 0.0;
    String? signature;
    for (var index = 0; index < total; index++) {
      _check();
      final inputProbe = _probes[index]!;
      final output = path.join(temporary.path, 'unify-$index.mp4');
      status = '统一格式（第 ${_numbers[index]} 集，${index + 1}/$total）';
      final epoch = ++_callbackEpoch;
      final startDuration = completedDuration;
      _report(_probeWeight + _normalizeWeight * startDuration / _duration);
      try {
        await executor.run(
          unifyArguments(_files[index], output, _reference!, input: inputProbe),
          duration: inputProbe.duration,
          progress: (value) {
            if (epoch == _callbackEpoch && value.isFinite) {
              _report(_probeWeight + _normalizeWeight *
                  (startDuration + inputProbe.duration * value.clamp(0.0, 1.0)) /
                  _duration);
            }
          },
        );
      } catch (error) {
        throw AppFailure('统一格式（第 ${_numbers[index]} 集）：$error');
      } finally {
        _callbackEpoch++;
      }
      _check();
      status = '验证格式（第 ${_numbers[index]} 集）';
      _notify();
      final MediaProbe normalized;
      try {
        normalized = await executor.probe(output);
        verifyMediaDuration(normalized, inputProbe.duration);
      } catch (error) {
        throw AppFailure('验证格式（第 ${_numbers[index]} 集）：$error');
      }
      _check();
      signature ??= _signature(normalized);
      if (_signature(normalized) != signature) {
        throw AppFailure(
          '第 ${episodeRanges([_numbers[index]])} 集转码后仍不符合统一格式，'
          '原下载文件已保留；请重试或检查该集源文件。',
        );
      }
      _files[index] = output;
      _probes[index] = normalized;
      completedDuration += inputProbe.duration;
      _report(_probeWeight + _normalizeWeight * completedDuration / _duration);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
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
