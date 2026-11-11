import 'dart:async';
import 'dart:io';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/merged_export.dart';
import 'package:duanju_app/download_collections.dart';
import 'package:duanju_app/download_converter.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/downloads/downloads_page.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final removed = <String>[];

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids,
  ) async {
    if (command == 'remove') {
      removed.addAll(ids);
      jobs = jobs!.where((job) => !ids.contains(job.id)).toList();
      downloadChanges.value++;
    }
    return DownloadBatchResult(completed: ids);
  }

  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => PlaybackPlan(url: '/local/${episode.number}.mp4', local: true);
}

class _Executor implements MediaExecutor {
  @override
  Future<MediaProbe> probe(String file) async => MediaProbe({
    'format': {'duration': '12'},
    'streams': [{'codec_type': 'video', 'codec_name': 'h264'}],
  });

  @override
  Future<void> run(
    List<String> args, {
    double duration = 0,
    void Function(double)? progress,
  }) async {}

  @override
  Future<void> cancel() async {}
}

class _Fixture {
  _Fixture(this.overview, this.converter, this.merges);
  final DownloadOverview overview;
  final DownloadConverter converter;
  final MergeQueue merges;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    merges.dispose();
    converter.dispose();
    overview.dispose();
  }
}

void main() {
  final first = drama('download-a', title: '已下载甲');
  final second = drama('download-b', title: '已下载乙');
  final partial = drama('partial', title: '仍在下载');
  late Directory root;
  late MergedLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('downloads-management-');
    library = MergedLibrary(directory: root);
    await library.ensureInitialized();
    debugMergedExportSupported = true;
  });
  tearDown(() async {
    library.dispose();
    await root.delete(recursive: true);
    debugMergedExportSupported = false;
  });

  Finder poster(String id) => find.byWidgetPredicate(
    (widget) => widget is ProgressPoster && widget.drama.id == id,
  );

  Future<_Fixture> mount(
    WidgetTester tester,
    _Repository repository, {
    FormFactor form = FormFactor.phone,
    void Function(List<DownloadJob>)? onMerge,
  }) async {
    await tester.binding.setSurfaceSize(
      form == FormFactor.window
          ? const Size(1100, 900)
          : const Size(390, 844),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    final overview = DownloadOverview(
      repository,
      store,
      interval: const Duration(hours: 1),
      idleInterval: const Duration(hours: 1),
    );
    final converter = DownloadConverter(repository, overview, executor: _Executor());
    final merges = MergeQueue(
      repository,
      library: library,
      save: (merge, task) async {
        onMerge?.call(task.jobs);
        return 'test-save';
      },
    );
    final fixture = _Fixture(overview, converter, merges);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(MaterialApp(
      builder: (_, child) => AppScope(
        repository: repository,
        formFactor: form,
        child: child!,
      ),
      home: DownloadsPage(
        store: store,
        downloads: overview,
        converter: converter,
        merges: merges,
      ),
    ));
    await tester.pumpAndSettle();
    return fixture;
  }

  for (final form in [FormFactor.phone, FormFactor.window]) {
    testWidgets('已下载长按、全选、取消与批量删除 ${form.name}', (tester) async {
      final repository = _Repository()..jobs = [
        downloadJob(first, 1),
        downloadJob(first, 2),
        downloadJob(second, 1),
        downloadJob(partial, 1),
        downloadJob(partial, 2, state: 'downloading'),
      ];
      final fixture = await mount(tester, repository, form: form);
      await tester.tap(find.text('已下载 3'));
      await tester.pumpAndSettle();
      final menu = find.descendant(
        of: poster(first.id),
        matching: find.byTooltip('剧集菜单'),
      );
      expect(menu, findsOneWidget);
      expect(find.ancestor(of: menu, matching: find.byType(GlassSurface)), findsOneWidget);
      expect(tester.getSize(menu), const Size(30, 30));
      expect(find.descendant(
        of: poster(partial.id),
        matching: find.byTooltip('剧集菜单'),
      ), findsNothing);
      await tester.longPress(poster(first.id));
      await tester.pumpAndSettle();
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('取消全选'), findsNothing);
      expect(tester.widgetList<ProgressPoster>(find.byType(ProgressPoster))
          .every((item) => item.selected == false), isTrue);
      expect(find.byTooltip('剧集菜单'), findsNothing);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('取消全选'), findsOneWidget);
      expect(tester.widgetList<ProgressPoster>(find.byType(ProgressPoster))
          .every((item) => item.selected == true), isTrue);
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(tester.widgetList<ProgressPoster>(find.byType(ProgressPoster))
          .every((item) => item.selected == false), isTrue);
      await tester.tap(poster(first.id));
      await tester.tap(poster(partial.id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除 2 部'));
      await tester.pumpAndSettle();
      expect(find.textContaining('下载中/处理中的分集'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(repository.removed.toSet(), {
        '${first.id}:1', '${first.id}:2', '${partial.id}:1',
      });
      expect(repository.jobs!.any((job) => job.drama.id == partial.id && job.active), isTrue);
      expect(repository.jobs!.any((job) => job.drama.id == second.id), isTrue);
      expect(poster(first.id), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  testWidgets('海报合并菜单默认使用全部已下载分集', (tester) async {
    List<DownloadJob>? selected;
    final repository = _Repository()..jobs = [
      downloadJob(first, 3), downloadJob(first, 1), downloadJob(first, 2),
    ];
    final fixture = await mount(tester, repository, onMerge: (jobs) => selected = jobs);
    await tester.tap(find.text('已下载 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('剧集菜单'));
    await tester.pumpAndSettle();
    expect(find.text('合并'), findsOneWidget);
    await tester.tap(find.text('合并'));
    await tester.pumpAndSettle();
    expect(selected?.map((job) => job.episode.number), [1, 2, 3]);
    expect(repository.removed, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('已合并海报标注范围，多选删除不删原分集', (tester) async {
    final one = (await tester.runAsync(() async {
      final firstVideo = await library.create(first, [1, 2], (file) async {
        await File(file).writeAsString('merged-one');
      });
      await library.create(second, [1, 3], (file) async {
        await File(file).writeAsString('merged-two');
      });
      return firstVideo;
    }))!;
    final repository = _Repository()..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository);
    await tester.tap(find.text('已合并 2'));
    await tester.pumpAndSettle();
    expect(find.textContaining('播放使用应用内副本，无需额外文件访问授权'), findsOneWidget);
    expect(find.textContaining('第 1-2 集'), findsOneWidget);
    expect(find.textContaining('第 1、3 集'), findsOneWidget);
    await tester.longPress(poster(first.id));
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('取消全选'), findsOneWidget);
    expect(tester.widgetList<ProgressPoster>(find.byType(ProgressPoster))
        .every((item) => item.selected == true), isTrue);
    await tester.tap(find.text('删除 2 部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原分集和已导出的副本保留'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      for (var i = 0; i < 100 && library.videos.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(library.videos, isEmpty);
    expect(repository.removed, isEmpty);
    expect(repository.jobs, hasLength(2));
    expect(File('${root.path}/media/${one.id}/video.mp4').existsSync(), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('已合并海报三点菜单与短剧海报同尺寸，可导出到 Movies', (tester) async {
    final video = (await tester.runAsync(() => library.create(first, [1, 2], (file) async {
      await File(file).writeAsString('merged-export');
    })))!;
    final repository = _Repository()..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'requestVideoExport') return true;
      if (call.method == 'exportVideo') {
        expect(call.arguments['source'], contains(video.id));
        return null;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    await tester.tap(find.text('已合并 1'));
    await tester.pumpAndSettle();
    final menu = find.byTooltip('成品菜单');
    expect(menu, findsOneWidget);
    expect(tester.getSize(menu), const Size(30, 30));
    expect(find.ancestor(of: menu, matching: find.byType(GlassSurface)), findsOneWidget);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('导出到 Movies'), findsOneWidget);
    await tester.tap(find.text('导出到 Movies'));
    await tester.pumpAndSettle();
    expect(File('${root.path}/media/${video.id}/video.mp4').existsSync(), isTrue);
    expect(library.videos, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });
}
