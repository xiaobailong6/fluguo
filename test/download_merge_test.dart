import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/download_merge.dart';
import 'package:duanju_app/download_normalization.dart';
import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _LocalRepository extends FakeRepository {
  _LocalRepository(this.executor);

  final _Executor executor;
  final begun = <String>[];
  final finished = <({String id, String result})>[];
  final pending = <String, DownloadConversion>{};
  final saved = <String, DownloadJob>{};

  @override
  Future<List<DownloadJob>> downloads() async => saved.values.toList();

  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => PlaybackPlan(url: '/videos/${episode.number}.mp4', local: true);

  @override
  Future<DownloadConversion> beginNormalization(DownloadJob job) async {
    if (pending.containsKey(job.id)) throw StateError('already normalizing');
    final input = '/videos/${job.episode.number}.mp4';
    final work = (input: input, key: '', output: '$input.normalize.mp4');
    begun.add(job.id);
    pending[job.id] = work;
    saved.putIfAbsent(job.id, () => job);
    return work;
  }

  @override
  Future<DownloadJob> finishNormalization(DownloadJob job, String result) async {
    final work = pending[job.id];
    if (work == null) throw StateError('normalization was not started');
    final current = saved[job.id]!;
    if (result == 'done') {
      // 只有执行器确实生成并经主路径校验的输出才能提交；共享映射模拟同名替换。
      final output = executor.files[work.output];
      if (output == null) throw StateError('normalization output missing');
      executor.files[work.input] = MediaProbe({
        'format': Map<String, dynamic>.from(output.raw['format'] as Map),
        'streams': [for (final stream in output.streams) Map<String, dynamic>.of(stream)],
      });
      saved[job.id] = DownloadJob(
        id: current.id,
        drama: current.drama,
        episode: current.episode,
        state: current.state,
        bytes: current.bytes,
        total: current.total,
        progress: current.progress,
        quality: current.quality,
        actualQuality: current.actualQuality,
        error: current.error,
        created: current.created,
        revision: current.revision + 1,
        archived: current.archived,
      );
    } else if (result != 'cancel') {
      throw StateError('unexpected normalization result: $result');
    }
    executor.files.remove(work.output);
    pending.remove(job.id);
    finished.add((id: job.id, result: result));
    return saved[job.id]!;
  }
}

class _Executor implements MediaExecutor {
  final files = <String, MediaProbe>{};
  final heights = <String, int>{};
  final runs = <List<String>>[];
  final concatFiles = <List<String>>[];
  final silent = <String>{};
  final rotations = <String, int>{};
  final overrides = <String, Map<String, dynamic>>{};
  final audioOverrides = <String, Map<String, dynamic>>{};
  final durations = <String, double>{};
  final callbacks = <void Function(double)>[];
  Future<void> Function(int, void Function(double)?)? onRun;
  bool invalidOutput = false;
  int cancellations = 0;

  @override
  Future<MediaProbe> probe(String file) async {
    final stored = files[file];
    if (stored != null) return stored;
    if (!file.startsWith('/videos/') || file.endsWith('.normalize.mp4')) {
      throw StateError('probe requested for missing output: $file');
    }
    return MediaProbe({
      'format': {'duration': '${durations[file] ?? 12}'},
      'streams': [
        {
          'codec_type': 'video', 'codec_name': 'h264', 'profile': 'High',
          'width': 1920, 'height': heights[file] ?? 1080,
          'pix_fmt': 'yuv420p', 'time_base': '1/90000',
          'sample_aspect_ratio': '1:1', 'r_frame_rate': '25/1',
          if (rotations.containsKey(file))
            'side_data_list': [{'rotation': rotations[file]}],
          ...?overrides[file],
        },
        if (!silent.contains(file))
          {
            'codec_type': 'audio', 'codec_name': 'aac', 'profile': 'LC',
            'sample_rate': '44100', 'channels': 2, 'channel_layout': 'stereo',
            ...?audioOverrides[file],
          },
      ],
    });
  }

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    runs.add(arguments);
    if (progress != null) callbacks.add(progress);
    String? option(String flag) {
      final index = arguments.indexOf(flag);
      return index < 0 ? null : arguments[index + 1];
    }

    final output = arguments.last;
    if (arguments.contains('concat')) {
      final list = await File(option('-i')!).readAsLines();
      final inputs = [
        for (final line in list)
          if (line.startsWith("file '")) line.substring(6, line.length - 1),
      ];
      concatFiles.add(inputs);
      final probes = [for (final input in inputs) await probe(input)];
      if (probes.map(mergeMediaFormat).toSet().length != 1) {
        throw StateError('concat inputs still have different formats');
      }
      files[output] = MediaProbe({
        'format': {'duration': invalidOutput ? '0' : '${probes.fold<double>(0, (sum, probe) => sum + probe.duration)}'},
        'streams': probes.first.streams,
      });
    } else {
      final input = await probe(option('-i')!);
      final video = Map<String, dynamic>.of(input.video);
      final audio = Map<String, dynamic>.of(input.audio);
      // 按命令实际生成输出轨道，不能直接复制目标 probe 让错误参数也通过校验。
      if (option('-c:v') != 'copy') {
        video['codec_name'] = switch (option('-c:v')) {
          'libx264' => 'h264', 'libx265' => 'hevc', final codec => codec,
        };
        final scale = RegExp(r'scale=(\d+):(\d+):').firstMatch(option('-vf')!);
        video['width'] = int.parse(scale!.group(1)!);
        video['height'] = int.parse(scale.group(2)!);
        video['pix_fmt'] = option('-pix_fmt');
        video['sample_aspect_ratio'] = RegExp(r'setsar=([^,]+)')
            .firstMatch(option('-vf')!)!.group(1)!.replaceAll('/', ':');
        video['r_frame_rate'] = option('-r');
        if (option('-profile:v') case final String profile) {
          video['profile'] = switch (profile) {
            'high' => 'High', 'main' => 'Main', 'baseline' => 'Constrained Baseline',
            'high10' => 'High 10', 'main10' => 'Main 10', _ => profile,
          };
        }
      }
      if (option('-video_track_timescale') case final String timescale) {
        video['time_base'] = '1/$timescale';
      }
      video.remove('tags');
      video['side_data_list'] = [
        {'rotation': double.parse(option('-metadata:s:v:0')!.split('=').last)},
      ];
      if (option('-c:a') != null && option('-c:a') != 'copy') {
        audio.addAll({
          'codec_type': 'audio',
          'codec_name': option('-c:a') == 'libmp3lame' ? 'mp3' : option('-c:a'),
          'sample_rate': option('-ar'), 'channels': int.parse(option('-ac')!),
          'channel_layout': option('-ac') == '1' ? 'mono' : 'stereo',
          'profile': switch (option('-profile:a')) {
            'aac_he' => 'HE-AAC', 'aac_he_v2' => 'HE-AACv2', _ => 'LC',
          },
        });
      }
      files[output] = MediaProbe({
        'format': {'duration': '${double.parse(option('-t') ?? '$duration')}'},
        'streams': [video, if (option('-c:a') != null) audio],
      });
    }
    await onRun?.call(runs.length - 1, progress);
  }

  @override
  Future<void> cancel() async { cancellations++; }
}

void main() {
  final show = drama('a', title: '剧甲');
  setUp(() async { DiaryService.traceEnabled = false; await DiaryService.clear(); });

  test('数字profile和名称按编码归一，不能跨编码误判', () {
    for (final value in [1, '1', 1.0, 'LC', 'lc']) {
      expect(normalizationProfile({'codec_name': 'aac', 'profile': value}), 'LC');
    }
    expect(normalizationProfile({'codec_name': 'aac', 'profile': 28}), 'HE-AACv2');
    expect(normalizationProfile({'codec_name': 'aac', 'profile': 4}), 'HE-AAC');
    expect(normalizationProfile({'codec_name': 'hevc', 'profile': 1}), 'Main');
    expect(normalizationProfile({'codec_name': 'hevc', 'profile': '2'}), 'Main 10');
    expect(normalizationProfile({'codec_name': 'h264', 'profile': 100}), 'High');
    expect(normalizationProfile({'codec_name': 'aac', 'profile': 999}), '999');
    expect(normalizationProfile({'codec_name': 'hevc', 'profile': 28}), '28');
    expect(normalizationProfile({'codec_name': 'aac', 'profile': null}), '');
  });

  test('日志复现：50集HEVC数字profile仅第34集异常可转换为Main和LC并复用', () async {
    final executor = _Executor();
    for (var number = 1; number <= 50; number++) {
      executor.overrides['/videos/$number.mp4'] = {
        'codec_name': 'hevc', 'profile': number.isEven ? 1 : '1',
        'width': number == 34 ? 720 : 1080,
        'height': number == 34 ? 1280 : 1920,
        'time_base': '1/15360', 'r_frame_rate': '30/1', 'avg_frame_rate': '30/1',
      };
      executor.audioOverrides['/videos/$number.mp4'] = {
        'profile': number == 34 ? 28 : 1,
        'time_base': '1/44100',
      };
    }
    final repository = _LocalRepository(executor);
    final jobs = [for (var i = 1; i <= 50; i++) downloadJob(show, i)];
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare(jobs);
    expect(merge.conversionTotal, 1);
    await merge.write('numeric-profiles.mp4');
    expect(repository.begun, ['a:34']);
    expect(executor.runs, hasLength(2));
    final conversion = executor.runs.first;
    expect(conversion, containsAllInOrder(['-c:v', 'libx265']));
    expect(conversion, containsAllInOrder(['-profile:v', 'main']));
    expect(conversion, containsAllInOrder(['-c:a', 'aac']));
    expect(conversion, containsAllInOrder(['-profile:a', 'aac_low']));
    final saved = await executor.probe('/videos/34.mp4');
    final target = await executor.probe('/videos/1.mp4');
    expect(saved.video['profile'], 'Main');
    expect(saved.audio['profile'], 'LC');
    expect(mergeMediaFormat(saved), mergeMediaFormat(target));
    expect(normalizationMismatch(saved, target), isEmpty);
    expect(normalizationSummary(target), contains('Main（原值=1）'));
    expect(normalizationSummary(target), contains('LC（原值=1）'));
    final repeated = DownloadMerge(repository, executor: executor);
    addTearDown(repeated.dispose);
    await repeated.prepare(jobs);
    expect(repeated.needsConversion, isFalse);
    await repeated.write('repeated-numeric.mp4');
    expect(executor.runs, hasLength(3));
    expect(repository.begun, ['a:34']);
  });

  test('同规格数字和名称profile不触发转换', () async {
    final executor = _Executor()
      ..overrides['/videos/1.mp4'] = {'profile': 100}
      ..audioOverrides['/videos/1.mp4'] = {'profile': '1'};
    final merge = DownloadMerge(_LocalRepository(executor), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    expect(merge.needsConversion, isFalse);
    await merge.write('same-profile.mp4');
    expect(executor.runs, hasLength(1));
  });
  tearDown(() { DiaryService.traceEnabled = false; });

  test('转换合并详细过程只在调试开关开启时进入日记', () async {
    for (final enabled in [false, true]) {
      DiaryService.traceEnabled = enabled;
      await DiaryService.clear();
      final executor = _Executor()..heights['/videos/3.mp4'] = 720;
      final repository = _LocalRepository(executor);
      final merge = DownloadMerge(repository, executor: executor);
      addTearDown(merge.dispose);
      await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
      await merge.write('out.mp4');
      if (enabled) {
        for (final step in ['格式检查', '检查完成', '分集转换', '单集已替换', '拼接开始', '拼接完成']) {
          expect(DiaryService.fullText, contains(step));
        }
        expect(DiaryService.fullText, isNot(contains('/videos/')));
      } else {
        expect(DiaryService.entries, isEmpty);
      }
    }
  });

  test('episode numbers collapse into ranges', () {
    expect(episodeRanges([1, 2, 3, 5, 7, 8, 9]), '1-3、5、7-9');
    expect(episodeRanges([4]), '4');
  });

  test('file names keep short ranges and summarize long ones', () {
    expect(mergeFileName('剧/甲', [1, 2, 3, 5]), '剧_甲 第1-3、5集.mp4');
    expect(mergeFileName('剧甲', [for (var i = 1; i <= 40; i += 2) i]),
        '剧甲 第1-39集等20集.mp4');
  });

  test('只转换多数格式组外分集并按集序拼接原路径', () async {
    final executor = _Executor()..heights['/videos/5.mp4'] = 720;
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (final number in [5, 1, 2, 3]) downloadJob(show, number)]);
    expect(merge.fileName, '剧甲 第1-3、5集.mp4');
    expect(merge.conversionTotal, 1);
    expect(merge.needsConversion, isTrue);
    expect(merge.conversionProgress, 0);
    executor.onRun = (index, report) async {
      if (index == 0) {
        expect(merge.phase, 'converting');
        expect(merge.conversionCompleted, 0);
        report!(.5);
        expect(merge.conversionProgress, .5);
        expect(merge.progress, closeTo(.425, .000001));
      } else {
        expect(merge.phase, 'merging');
        expect(merge.conversionCompleted, 1);
        expect(merge.conversionProgress, 1);
        report!(.5);
        expect(merge.mergeProgress, .5);
        expect(merge.progress, closeTo(.875, .000001));
      }
    };
    await merge.write('saf:4.mp4');
    expect(executor.runs, hasLength(2));
    expect(executor.runs.first, containsAllInOrder(['-i', '/videos/5.mp4']));
    expect(executor.runs.first, containsAllInOrder(['-c:v', 'libx264']));
    expect(executor.runs.first, containsAllInOrder(['-c:a', 'copy']));
    expect(executor.runs.first.last, '/videos/5.mp4.normalize.mp4');
    expect(repository.finished, [(id: 'a:5', result: 'done')]);
    expect((await executor.probe('/videos/5.mp4')).video['height'], 1080);
    expect(executor.concatFiles.single,
        ['/videos/1.mp4', '/videos/2.mp4', '/videos/3.mp4', '/videos/5.mp4']);
    expect(executor.runs.last.take(4), ['-f', 'concat', '-safe', '0']);
    expect(executor.runs.last, isNot(contains('+faststart')));
  });

  test('90集一致加2异常只转2次，提交后再次合并及单集读取均可复用', () async {
    final executor = _Executor()
      ..heights.addAll({'/videos/91.mp4': 720, '/videos/92.mp4': 480});
    final repository = _LocalRepository(executor);
    final selected = [for (var i = 1; i <= 92; i++) downloadJob(show, i)];
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare(selected.reversed.toList());
    expect(merge.needsConversion, isTrue);
    expect(merge.conversionTotal, 2);
    await merge.write('first.mp4');
    expect(executor.runs, hasLength(3));
    expect(repository.begun, ['a:91', 'a:92']);
    expect(repository.finished, [
      (id: 'a:91', result: 'done'), (id: 'a:92', result: 'done'),
    ]);
    expect(executor.concatFiles.single,
        [for (var i = 1; i <= 92; i++) '/videos/$i.mp4']);
    final target = await executor.probe('/videos/1.mp4');
    for (final number in [91, 92]) {
      final plan = await repository.localPlayback(show, selected[number - 1].episode);
      expect(plan!.url, '/videos/$number.mp4');
      expect(plan.local, isTrue);
      expect(mergeMediaFormat(await executor.probe(plan.url)), mergeMediaFormat(target));
      expect(repository.saved['a:$number']!.revision, 1);
      expect(repository.saved['a:$number']!.completed, isTrue);
    }
    expect(repository.pending, isEmpty);
    expect(executor.files.keys.where((file) => file.endsWith('.normalize.mp4')), isEmpty);
    final again = DownloadMerge(repository, executor: executor);
    addTearDown(again.dispose);
    await again.prepare(selected);
    expect(again.needsConversion, isFalse);
    expect(again.conversionTotal, 0);
    await again.write('second.mp4');
    expect(executor.runs, hasLength(4));
    expect(repository.begun, hasLength(2));
    expect(executor.runs.last, contains('concat'));
    expect(again.progress, 1);
  });

  test('相同格式只拼接，一步字段及进度不出现转换阶段', () async {
    final executor = _Executor();
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    final values = <double>[];
    final phases = <String>[];
    merge.addListener(() {
      if (merge.progress != null) values.add(merge.progress!);
      phases.add(merge.phase);
    });
    await merge.prepare([downloadJob(show, 3), downloadJob(show, 1)]);
    expect(merge.fileName, '剧甲 第1、3集.mp4');
    expect(merge.phase, 'checking');
    expect(merge.needsConversion, isFalse);
    expect(merge.conversionTotal, 0);
    expect(merge.conversionCompleted, 0);
    expect(merge.conversionProgress, isNull);
    expect(merge.mergeProgress, 0);
    executor.onRun = (_, report) async {
      expect(merge.phase, 'merging');
      report!(.5);
      expect(merge.mergeProgress, .5);
      expect(merge.progress, closeTo(.55, .000001));
    };
    await merge.write('saf:1.mp4');
    expect(executor.runs, hasLength(1));
    expect(repository.begun, isEmpty);
    expect(phases, isNot(contains('converting')));
    expect(values.where((value) => value == .75), isEmpty);
    expect(merge.mergeProgress, .99);
    expect(values.last, 1);
  });

  test('开始前取消不能被 prepare 清掉', () async {
    final executor = _Executor();
    final merge = DownloadMerge(_LocalRepository(executor), executor: executor)..cancel();
    addTearDown(merge.dispose);
    await expectLater(merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]),
        throwsA(isA<AppFailure>()));
    expect(executor.runs, isEmpty);
  });

  test('有声组优先且保留参考旋转，只转换两集无声异常', () async {
    final executor = _Executor()
      ..silent.addAll(['/videos/1.mp4', '/videos/2.mp4'])
      ..rotations['/videos/3.mp4'] = 90;
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    expect(merge.conversionTotal, 2);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(3));
    for (final run in executor.runs.take(2)) {
      expect(run, contains('-noautorotate'));
      expect(run, contains(contains('scale=1920:1080:')));
      expect(run, containsAllInOrder(['-metadata:s:v:0', 'rotate=90.0']));
      expect(run, containsAllInOrder(['-c:a', 'aac']));
      expect(run, containsAllInOrder(['-map', '1:a:0']));
      expect(run, contains(contains('anullsrc')));
      expect(run, containsAllInOrder(['-t', '12.0']));
    }
    expect(repository.begun, ['a:1', 'a:2']);
    expect(mediaRotation(await executor.probe('/videos/1.mp4')), 90);
    expect((await executor.probe('/videos/1.mp4')).audio, isNotEmpty);
  });

  test('只有音频不同复制视频，只有视频不同复制音频', () async {
    for (final audioOnly in [true, false]) {
      final executor = _Executor();
      if (audioOnly) {
        executor.audioOverrides['/videos/3.mp4'] = {'sample_rate': '48000'};
      } else {
        executor.heights['/videos/3.mp4'] = 720;
      }
      final repository = _LocalRepository(executor);
      final merge = DownloadMerge(repository, executor: executor);
      addTearDown(merge.dispose);
      await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
      await merge.write('out.mp4');
      expect(executor.runs, hasLength(2));
      final run = executor.runs.first;
      expect(run, containsAllInOrder(['-c:v', audioOnly ? 'copy' : 'libx264']));
      expect(run, containsAllInOrder(['-c:a', audioOnly ? 'aac' : 'copy']));
      if (audioOnly) {
        expect(run, isNot(contains('-vf')));
        expect(run, containsAllInOrder(['-ar', '44100']));
      } else {
        expect(run, isNot(contains('-af')));
      }
      expect(repository.finished.single, (id: 'a:3', result: 'done'));
    }
  });

  test('只有视频时间基不同时仅换封装，不重编码10MB或50MB分集', () async {
    final executor = _Executor()..overrides['/videos/3.mp4'] = {'time_base': '1/12800'};
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await merge.normalize();
    final run = executor.runs.single;
    expect(run, containsAllInOrder(['-c:v', 'copy']));
    expect(run, containsAllInOrder(['-c:a', 'copy']));
    expect(run, containsAllInOrder(['-video_track_timescale', '90000']));
    expect(run, isNot(contains('-vf')));
    expect(repository.finished.single.result, 'done');
    expect(mergeVideoFormat(await executor.probe('/videos/3.mp4')),
        mergeVideoFormat(await executor.probe('/videos/1.mp4')));
  });

  test('异常r_frame_rate不强制生成巨量重复帧', () {
    final reference = MediaProbe({'streams': [
      {'codec_type': 'video', 'codec_name': 'h264', 'profile': 'High',
        'width': 1920, 'height': 1080, 'pix_fmt': 'yuv420p', 'time_base': '1/90000',
        'r_frame_rate': '90000/1', 'avg_frame_rate': '30000/1001'},
    ]});
    final input = MediaProbe({'streams': [
      {...reference.video, 'width': 1280, 'height': 720},
    ]});
    final args = normalizationArguments('in.mp4', 'out.mp4', reference, input: input);
    expect(args, containsAllInOrder(['-r', '30000/1001']));
    expect(args, isNot(contains('90000/1')));
    final unknown = MediaProbe({'streams': [
      {...reference.video, 'avg_frame_rate': '0/0'},
    ]});
    final preserved = normalizationArguments('in.mp4', 'out.mp4', unknown, input: input);
    expect(preserved, isNot(contains('-r')));
    expect(preserved, containsAllInOrder(['-fps_mode', 'passthrough']));
  });

  test('不支持的HE-AAC目标在开始转换前失败，不能先转视频再报错', () async {
    final executor = _Executor()
      ..audioOverrides['/videos/1.mp4'] = {'profile': 'HE-AAC'}
      ..audioOverrides['/videos/2.mp4'] = {'profile': 'HE-AAC'};
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await expectLater(merge.normalize(), throwsA(isA<AppFailure>().having(
        (error) => error.toString(), 'reason', contains('HE-AAC'))));
    expect(repository.begun, isEmpty);
    expect(executor.runs, isEmpty);
  });

  test('未知AAC目标配置预检失败且包含集号和输入目标', () async {
    final executor = _Executor()
      ..audioOverrides['/videos/1.mp4'] = {'profile': 'unknown'}
      ..audioOverrides['/videos/2.mp4'] = {'profile': 'unknown'};
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await expectLater(merge.normalize(), throwsA(isA<AppFailure>().having(
      (error) => error.toString(), 'detail', allOf(
        contains('转换预检（第 3 集'), contains('输入：'), contains('目标：')))));
    expect(repository.begun, isEmpty);
    expect(executor.runs, isEmpty);
  });

  test('导出名不使用父目录、设备名和过长路径', () {
    expect(safeFileName('..'), '未命名');
    expect(safeFileName('CON.mp4'), '_CON.mp4');
    expect(safeFileName(' 剧名. '), '剧名');
    expect(safeFileName(List.filled(100, '剧').join()).runes.length, 60);
  });

  test('动态 side data 和平均帧率差异不触发转换', () async {
    final executor = _Executor()..overrides.addAll({
      '/videos/1.mp4': {'avg_frame_rate': '25000/1001',
        'side_data_list': [{'side_data_type': 'HDR', 'bit_rate': 111}]},
      '/videos/2.mp4': {'avg_frame_rate': '25/1',
        'side_data_list': [{'side_data_type': 'HDR', 'bit_rate': 222}]},
    });
    final merge = DownloadMerge(_LocalRepository(executor), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(1));
  });

  test('转换后平均帧率量化差异不会拒绝拼接', () async {
    final executor = _Executor()..heights['/videos/3.mp4'] = 720;
    executor.onRun = (index, _) async {
      if (index == 0) {
        final file = executor.runs.last.last;
        final output = executor.files[file]!;
        executor.files[file] = MediaProbe({
          'format': output.raw['format'],
          'streams': [{...output.video, 'avg_frame_rate': '2249/90'}, output.audio],
        });
      }
    };
    final merge = DownloadMerge(_LocalRepository(executor), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(2));
    expect(merge.progress, 1);
  });

  test('profile不同只转换少数集且编码目标跟随多数High', () async {
    final executor = _Executor()..overrides['/videos/3.mp4'] = {'profile': 'Main'};
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    expect(merge.conversionTotal, 1);
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(2));
    expect(executor.runs.first, containsAllInOrder(['-profile:v', 'high']));
    expect(executor.runs.first, containsAllInOrder(['-c:a', 'copy']));
    expect(repository.begun, ['a:3']);
    expect((await executor.probe('/videos/3.mp4')).video['profile'], 'High');
  });

  test('两步转换按异常集时长加权，回退和迟到回调不推进总进度', () async {
    final executor = _Executor()
      ..heights.addAll({'/videos/4.mp4': 720, '/videos/5.mp4': 720})
      ..durations.addAll({'/videos/4.mp4': 10, '/videos/5.mp4': 90});
    final repository = _LocalRepository(executor);
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    final values = <double>[];
    merge.addListener(() { if (merge.progress != null) values.add(merge.progress!); });
    await merge.prepare([for (var i = 1; i <= 5; i++) downloadJob(show, i)]);
    expect(merge.phase, 'checking');
    expect(merge.conversionTotal, 2);
    expect(merge.conversionCompleted, 0);
    expect(merge.conversionProgress, 0);
    expect(merge.mergeProgress, 0);
    executor.onRun = (index, report) async {
      expect(merge.phase, 'converting');
      expect(merge.conversionCompleted, index);
      expect(merge.mergeProgress, 0);
      if (index == 1) {
        expect(merge.progress, closeTo(.165, .000001));
        expect(merge.conversionProgress, closeTo(.1, .000001));
        executor.callbacks.first(1);
        expect(merge.progress, closeTo(.165, .000001));
        expect(merge.conversionProgress, closeTo(.1, .000001));
      }
      report!(.5);
      final fraction = index == 0 ? .05 : .55;
      expect(merge.conversionProgress, closeTo(fraction, .000001));
      expect(merge.progress, closeTo(.1 + .65 * fraction, .000001));
      report(.1);
      report(double.nan);
      expect(merge.progress, closeTo(.1 + .65 * fraction, .000001));
    };
    await merge.normalize();
    expect(executor.runs, hasLength(2));
    expect(merge.conversionCompleted, 2);
    expect(merge.conversionProgress, 1);
    expect(merge.progress, closeTo(.75, .000001));
    expect(repository.finished.every((call) => call.result == 'done'), isTrue);
    executor.onRun = (index, report) async {
      expect(index, 2);
      expect(merge.phase, 'merging');
      executor.callbacks.first(1);
      expect(merge.progress, closeTo(.75, .000001));
      report!(.5);
      expect(merge.mergeProgress, .5);
      expect(merge.progress, closeTo(.875, .000001));
    };
    await merge.write('out.mp4');
    expect(executor.runs, hasLength(3));
    expect(values, orderedEquals([...values]..sort()));
    expect(merge.progress, 1);
    executor.callbacks.last(0);
    expect(merge.progress, 1);
  });

  test('转换输出格式不匹配保留原集，不提交done、不拼接', () async {
    final executor = _Executor()..heights['/videos/3.mp4'] = 720;
    final repository = _LocalRepository(executor);
    final original = await executor.probe('/videos/3.mp4');
    executor.onRun = (_, _) async {
      final file = executor.runs.last.last;
      final output = executor.files[file]!;
      executor.files[file] = MediaProbe({
        'format': output.raw['format'],
        'streams': [{...output.video, 'profile': 'Main'}, output.audio],
      });
    };
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>().having(
      (error) => error.toString(), 'context', contains('转换后未匹配目标音视频格式'),
    )));
    expect(repository.finished, [(id: 'a:3', result: 'cancel')]);
    expect((await executor.probe('/videos/3.mp4')).raw, original.raw);
    expect(repository.saved['a:3']!.revision, 0);
    expect(repository.pending, isEmpty);
    expect(executor.files, isEmpty);
    expect(executor.runs, hasLength(1));
    expect(merge.conversionCompleted, 0);
    expect(merge.progress, lessThan(1));
  });

  test('转换中取消保留已提交单集，未提交集cancel且原格式不变', () async {
    final executor = _Executor()
      ..heights.addAll({'/videos/4.mp4': 720, '/videos/5.mp4': 480});
    final repository = _LocalRepository(executor);
    final original = await executor.probe('/videos/5.mp4');
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    executor.onRun = (index, report) async {
      report!(.5);
      if (index == 1) merge.cancel();
    };
    await merge.prepare([for (var i = 1; i <= 5; i++) downloadJob(show, i)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>()));
    expect(repository.finished, [
      (id: 'a:4', result: 'done'), (id: 'a:5', result: 'cancel'),
    ]);
    expect((await executor.probe('/videos/4.mp4')).video['height'], 1080);
    expect((await executor.probe('/videos/5.mp4')).raw, original.raw);
    expect(repository.saved['a:4']!.revision, 1);
    expect(repository.saved['a:5']!.revision, 0);
    expect(repository.pending, isEmpty);
    expect(executor.files.keys.where((file) => file.endsWith('.normalize.mp4')), isEmpty);
    expect(executor.runs, hasLength(2));
    expect(executor.concatFiles, isEmpty);
    expect(executor.cancellations, 1);
    expect(merge.conversionCompleted, 1);
    expect(merge.cancelled, isTrue);
    final before = merge.progress;
    for (final callback in executor.callbacks) { callback(1); }
    expect(merge.progress, before);
    final retry = DownloadMerge(repository, executor: executor);
    addTearDown(retry.dispose);
    executor.onRun = null;
    await retry.prepare([for (var i = 1; i <= 5; i++) downloadJob(show, i)]);
    expect(retry.conversionTotal, 1);
    await retry.write('retry.mp4');
    expect(repository.begun, ['a:4', 'a:5', 'a:5']);
    expect(retry.progress, 1);
  });

  test('验证失败不显示100%，取消后回调不能推进', () async {
    final executor = _Executor()..invalidOutput = true;
    final merge = DownloadMerge(_LocalRepository(executor), executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([downloadJob(show, 1), downloadJob(show, 2)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>()));
    expect(merge.progress, lessThan(1));
    merge.cancel();
    final before = merge.progress;
    executor.callbacks.single(1);
    expect(merge.progress, before);
  });

  test('转码失败报告阶段和异常集数，不进入拼接或100%', () async {
    final executor = _Executor()..heights['/videos/3.mp4'] = 720;
    final repository = _LocalRepository(executor);
    executor.onRun = (_, _) async => throw AppFailure('encoder failure');
    final merge = DownloadMerge(repository, executor: executor);
    addTearDown(merge.dispose);
    await merge.prepare([for (var i = 1; i <= 3; i++) downloadJob(show, i)]);
    await expectLater(merge.write('out.mp4'), throwsA(isA<AppFailure>().having(
      (error) => error.toString(), 'context', contains('转换异常分集（第 3 集，'),
    )));
    expect(repository.finished, [(id: 'a:3', result: 'cancel')]);
    expect(executor.runs, hasLength(1));
    expect(executor.files, isEmpty);
    expect(merge.progress, lessThan(1));
  });

  // 旧纯函数仍保持独立覆盖，主路径的断言使用 normalizationArguments。
  test('unify arguments follow reference and add silence for a missing track', () {
    final reference = MediaProbe({'streams': [
      {'codec_type': 'video', 'codec_name': 'h264', 'width': 1080,
        'height': 1920, 'pix_fmt': 'yuv420p', 'r_frame_rate': '25/1'},
      {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '48000', 'channels': 2},
    ]});
    final silent = MediaProbe({'streams': [
      {'codec_type': 'video', 'codec_name': 'hevc', 'width': 720, 'height': 1280},
    ]});
    final arguments = unifyArguments('in.mp4', 'out.mp4', reference, input: silent);
    expect(arguments, containsAllInOrder(['-i', 'in.mp4']));
    expect(arguments, containsAllInOrder(['-f', 'lavfi', '-i', contains('anullsrc')]));
    expect(arguments, containsAllInOrder(['-map', '1:a:0']));
    expect(arguments, containsAll(['-ar', '48000', '-ac', '2']));
    expect(arguments, contains(contains('fps=25.0')));
    expect(arguments, contains(contains('scale=1080:1920:force_original_aspect_ratio=decrease')));
    expect(arguments, contains('-shortest'));
  });

  test('未知时长的原音轨不会无限apad，旧临时转码不做faststart', () {
    final probe = MediaProbe({'streams': [
      {'codec_type': 'video', 'codec_name': 'h264'},
      {'codec_type': 'audio', 'codec_name': 'aac'},
    ]});
    final args = unifyArguments('in.mp4', 'out.mp4', probe, input: probe);
    expect(args, isNot(contains('apad')));
    expect(args, isNot(contains('+faststart')));
    expect(args, containsAllInOrder(['-threads', '2']));
  });
}
