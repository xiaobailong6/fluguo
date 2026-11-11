import 'dart:async';
import 'dart:io';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final leases = <String>[];
  @override
  Future<int> workLease(String id, String command) async {
    leases.add(command);
    return 0;
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode, {bool playback = false}) async =>
      PlaybackPlan(url: '/local/${episode.number}.mp4', local: true);
}

class _Executor implements MediaExecutor {
  Completer<void>? gate;
  final started = Completer<void>();
  final runs = <List<String>>[];
  bool cancelled = false;
  String outputDuration = '24';

  @override
  Future<MediaProbe> probe(String file) async => MediaProbe({
    'format': {'duration': file.contains('writing.mp4') ? outputDuration : '12'},
    'streams': [
      {'codec_type': 'video', 'codec_name': 'h264', 'height': 1080},
      {'codec_type': 'audio', 'codec_name': 'aac', 'sample_rate': '44100'},
    ],
  });

  @override
  Future<void> run(List<String> arguments, {
    double duration = 0,
    void Function(double)? progress,
  }) async {
    runs.add(arguments);
    started.complete();
    await gate?.future;
    // 故意忽略取消并产出文件，验证库的提交检查而不是依赖执行器善后。
    await File(arguments.last).writeAsBytes([1, 2, 3, 4]);
    progress?.call(1);
  }

  @override
  Future<void> cancel() async { cancelled = true; }
}

class _ExportGateLibrary extends MergedLibrary {
  _ExportGateLibrary({required Directory directory}) : super(directory: directory);
  final exporting = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<String> fileFor(MergedVideo video) async {
    if (!exporting.isCompleted) exporting.complete();
    await resume.future;
    return super.fileFor(video);
  }
}

void main() {
  late Directory temporary;
  late MergedLibrary library;
  late _Repository repository;
  final show = drama('queue', title: '队列剧');
  List<DownloadJob> jobs() => [downloadJob(show, 1), downloadJob(show, 2)];

  Future<void> settle(MergeQueue queue) async {
    for (var i = 0; i < 2000; i++) {
      if (queue.tasks.every((task) => task.finished)) {
        await Future<void>.delayed(Duration.zero);
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    fail('合并队列没有结束');
  }

  MergeQueue queue({required _Executor executor, MergeSave? save, LocalStore? store}) {
    final result = MergeQueue(repository,
      executor: () => executor, library: library, save: save, store: store,
    );
    addTearDown(result.dispose);
    return result;
  }

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('merge-queue-library-test-');
    addTearDown(() => temporary.delete(recursive: true));
    library = MergedLibrary(directory: Directory(path.join(temporary.path, 'library')));
    addTearDown(library.dispose);
    repository = _Repository();
  });

  test('default queue commits a managed MP4 before making an independent export', () async {
    final executor = _Executor();
    final merges = queue(executor: executor);
    final exported = File(path.join(temporary.path, 'export.mp4'));
    var finished = 0;
    merges.onFinished = (_) => finished++;
    merges.add(jobs(), file: exported.path);
    await settle(merges);

    final task = merges.tasks.single;
    expect(task.state, MergeState.done);
    expect(task.outputId, library.videos.single.id);
    expect(task.message, contains('已导出'));
    expect(finished, 1);
    expect(exported.readAsBytesSync(), [1, 2, 3, 4]);
    expect(executor.runs.single, contains('+faststart'));
    final managed = File(await library.fileFor(library.videos.single));
    expect(managed.path, isNot(exported.path));
    expect(repository.controls, isEmpty);
    expect(await library.remove({task.outputId!}), isEmpty);
    expect(exported.existsSync(), isTrue);
    expect(repository.leases, ['start', 'end']);
  });

  test('merge without a destination only commits internally and never exports', () async {
    final merges = queue(executor: _Executor());
    merges.add(jobs());
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    expect(merges.tasks.single.message, '已保存到合并成品库');
    expect(merges.tasks.single.outputId, library.videos.single.id);
    expect(Directory(temporary.path).listSync().whereType<File>(), isEmpty);
  });

  test('desktop without destination still succeeds and survives restart', () async {
    final merges = queue(executor: _Executor());
    merges.add(jobs());
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    final restarted = MergedLibrary(directory: Directory(path.join(temporary.path, 'library')));
    addTearDown(restarted.dispose);
    await restarted.ensureInitialized();
    expect(restarted.videos.single.id, merges.tasks.single.outputId);
    expect(File(await restarted.fileFor(restarted.videos.single)).existsSync(), isTrue);
  });

  test('export failure cannot fail or remove an already committed internal product', () async {
    final merges = queue(executor: _Executor());
    final existing = File(path.join(temporary.path, 'existing.mp4'))..writeAsStringSync('do not overwrite');
    merges.add(jobs(), file: existing.path);
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    expect(merges.tasks.single.message, contains('外部导出失败'));
    expect(existing.readAsStringSync(), 'do not overwrite');
    expect(File(await library.fileFor(library.videos.single)).existsSync(), isTrue);
  });

  test('duration verification failure never commits an incomplete managed MP4', () async {
    final executor = _Executor()..outputDuration = '1';
    final merges = queue(executor: executor);
    merges.add(jobs());
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.failed);
    expect(merges.tasks.single.outputId, isNull);
    expect(library.videos, isEmpty);
    expect(repository.controls, isEmpty);
    expect(Directory(path.join(temporary.path, 'library', 'media')).listSync(), isEmpty);
  });

  test('input validation filters incomplete jobs, sorts and deduplicates, rejects active duplicates', () async {
    final executor = _Executor()..gate = Completer<void>();
    final merges = queue(executor: executor);
    merges.add([
      downloadJob(show, 2), downloadJob(show, 1), downloadJob(show, 2),
      downloadJob(show, 3, state: 'failed'),
      downloadJob(drama('other'), 4, state: 'downloading'),
    ]);
    expect(merges.tasks.single.jobs.map((job) => job.episode.number), [1, 2]);
    expect(() => merges.add(jobs()), throwsA(isA<AppFailure>()));
    await executor.started.future;
    expect(() => merges.add(jobs().reversed.toList()), throwsA(isA<AppFailure>()));
    expect(() => merges.add([downloadJob(show, 1), downloadJob(show, 1)]), throwsA(isA<AppFailure>()));
    expect(() => merges.add([downloadJob(show, 1), downloadJob(show, 2, state: 'paused')]), throwsA(isA<AppFailure>()));
    expect(() => merges.add([downloadJob(show, 1), downloadJob(drama('other'), 2)]), throwsA(isA<AppFailure>()));
    executor.gate!.complete();
    await settle(merges);
  });

  test('source revoked during write cancels before commit and keeps the library healthy', () async {
    final store = await openStore();
    final executor = _Executor()..gate = Completer<void>();
    final merges = queue(executor: executor, store: store);
    final exported = File(path.join(temporary.path, 'revoked.mp4'));
    merges.add(jobs(), file: exported.path);
    await executor.started.future;
    await store.setSourceEnabled(show.source, false);
    executor.gate!.complete();
    await settle(merges);
    expect(executor.cancelled, isTrue);
    expect(merges.tasks.single.state, MergeState.cancelled);
    expect(library.videos, isEmpty);
    expect(library.error, isNull);
    expect(exported.existsSync(), isFalse);
  });

  test('source revoked after commit preserves internal video but skips export', () async {
    final store = await openStore();
    final gated = _ExportGateLibrary(
      directory: Directory(path.join(temporary.path, 'gated-library')),
    );
    addTearDown(gated.dispose);
    final merges = MergeQueue(repository, executor: _Executor.new, library: gated, store: store);
    addTearDown(merges.dispose);
    final exported = File(path.join(temporary.path, 'not-authorized.mp4'));
    merges.add(jobs(), file: exported.path);
    await gated.exporting.future;
    await store.setSourceEnabled(show.source, false);
    gated.resume.complete();
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    expect(merges.tasks.single.outputId, gated.videos.single.id);
    expect(merges.tasks.single.message, contains('已取消外部导出'));
    expect(File(await gated.fileFor(gated.videos.single)).existsSync(), isTrue);
    expect(exported.existsSync(), isFalse);
    expect(gated.error, isNull);
  });

  test('running cancellation never commits even if the executor returns a valid output', () async {
    final executor = _Executor()..gate = Completer<void>();
    final merges = queue(executor: executor);
    merges.add(jobs());
    await executor.started.future;
    merges.cancel(merges.tasks.single);
    executor.gate!.complete();
    await settle(merges);
    expect(executor.cancelled, isTrue);
    expect(merges.tasks.single.state, MergeState.cancelled);
    expect(merges.tasks.single.outputId, isNull);
    expect(library.videos, isEmpty);
    expect(Directory(path.join(temporary.path, 'library', 'media')).listSync(), isEmpty);
  });

  test('queued cancellation never creates a product', () async {
    final merges = queue(executor: _Executor());
    merges.add(jobs());
    merges.cancel(merges.tasks.single);
    await settle(merges);
    await library.ensureInitialized();
    expect(merges.tasks.single.state, MergeState.cancelled);
    expect(library.videos, isEmpty);
  });

  test('cancel immediately after internal commit only skips export and preserves done state', () async {
    final merges = queue(executor: _Executor());
    final exported = File(path.join(temporary.path, 'not-exported.mp4'));
    library.addListener(() {
      if (library.videos.isNotEmpty) merges.cancel(merges.tasks.single);
    });
    merges.add(jobs(), file: exported.path);
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    expect(merges.tasks.single.outputId, library.videos.single.id);
    expect(merges.tasks.single.message, contains('已取消外部导出'));
    expect(exported.existsSync(), isFalse);
    expect(File(await library.fileFor(library.videos.single)).existsSync(), isTrue);
  });

  test('library notifications reach queue listeners, including library-only changes', () async {
    final merges = queue(executor: _Executor());
    await library.ensureInitialized();
    var notifications = 0;
    merges.addListener(() => notifications++);
    final video = await library.create(show, [1, 2], (output) async {
      await File(output).writeAsString('standalone');
    });
    expect(notifications, greaterThan(0));
    notifications = 0;
    await library.remove({video.id});
    expect(notifications, greaterThan(0));
  });

  test('injected MergeSave keeps the existing signature and result contract', () async {
    final executor = _Executor();
    final merges = queue(executor: executor, save: (merge, task) async {
      expect(task.jobs.length, 2);
      expect(merge.fileName, '队列剧 第1-2集.mp4');
      return 'injected';
    });
    merges.add(jobs());
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.done);
    expect(merges.tasks.single.message, 'injected');
    expect(merges.tasks.single.outputId, isNull);
    expect(executor.runs, isEmpty);
  });

  test('metadata failure leaves episode downloads untouched and no managed result', () async {
    final merges = queue(executor: _Executor());
    await library.ensureInitialized();
    Directory(path.join(temporary.path, 'library', 'index.json.tmp')).createSync();
    merges.add(jobs());
    await settle(merges);
    expect(merges.tasks.single.state, MergeState.failed);
    expect(merges.tasks.single.outputId, isNull);
    expect(library.videos, isEmpty);
    expect(repository.controls, isEmpty);
    expect(Directory(path.join(temporary.path, 'library', 'media')).listSync(), isEmpty);
  });

  test('dispose during write suppresses queue notifications and prevents commit', () async {
    final executor = _Executor()..gate = Completer<void>();
    final merges = MergeQueue(repository, executor: () => executor, library: library);
    var notifications = 0, finished = 0;
    merges.addListener(() => notifications++);
    merges.onFinished = (_) => finished++;
    merges.add(jobs());
    await executor.started.future;
    merges.dispose();
    final before = notifications;
    executor.gate!.complete();
    await settle(merges);
    expect(notifications, before);
    expect(finished, 0);
    expect(library.videos, isEmpty);
    // 注入的库仍由调用方拥有，队列关闭不会 dispose 它。
    await library.create(show, [3, 4], (output) async {
      await File(output).writeAsString('available');
    });
    expect(notifications, before);
  });
}
