import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/download_merge.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _LocalRepository extends FakeRepository {
  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => PlaybackPlan(url: '/videos/${episode.number}.mp4', local: true);
}

class _Executor implements MediaExecutor {
  final heights = <String, int>{};
  final runs = <List<String>>[];
  final silent = <String>{};
  final rotations = <String, int>{};
  final overrides = <String, Map<String, dynamic>>{};
  final durations = <String, double>{};
  final outputDurations = <String, double>{};
  final callbacks = <void Function(double)>[];
  Future<void> Function(int, void Function(double)?)? onRun;
  bool invalidOutput = false;

  @override
  Future<MediaProbe> probe(String file) async => MediaProbe({
    'format': {'duration': invalidOutput && !file.startsWith('/videos/') && !file.contains('unify-')
        ? '0' : '${outputDurations[file] ?? durations[file] ?? 12}'},
    'streams': [
      {
        'codec_type': 'video',
        'codec_name': 'h264',
        'width': 1920,
        'height': file.contains('unify-') ? 1080 : heights[file] ?? 1080,
        if (rotations.containsKey(file))
          'side_data_list': [
            {'rotation': rotations[file]},
          ],
        ...?overrides[file],
      },
      if (!silent.contains(file))
        {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '44100'},
    ],
  });

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    runs.add(arguments);
    if (progress != null) callbacks.add(progress);
    await onRun?.call(runs.length - 1, progress);
    final output = arguments.last;
    outputDurations[output] = duration;
  }

  @override
  Future<void> cancel() async {}
}

void main() {
  final show = drama('a', title: '剧甲');

  test('episode numbers collapse into ranges', () {
    expect(episodeRanges([1, 2, 3, 5, 7, 8, 9]), '1-3、5、7-9');
    expect(episodeRanges([4]), '4');
  });

  test('file names keep short ranges and summarize long ones', () {
    expect(mergeFileName('剧/甲', [1, 2, 3, 5]), '剧_甲 第1-3、5集.mp4');
    expect(
      mergeFileName('剧甲', [for (var i = 1; i <= 40; i += 2) i]),
      '剧甲 第1-39集等20集.mp4',
    );
  });

  test(
    'episodes with a different format are unified instead of refused',
    () async {
      final executor = _Executor()
        ..heights.addAll({
          '/videos/1.mp4': 1080,
          '/videos/2.mp4': 720,
          '/videos/3.mp4': 1080,
          '/videos/5.mp4': 720,
        });
      final merge = DownloadMerge(_LocalRepository(), executor: executor);
      addTearDown(merge.dispose);

      await merge.prepare([
        downloadJob(show, 5),
        downloadJob(show, 1),
        downloadJob(show, 2),
        downloadJob(show, 3),
      ]);
      expect(merge.fileName, '剧甲 第1-3、5集.mp4');
      await merge.write('saf:4.mp4');

      // 参数不同时全部统一编码，不能把新编码与旧 profile 直接混拼。
      expect(executor.runs, hasLength(5));
      for (final run in executor.runs.take(4)) {
        expect(run, containsAllInOrder(['-c:v', 'libx264']));
        expect(run.any((argument) => argument.startsWith('scale=')), isTrue);
        expect(run.last, endsWith('.mp4'));
      }
      expect(executor.runs.last.take(4), ['-f', 'concat', '-safe', '0']);
    },
  );

  test(
    'unify arguments follow the reference and add silence for a missing track',
    () {
      final reference = MediaProbe({
        'streams': [
          {
            'codec_type': 'video',
            'codec_name': 'h264',
            'width': 1080,
            'height': 1920,
            'pix_fmt': 'yuv420p',
            'r_frame_rate': '25/1',
          },
          {
            'codec_type': 'audio',
            'codec_name': 'aac',
            'sample_rate': '48000',
            'channels': 2,
          },
        ],
      });
      final silent = MediaProbe({
        'streams': [
          {
            'codec_type': 'video',
            'codec_name': 'hevc',
            'width': 720,
            'height': 1280,
          },
        ],
      });
      final arguments = unifyArguments(
        'in.mp4',
        'out.mp4',
        reference,
        input: silent,
      );
      expect(arguments, containsAllInOrder(['-i', 'in.mp4']));
      expect(
        arguments,
        containsAllInOrder(['-f', 'lavfi', '-i', contains('anullsrc')]),
      );
      expect(arguments, containsAllInOrder(['-map', '1:a:0']));
      expect(arguments, containsAll(['-ar', '48000']));
      expect(arguments, containsAll(['-ac', '2']));
      expect(arguments, contains(contains('fps=25.0')));
      expect(
        arguments,
        contains(
          contains('scale=1080:1920:force_original_aspect_ratio=decrease'),
        ),
      );
      expect(arguments, contains('-shortest'));
    },
  );

  test('selected episodes are concatenated in episode order', () async {
    final executor = _Executor();
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);

    await merge.prepare([downloadJob(show, 3), downloadJob(show, 1)]);
    expect(merge.fileName, '剧甲 第1、3集.mp4');
    await merge.write('saf:1.mp4');

    final arguments = executor.runs.single;
    expect(arguments.take(4), ['-f', 'concat', '-safe', '0']);
    expect(arguments, isNot(contains('+faststart')));
    expect(arguments.last, 'saf:1.mp4');
  });

  test('相同格式只拼接，进度不跳过不存在的转码阶段', () async {
    final executor = _Executor();
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    final values = <double>[];
    merge.addListener(() {
      if (merge.progress != null) values.add(merge.progress!);
    });
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(1));
    expect(values.where((value) => value == .75), isEmpty);
    expect(values.last, 1);
  });

  test('开始前取消不能被 prepare 清掉', () async {
    final merge = DownloadMerge(_LocalRepository(), executor: _Executor())
      ..cancel();
    addTearDown(merge.dispose);
    await expectLater(
      merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]),
      throwsA(isA<AppFailure>()),
    );
  });

  test('混合无声/有声分集保留音轨，旋转参考集使用竖屏画布', () async {
    final executor = _Executor()
      ..silent.addAll(['/videos/1.mp4', '/videos/2.mp4'])
      ..rotations.addAll({'/videos/1.mp4': 90, '/videos/2.mp4': 90});
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([
      downloadJob(show, 1),
      downloadJob(show, 2),
      downloadJob(show, 3),
    ]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(4));
    for (final run in executor.runs.take(3)) {
      expect(run, contains(contains('scale=1080:1920:')));
      expect(run, containsAllInOrder(['-c:a', 'aac']));
      expect(run, containsAllInOrder(['-t', '12.0']));
    }
    expect(executor.runs.first, contains(contains('anullsrc')));
    expect(executor.runs[2], containsAllInOrder(['-map', '0:a:0']));
  });

  test('导出名不使用父目录、设备名和过长路径', () {
    expect(safeFileName('..'), '未命名');
    expect(safeFileName('CON.mp4'), '_CON.mp4');
    expect(safeFileName(' 剧名. '), '剧名');
    expect(safeFileName(List.filled(100, '剧').join()).runes.length, 60);
  });

  test('动态 side data 和平均帧率差异不触发全量转码', () async {
    final executor = _Executor()..overrides.addAll({
      '/videos/1.mp4': {'avg_frame_rate': '25000/1001',
        'side_data_list': [{'side_data_type': 'HDR', 'bit_rate': 111}]},
      '/videos/2.mp4': {'avg_frame_rate': '25/1',
        'side_data_list': [{'side_data_type': 'HDR', 'bit_rate': 222}]},
    });
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(1));
  });

  test('统一后平均帧率量化差异不会拒绝拼接', () async {
    final executor = _Executor()..heights['/videos/2.mp4'] = 720;
    executor.onRun = (index, _) async {
      if (index < 2) {
        executor.overrides[executor.runs.last.last] = {
          'avg_frame_rate': index == 0 ? '250/10' : '2249/90',
          'r_frame_rate': '25/1',
        };
      }
    };
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(3));
    expect(merge.progress, 1);
  });

  test('真正的编码 profile 差异仍触发统一', () async {
    final executor = _Executor()..overrides.addAll({
      '/videos/1.mp4': {'profile': 'High'},
      '/videos/2.mp4': {'profile': 'Main'},
    });
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(3));
  });

  test('进度按累计时长计算且回退和迟到 statistics 无效', () async {
    final executor = _Executor()
      ..heights['/videos/2.mp4'] = 720
      ..durations.addAll({'/videos/1.mp4': 10, '/videos/2.mp4': 90});
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    final values = <double>[];
    merge.addListener(() { if (merge.progress != null) values.add(merge.progress!); });
    executor.onRun = (index, report) async {
      if (index == 1) {
        expect(merge.progress, closeTo(.165, .000001));
        executor.callbacks.first(1);
        expect(merge.progress, closeTo(.165, .000001));
      }
      report?.call(.8);
      report?.call(.1);
      report?.call(double.nan);
      expect(merge.progress, lessThan(1));
    };
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(values, orderedEquals([...values]..sort()));
    expect(merge.progress, 1);
    executor.callbacks.last(0);
    expect(merge.progress, 1);
  });

  test('验证失败不显示100%，取消后回调不能推进', () async {
    final executor = _Executor()..invalidOutput = true;
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>()));
    expect(merge.progress, lessThan(1));
    merge.cancel();
    final before = merge.progress;
    executor.callbacks.single(1);
    expect(merge.progress, before);
  });

  test('未知时长的原音轨不会无限 apad，临时转码不做 faststart', () {
    final probe = MediaProbe({'streams': [
      {'codec_type': 'video', 'codec_name': 'h264'},
      {'codec_type': 'audio', 'codec_name': 'aac'},
    ]});
    final args = unifyArguments('in.mp4', 'out.mp4', probe, input: probe);
    expect(args, isNot(contains('apad')));
    expect(args, isNot(contains('+faststart')));
    expect(args, containsAllInOrder(['-threads', '2']));
  });

  test('转码失败报告阶段和集数，不进入拼接或100%', () async {
    final executor = _Executor()..heights['/videos/2.mp4'] = 720;
    executor.onRun = (_, _) async => throw AppFailure('encoder failure');
    final merge = DownloadMerge(_LocalRepository(), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>().having(
      (error) => error.toString(), 'context', contains('统一格式（第 1 集）'),
    )));
    expect(executor.runs, hasLength(1));
    expect(merge.progress, lessThan(1));
  });
}
