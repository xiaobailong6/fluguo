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
  final name = title
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .trim();
  return name.isEmpty ? '未命名' : name;
}

String mergeFileName(String title, List<int> numbers) {
  final ranges = episodeRanges(numbers);
  final episodes = ranges.length <= 40
      ? '第$ranges集'
      : '第${numbers.first}-${numbers.last}集等${numbers.length}集';
  return '${safeFileName(title)} $episodes.mp4';
}

String _signature(MediaProbe probe) {
  final audio = probe.streams.firstWhere(
    (stream) => stream['codec_type'] == 'audio',
    orElse: () => {},
  );
  return [
    for (final key in const [
      'codec_name',
      'profile',
      'width',
      'height',
      'pix_fmt',
      'sample_aspect_ratio',
    ])
      probe.video[key],
    for (final key in const [
      'codec_name',
      'profile',
      'sample_rate',
      'channels',
    ])
      audio[key],
  ].join('|');
}

String _concatLine(String file) {
  if (file.contains('\n') || file.contains('\r')) {
    throw AppFailure('文件路径不能包含换行');
  }
  return "file '${file.replaceAll("'", "'\\''")}'";
}

/// 把一条分集重编码成参考集的画面与声音参数。
///
/// 只有格式不一致时才用，输出的编码参数和容器与参考集完全一致，拼接仍是
/// `-c copy`，因此只在必要处付一次重编码代价。
List<String> unifyArguments(
  String source,
  String output,
  MediaProbe reference, {
  required MediaProbe input,
}) {
  final video = reference.video;
  final audio = reference.audio;
  final width = video['width'];
  final height = video['height'];
  final rate = audio['sample_rate'];
  final channels = audio['channels'];
  final hasAudio = audio.isNotEmpty;
  final needSilence = hasAudio && input.audio.isEmpty;
  final filters = <String>[
    if (width is int && height is int && width > 0 && height > 0) ...[
      'scale=$width:$height:force_original_aspect_ratio=decrease',
      'pad=$width:$height:(ow-iw)/2:(oh-ih)/2',
    ],
    'setsar=${video['sample_aspect_ratio'] ?? '1'}',
  ];
  return [
    '-i',
    source,
    if (needSilence) ...[
      '-f',
      'lavfi',
      '-i',
      'anullsrc=r=${rate is String ? rate : '44100'}:'
          'cl=${channels == 1 ? 'mono' : 'stereo'}',
    ],
    '-map',
    '0:v:0',
    if (hasAudio) '-map',
    if (hasAudio) needSilence ? '1:a:0' : '0:a:0',
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    '${video['pix_fmt'] ?? 'yuv420p'}',
    '-vf',
    filters.join(','),
    if (video['r_frame_rate'] case final String fps) ...['-r', fps],
    if (hasAudio) ...['-c:a', 'aac', '-b:a', '128k'],
    if (rate is String) ...['-ar', rate],
    if (channels is int) ...['-ac', '$channels'],
    if (needSilence) '-shortest',
    '-movflags',
    '+faststart',
    '-f',
    'mp4',
    output,
  ];
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
  double _duration = 0;
  /// 每个文件下标的探测结果，统一格式时用来判断要不要补静音轨。
  final _probes = <int, MediaProbe>{};
  /// 需要统一格式的文件下标；空表示全部一致，可直接无损拼接。
  final _normalize = <int>{};
  /// 多数派格式，作为统一格式的参考参数。
  MediaProbe? _reference;
  final _numbers = <int>[];
  bool _cancelled = false, _disposed = false;

  bool get cancelled => _cancelled;

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
    final jobs = List<DownloadJob>.of(selected)
      ..sort((a, b) => a.episode.number.compareTo(b.episode.number));
    final numbers = [for (final job in jobs) job.episode.number];
    if (jobs.length < 2) throw AppFailure('至少选择 2 集');
    _numbers.addAll(numbers);
    fileName = mergeFileName(jobs.first.drama.title, numbers);
    final groups = <String, List<int>>{};
    for (final job in jobs) {
      _check();
      final plan = await repository.localPlayback(job.drama, job.episode);
      if (plan == null || !plan.local) {
        throw AppFailure('第 ${job.episode.number} 集没有完整的本地文件');
      }
      final probe = await executor.probe(plan.url);
      final index = _files.length;
      _files.add(plan.url);
      _probes[index] = probe;
      _duration += probe.duration;
      (groups[_signature(probe)] ??= []).add(index);
      progress = _files.length / jobs.length;
      _notify();
    }
    _check();
    if (groups.length < 2) return;
    // 格式不一致时不再拒绝，改为按多数派的参数统一少数集，再无损拼接。
    final ordered = groups.values.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    _reference = _probes[ordered.first.first];
    for (final group in ordered.skip(1)) {
      _normalize.addAll(group);
    }
  }

  Future<void> write(String output, {String? file}) async {
    _check();
    final temporary = await Directory.systemTemp.createTemp('merge');
    try {
      if (_normalize.isNotEmpty) await _unify(temporary);
      _check();
      status = '合并视频';
      progress = 0;
      _notify();
      final list = File(path.join(temporary.path, 'concat.txt'));
      await list.writeAsString(
        'ffconcat version 1.0\n${_files.map(_concatLine).join('\n')}\n',
        flush: true,
      );
      _check();
      await executor.run(
        arguments(list.path, output, faststart: file != null),
        duration: _duration,
        progress: (value) {
          progress = value;
          _notify();
        },
      );
      if (file != null) {
        verifyMediaDuration(await executor.probe(file), _duration);
      }
    } catch (_) {
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

  /// 把格式不一致的分集重编码成参考集的参数，输出仍留在临时目录。
  Future<void> _unify(Directory temporary) async {
    final reference = _reference!;
    final total = _normalize.length;
    var done = 0;
    status = '统一格式';
    progress = 0;
    _notify();
    final ordered = _normalize.toList()..sort();
    for (final index in ordered) {
      _check();
      final input = _probes[index]!;
      final output = path.join(temporary.path, 'unify-$index.mp4');
      await executor.run(
        unifyArguments(_files[index], output, reference, input: input),
        progress: (value) {
          progress = (done + value) / total;
          _notify();
        },
      );
      _check();
      final result = await executor.probe(output);
      if (_signature(result) != _signature(reference)) {
        throw AppFailure(
          '第 ${episodeRanges([_numbers[index]])} 集统一格式后仍和其余集不同，'
          '可能是来源文件损坏，删除后重新下载再来合并。',
        );
      }
      _files[index] = output;
      done++;
      progress = done / total;
      _notify();
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _notify();
    unawaited(executor.cancel());
  }

  void _check() {
    if (_cancelled) throw AppFailure('已取消合并');
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
