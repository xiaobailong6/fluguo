import 'dart:async';
import 'dart:io';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/merged_export.dart';
import 'package:duanju_app/download_collections.dart';
import 'package:duanju_app/download_converter.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/media_pipeline.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/downloads/downloads_page.dart';
import 'package:duanju_app/ui/downloads/downloaded_drama_page.dart';
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
  /// 设置后 probe 直接抛出，用来制造合并失败。
  String? fail;
  Completer<MediaProbe>? probeGate;
  Completer<void>? cancelGate;
  int cancels = 0;

  @override
  Future<MediaProbe> probe(String file) async {
    if (probeGate case final gate?) return gate.future;
    if (fail case final message?) throw AppFailure(message);
    return MediaProbe({
      'format': {'duration': '12'},
      'streams': [
        {'codec_type': 'video', 'codec_name': 'h264'},
      ],
    });
  }

  @override
  Future<void> run(
    List<String> args, {
    double duration = 0,
    void Function(double)? progress,
  }) async {}

  @override
  Future<void> cancel() async {
    cancels++;
    if (cancelGate case final gate?) await gate.future;
    final gate = probeGate;
    if (gate != null && !gate.isCompleted) gate.completeError(AppFailure('已取消合并'));
  }
}

class _TestMergedLibrary extends MergedLibrary {
  _TestMergedLibrary({required super.directory});
  void publishTaskProgress() => notifyListeners();
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
  late _TestMergedLibrary library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('downloads-management-');
    library = _TestMergedLibrary(directory: root);
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
    MediaExecutor? executor,
    Size? size,
    double textScale = 1,
    Drama? detail,
  }) async {
    final media = executor ?? _Executor();
    await tester.binding.setSurfaceSize(
      size ??
          (form == FormFactor.window
              ? const Size(1100, 900)
              : const Size(390, 844)),
    );
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    final overview = DownloadOverview(
      repository,
      store,
      interval: const Duration(hours: 1),
      idleInterval: const Duration(hours: 1),
    );
    final converter = DownloadConverter(repository, overview, executor: media);
    final merges = MergeQueue(
      repository,
      library: library,
      save: (merge, task) async {
        onMerge?.call(task.jobs);
        return 'test-save';
      },
      executor: () => media,
    );
    final fixture = _Fixture(overview, converter, merges);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: AppScope(
            repository: repository,
            formFactor: form,
            child: child!,
          ),
        ),
        home: detail == null
            ? DownloadsPage(
                store: store,
                downloads: overview,
                converter: converter,
                merges: merges,
              )
            : DownloadedDramaPage(
                store: store,
                downloads: overview,
                drama: detail,
                merges: merges,
              ),
      ),
    );
    await tester.pumpAndSettle();
    return fixture;
  }

  testWidgets('运行中海报同排状态与完整百分比，查看关闭不会取消或重启', (tester) async {
    final gate = Completer<MediaProbe>();
    final executor = _Executor()..probeGate = gate;
    final repository = _Repository()..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository, executor: executor,
      size: const Size(320, 844));
    await tester.tap(find.text('已合并'));
    await tester.pumpAndSettle();
    fixture.merges.add(repository.jobs!);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final task = fixture.merges.tasks.single;
    task.progress = .42;
    task
      ..phase = 'merging'
      ..mergeProgress = .42;
    library.publishTaskProgress();
    await tester.pump();
    var tile = tester.widget<ProgressPoster>(poster(first.id));
    expect(tile.inlineStatus, isTrue);
    expect(tile.progressLabel, '42%');
    expect(tile.showMenuButton, isFalse);
    expect(find.byTooltip('成品菜单'), findsNothing);
    expect(find.text('42%'), findsOneWidget);
    final source = find.descendant(of: poster(first.id),
      matching: find.text(SourceSite.byId(first.source).name));
    expect(tester.getCenter(source).dy,
      closeTo(tester.getCenter(find.text('合并中')).dy, 1));
    await tester.tap(poster(first.id));
    await tester.pump(const Duration(milliseconds: 400));
    expect(executor.cancels, 0);
    expect(task.state, MergeState.running);
    expect(find.text('取消合并任务？'), findsNothing);
    task.progress = .99;
    task.mergeProgress = .99;
    library.publishTaskProgress();
    await tester.pump();
    expect(find.text('99%'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pump(const Duration(milliseconds: 400));
    tile = tester.widget<ProgressPoster>(poster(first.id));
    expect(tile.progressLabel, '99%');
    expect(executor.cancels, 0);
    expect(fixture.merges.tasks, hasLength(1));
    expect(tester.takeException(), isNull);
    fixture.merges.cancel(task);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  for (final scale in [1.0, 2.0, 3.0]) {
    testWidgets('下载列表 320 宽、$scale倍字体不溢出', (tester) async {
      final repository = _Repository()
        ..jobs = [downloadJob(first, 100000, state: 'paused')];
      final fixture = await mount(
        tester,
        repository,
        size: const Size(320, 844),
        textScale: scale,
      );
      expect(find.text('第 100000 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  for (final scale in [2.0, 3.0]) {
    testWidgets('已下载分集 320 宽、$scale倍字体及编辑态不溢出', (tester) async {
      final repository = _Repository()
        ..jobs = [
          for (var number = 100000; number < 100012; number++)
            DownloadJob(
              id: '${first.id}:$number',
              drama: first,
              episode: Episode({'vip': true}, number),
              state: 'completed',
              actualQuality: 1080,
              bytes: 1024,
            ),
          downloadJob(first, 100012, state: 'paused'),
        ];
      final fixture = await mount(
        tester,
        repository,
        detail: first,
        size: const Size(320, 844),
        textScale: scale,
      );
      final firstCard = find.byKey(ValueKey('${first.id}:100000'));
      final secondCard = find.byKey(ValueKey('${first.id}:100001'));
      expect(tester.getSize(firstCard).height, greaterThan(64));
      expect(
        tester.getTopLeft(secondCard).dy - tester.getTopLeft(firstCard).dy,
        closeTo(tester.getSize(firstCard).height + 12, .01),
      );
      expect(find.textContaining('另有 1 集未完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(firstCard);
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 横向起拖后跨行，验证放大字体后的命中行距与网格一致。
      final gesture = await tester.startGesture(tester.getCenter(secondCard));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveTo(tester.getCenter(firstCard));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final scrollable = tester.state<ScrollableState>(find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ));
      final edgeDrag = await tester.startGesture(tester.getCenter(secondCard));
      await edgeDrag.moveBy(const Offset(30, 0));
      await tester.pump();
      final viewport = tester.getRect(find.byType(CustomScrollView));
      await edgeDrag.moveTo(Offset(viewport.center.dx, viewport.bottom - 4));
      await tester.pump(const Duration(milliseconds: 500));
      expect(scrollable.position.pixels, greaterThan(0));
      await edgeDrag.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  testWidgets('删除失败展示错误且重试发送 remove，运行中删除不显示', (tester) async {
    final repository = _Repository()
      ..jobs = [
        DownloadJob(
          id: '${first.id}:1',
          drama: first,
          episode: Episode(const {}, 1),
          state: 'removing',
          error: '文件被占用',
        ),
        downloadJob(second, 1, state: 'removing'),
      ];
    final fixture = await mount(tester, repository);
    expect(find.text('删除失败'), findsOneWidget);
    expect(find.text('文件被占用'), findsOneWidget);
    expect(find.text(second.title), findsNothing);
    expect(find.byTooltip('继续'), findsNothing);
    final retry = find.byTooltip('重试删除');
    expect(retry, findsOneWidget);
    expect(
      tester.widget<Icon>(find.descendant(
        of: retry,
        matching: find.byType(Icon),
      )).icon,
      Icons.delete_outline_rounded,
    );
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(repository.controls, ['remove|${first.id}:1']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('导出授权期间权限变更不会调用系统复制', (tester) async {
    var allowed = true;
    var copies = 0;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'requestVideoExport') {
        allowed = false;
        return true;
      }
      if (call.method == 'exportVideo') copies++;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    final video = MergedVideo(
      id: 'unused',
      drama: first,
      episodes: [1, 2],
      bytes: 1,
      createdAt: DateTime.now(),
      fileName: 'video.mp4',
    );
    await expectLater(
      exportMergedVideo(
        library,
        video,
        checkAccess: () {
          if (!allowed) throw AppFailure('权限已变更');
        },
      ),
      throwsA(isA<AppFailure>()),
    );
    expect(copies, 0);
  });

  for (final form in [FormFactor.phone, FormFactor.window]) {
    testWidgets('已下载长按、全选、取消与批量删除 ${form.name}', (tester) async {
      final repository = _Repository()
        ..jobs = [
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
      expect(
        find.ancestor(of: menu, matching: find.byType(GlassSurface)),
        findsOneWidget,
      );
      expect(tester.getSize(menu), const Size(30, 30));
      expect(
        find.descendant(
          of: poster(partial.id),
          matching: find.byTooltip('剧集菜单'),
        ),
        findsOneWidget,
      );
      await tester.longPress(poster(first.id));
      await tester.pumpAndSettle();
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('取消全选'), findsNothing);
      expect(
        tester
            .widgetList<ProgressPoster>(find.byType(ProgressPoster))
            .every((item) => item.selected == false),
        isTrue,
      );
      expect(find.byTooltip('剧集菜单'), findsNothing);
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('取消全选'), findsOneWidget);
      expect(
        tester
            .widgetList<ProgressPoster>(find.byType(ProgressPoster))
            .every((item) => item.selected == true),
        isTrue,
      );
      await tester.tap(find.text('取消全选'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<ProgressPoster>(find.byType(ProgressPoster))
            .every((item) => item.selected == false),
        isTrue,
      );
      await tester.tap(poster(first.id));
      await tester.tap(poster(partial.id));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除 2 部'));
      await tester.pumpAndSettle();
      expect(find.textContaining('下载中/处理中的分集'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      expect(repository.removed.toSet(), {
        '${first.id}:1',
        '${first.id}:2',
        '${partial.id}:1',
      });
      expect(
        repository.jobs!.any((job) => job.drama.id == partial.id && job.active),
        isTrue,
      );
      expect(repository.jobs!.any((job) => job.drama.id == second.id), isTrue);
      expect(poster(first.id), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  testWidgets('未完成分集徽标与站源同排，完成后才显示海报菜单', (tester) async {
    final repository = _Repository()
      ..jobs = [
        downloadJob(first, 3),
        downloadJob(first, 1),
        downloadJob(first, 2),
        downloadJob(first, 4, state: 'paused'),
        downloadJob(first, 5, state: 'failed'),
        downloadJob(first, 6, state: 'converting'),
      ];
    final fixture = await mount(tester, repository);
    await tester.tap(find.text('已下载 1'));
    await tester.pumpAndSettle();
    expect(find.text('3 集未完成'), findsOneWidget);
    final tile = tester.widget<ProgressPoster>(poster(first.id));
    expect(tile.inlineStatus, isTrue);
    expect(tile.showMenuButton, isFalse);
    expect(find.byTooltip('剧集菜单'), findsNothing);
    final source = find.descendant(of: poster(first.id),
        matching: find.text(SourceSite.byId(first.source).name));
    expect(tester.getCenter(source).dy,
        closeTo(tester.getCenter(find.text('3 集未完成')).dy, 1));
    repository.jobs = [for (final job in repository.jobs!)
      downloadJob(job.drama, job.episode.number)];
    await fixture.overview.refresh();
    await tester.pumpAndSettle();
    expect(find.text('3 集未完成'), findsNothing);
    expect(find.byTooltip('剧集菜单'), findsOneWidget);
    expect(repository.removed, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('已合并海报菜单可直接删除单个成品', (tester) async {
    final video = (await tester.runAsync(
      () => library.create(first, [1, 2], (file) async {
        await File(file).writeAsString('merged-single');
      }),
    ))!;
    final repository = _Repository()..jobs = [downloadJob(first, 1)];
    final fixture = await mount(tester, repository);
    await tester.tap(find.text('已合并 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('成品菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('删除 1 项？'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      for (var i = 0; i < 100 && library.videos.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();
    expect(library.videos, isEmpty);
    expect(
      File('${root.path}/media/${video.id}/video.mp4').existsSync(),
      isFalse,
    );
    expect(repository.removed, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('合并失败保留海报，点击查看错误、重试或多选删除', (tester) async {
    const message = '第 2 集的画面或声音格式和其余集不同，无法无损合并。请分开选择格式相同的集，或删除后重新下载这些集。';
    final executor = _Executor()..fail = message;
    final repository = _Repository()
      ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository, executor: executor);
    await tester.tap(find.text('已合并'));
    await tester.pumpAndSettle();
    fixture.merges.add([downloadJob(first, 1), downloadJob(first, 2)]);
    await tester.pumpAndSettle();

    expect(find.text('已合并 · 失败 1'), findsOneWidget);
    expect(poster(first.id), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(find.text('清除任务记录'), findsNothing);
    expect(tester.widget<ProgressPoster>(poster(first.id)).status, '合并失败');
    expect(find.textContaining(message), findsNothing);
    expect(find.byTooltip('成品菜单'), findsNothing);
    await tester.tap(poster(first.id));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '重新合并'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    expect(poster(first.id), findsOneWidget);
    await tester.longPress(poster(first.id));
    await tester.pumpAndSettle();
    await tester.tap(poster(first.id));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除 1 部'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();
    expect(fixture.merges.tasks, isEmpty);
    expect(find.text('合并失败'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  for (final message in ['外部导出失败：无权限', '外部导出未完成：无权限']) {
    testWidgets('done 合并任务不再展示旧导出记录：$message', (tester) async {
      final repository = _Repository()
        ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
      final fixture = await mount(tester, repository);
      fixture.merges.add(repository.jobs!);
      await tester.pumpAndSettle();
      final task = fixture.merges.tasks.single;
      expect(task.state, MergeState.done);
      task.message = message;
      await tester.tap(find.text('已合并'));
      await tester.pumpAndSettle();
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.text('任务记录 1'), findsNothing);
      expect(find.text('清除任务记录'), findsNothing);
      expect(poster(first.id), findsNothing);
      expect(find.text(message), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  for (final needsConversion in [false, true]) {
    testWidgets('合并弹窗显示${needsConversion ? '转换和合并两步' : '仅合并一步'}独立进度', (tester) async {
      final executor = _Executor()..probeGate = Completer<MediaProbe>();
      final repository = _Repository()
        ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
      final fixture = await mount(tester, repository, executor: executor);
      await tester.tap(find.text('已合并'));
      await tester.pumpAndSettle();
      fixture.merges.add(repository.jobs!);
      await tester.pump();
      await tester.tap(poster(first.id));
      await tester.pump(const Duration(milliseconds: 400));
      final sheet = find.byType(BottomSheet);
      final bars = find.descendant(of: sheet,
          matching: find.byType(LinearProgressIndicator));
      expect(find.text('检查'), findsOneWidget);
      expect(bars, findsNothing);
      final task = fixture.merges.tasks.single;
      task
        ..needsConversion = needsConversion
        ..conversionTotal = needsConversion ? 3 : 0
        ..conversionCompleted = needsConversion ? 1 : 0
        ..conversionProgress = needsConversion ? .25 : null
        ..mergeProgress = needsConversion ? null : .67
        ..phase = needsConversion ? 'converting' : 'merging'
        ..status = needsConversion ? '正在转换第 2 集' : '正在合并视频';
      library.publishTaskProgress();
      await tester.pump();
      expect(find.text('检查'), findsNothing);
      expect(find.text(task.status), findsOneWidget);
      expect(bars, findsNWidgets(needsConversion ? 2 : 1));
      if (needsConversion) {
        expect(find.text('1 转换异常分集（1/3）'), findsOneWidget);
        expect(find.text('2 合并视频'), findsOneWidget);
        expect(find.text('25%'), findsOneWidget);
        expect(find.descendant(of: sheet, matching: find.text('0%')), findsOneWidget);
        expect(tester.widgetList<LinearProgressIndicator>(bars)
            .map((bar) => bar.value), [.25, 0]);
        task
          ..conversionCompleted = 3
          ..conversionProgress = 1
          ..mergeProgress = .67
          ..phase = 'merging';
        library.publishTaskProgress();
        await tester.pump();
        expect(find.text('1 转换异常分集（3/3）'), findsOneWidget);
        expect(find.text('100%'), findsOneWidget);
        expect(find.text('67%'), findsOneWidget);
        expect(tester.widgetList<LinearProgressIndicator>(bars)
            .map((bar) => bar.value), [1, .67]);
      } else {
        expect(find.textContaining('转换异常分集'), findsNothing);
        expect(find.text('合并视频'), findsOneWidget);
        expect(find.text('67%'), findsOneWidget);
      }
      await tester.tap(find.widgetWithText(TextButton, '关闭'));
      await tester.pump(const Duration(milliseconds: 400));
      fixture.merges.cancel(task);
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    });
  }

  testWidgets('取消和清理时按钮禁用，海报显示取消中，结束仍保留海报', (tester) async {
    final executor = _Executor()
      ..probeGate = Completer<MediaProbe>()
      ..cancelGate = Completer<void>();
    final repository = _Repository()
      ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository, executor: executor);
    await tester.tap(find.text('已合并'));
    await tester.pumpAndSettle();
    fixture.merges.add(repository.jobs!);
    await tester.pump();
    await tester.tap(poster(first.id));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(OutlinedButton, '取消合并'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, '取消合并'));
    await tester.pump(const Duration(milliseconds: 400));
    final task = fixture.merges.tasks.single;
    expect(task.cancelling, isTrue);
    expect(executor.cancels, 1);
    final cancelling = find.widgetWithText(OutlinedButton, '正在取消');
    expect(tester.widget<OutlinedButton>(cancelling).onPressed, isNull);
    await tester.tap(cancelling);
    await tester.pump();
    expect(executor.cancels, 1);
    expect(find.text('取消合并任务？'), findsNothing);
    expect(tester.widget<ProgressPoster>(poster(first.id)).status, '取消中');
    task
      ..cancelling = false
      ..cleaning = true;
    library.publishTaskProgress();
    await tester.pump();
    expect(tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '清理中')).onPressed, isNull);
    expect(find.widgetWithText(FilledButton, '重新合并'), findsNothing);
    task
      ..cleaning = false
      ..cancelling = true;
    executor.cancelGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(TextButton, '关闭'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(poster(first.id), findsOneWidget);
    expect(tester.widget<ProgressPoster>(poster(first.id)).status, '已取消');
    await tester.tap(poster(first.id));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.widgetWithText(FilledButton, '重新合并'), findsOneWidget);
    expect(find.byType(ExpansionTile), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('删除运行任务立即隐藏并恢复操作，原生退出前禁止删除原分集', (tester) async {
    final executor = _Executor()
      ..probeGate = Completer<MediaProbe>()
      ..cancelGate = Completer<void>();
    final repository = _Repository()
      ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository, executor: executor);
    await tester.tap(find.text('已合并'));
    await tester.pumpAndSettle();
    fixture.merges.add(repository.jobs!);
    await tester.pump();
    await tester.longPress(poster(first.id));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(poster(first.id));
    await tester.pump();
    await tester.tap(find.text('删除 1 部'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.merges.tasks, isEmpty);
    expect(poster(first.id), findsNothing);
    expect(find.text('删除 1 部'), findsNothing);
    expect(executor.cancelGate!.isCompleted, isFalse);
    expect(fixture.merges.usesDownload(repository.jobs!.first.id), isTrue);
    await tester.tap(find.text('已下载 1'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.longPress(poster(first.id));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(poster(first.id));
    await tester.pump();
    await tester.tap(find.text('删除 1 部'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('所选分集正在合并'), findsOneWidget);
    expect(find.text('删除 1 部已下载剧集？'), findsNothing);
    expect(repository.removed, isEmpty);
    executor.cancelGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(fixture.merges.usesDownload(repository.jobs!.first.id), isFalse);
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
    final repository = _Repository()
      ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository);
    await tester.tap(find.text('已合并 2'));
    await tester.pumpAndSettle();
    // 徽标已从左下移到站源下面，两个成品各一个。
    expect(find.text('已合并'), findsNWidgets(2));
    expect(find.textContaining('第 1-2 集'), findsOneWidget);
    expect(find.textContaining('第 1、3 集'), findsOneWidget);
    await tester.longPress(poster(first.id));
    await tester.pumpAndSettle();
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('取消全选'), findsOneWidget);
    expect(
      tester
          .widgetList<ProgressPoster>(find.byType(ProgressPoster))
          .every((item) => item.selected == true),
      isTrue,
    );
    await tester.tap(find.text('删除 2 部'));
    await tester.pumpAndSettle();
    expect(find.textContaining('原分集和已导出副本保留'), findsOneWidget);
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
    expect(
      File('${root.path}/media/${one.id}/video.mp4').existsSync(),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('已合并海报三点菜单与短剧海报同尺寸，可导出到 Movies', (tester) async {
    final video = (await tester.runAsync(
      () => library.create(first, [1, 2], (file) async {
        await File(file).writeAsString('merged-export');
      }),
    ))!;
    final repository = _Repository()
      ..jobs = [downloadJob(first, 1), downloadJob(first, 2)];
    final fixture = await mount(tester, repository);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'requestVideoExport') return true;
      if (call.method == 'exportVideo') {
        expect(call.arguments['source'], contains(video.id));
        return null;
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
    );
    await tester.tap(find.text('已合并 1'));
    await tester.pumpAndSettle();
    final menu = find.byTooltip('成品菜单');
    expect(menu, findsOneWidget);
    expect(tester.getSize(menu), const Size(30, 30));
    expect(
      find.ancestor(of: menu, matching: find.byType(GlassSurface)),
      findsOneWidget,
    );
    await tester.tap(menu);
    await tester.pumpAndSettle();
    expect(find.text('导出到 Movies'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await tester.tap(find.text('导出到 Movies'));
    await tester.pumpAndSettle();
    expect(
      File('${root.path}/media/${video.id}/video.mp4').existsSync(),
      isTrue,
    );
    expect(library.videos, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });
}
