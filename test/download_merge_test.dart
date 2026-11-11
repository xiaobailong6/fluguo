import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/download_merge.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _LocalRepository extends FakeRepository {
  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode, {bool playback = false}) async =>
      PlaybackPlan(url: '/videos/${episode.number}.mp4', local: true);
}

class _Executor implements MediaExecutor {
  final heights = <String, int>{};
  final runs = <List<String>>[];

  @override
  Future<MediaProbe> probe(String file) async => MediaProbe({
    'format': {'duration': '12'},
    'streams': [
      {
        'codec_type': 'video',
        'codec_name': 'h264',
        'height': file.contains('unify-') ? 1080 : heights[file],
      },
      {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '44100'},
    ],
  });

  @override
  Future<void> run(
    List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async => runs.add(arguments);

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

  test('episodes with a different format are unified instead of refused', () async {
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

    // 2、5 集先各自重编码成多数派的 1080，再统一拼接。
    expect(executor.runs, hasLength(3));
    for (final run in executor.runs.take(2)) {
      expect(run, containsAllInOrder(['-c:v', 'libx264']));
      expect(run.any((argument) => argument.startsWith('scale=')), isTrue);
      expect(run.last, endsWith('.mp4'));
    }
    expect(executor.runs.last.take(4), ['-f', 'concat', '-safe', '0']);
  });

  test('unify arguments follow the reference and add silence for a missing track', () {
    final reference = MediaProbe({
      'streams': [
        {'codec_type': 'video', 'codec_name': 'h264', 'width': 1080, 'height': 1920,
          'pix_fmt': 'yuv420p', 'r_frame_rate': '25/1'},
        {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '48000', 'channels': 2},
      ],
    });
    final silent = MediaProbe({
      'streams': [
        {'codec_type': 'video', 'codec_name': 'hevc', 'width': 720, 'height': 1280},
      ],
    });
    final arguments = unifyArguments('in.mp4', 'out.mp4', reference, input: silent);
    expect(arguments, containsAllInOrder(['-i', 'in.mp4']));
    expect(arguments, containsAllInOrder(['-f', 'lavfi', '-i', contains('anullsrc')]));
    expect(arguments, containsAllInOrder(['-map', '1:a:0']));
    expect(arguments, containsAll(['-ar', '48000']));
    expect(arguments, containsAll(['-ac', '2']));
    expect(arguments, containsAll(['-r', '25/1']));
    expect(arguments, contains('scale=1080:1920:force_original_aspect_ratio=decrease'));
    expect(arguments, contains('-shortest'));
  });

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
}
