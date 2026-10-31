import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/theater_feed.dart';
import 'package:duanju_app/theater_preview.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart'
    show PreviewRepository, FakePreviewBackend, flushPreview;

class SlowStartupRepository extends PreviewRepository {
  final slowCache = Completer<CatalogPage>();
  final slowDirectory = Completer<CatalogPage>();
  int categoryCalls = 0;
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) =>
      slowCache.future;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) => slowDirectory.future;
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    categoryCalls++;
    return const [];
  }

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async =>
      CatalogPage([drama('first-fast', title: '首部立即播放')], hasMore: false);
  void finish() {
    if (!slowCache.isCompleted) {
      slowCache.complete(CatalogPage(const [], hasMore: false));
    }
    if (!slowDirectory.isCompleted) {
      slowDirectory.complete(CatalogPage(const [], hasMore: false));
    }
  }
}

class SurfaceFirstBackend extends FakePreviewBackend {
  final surface = Completer<void>();
  @override
  Widget buildVideo() => Builder(
    builder: (_) {
      if (!surface.isCompleted) surface.complete();
      return const SizedBox(key: ValueKey('fake-preview-video'));
    },
  );
  @override
  Future<void> open(PlaybackPlan plan, Duration position) async {
    await surface.future;
    await super.open(plan, position);
  }
}

class FailingStartBackend extends FakePreviewBackend {
  FailingStartBackend(this.stage);
  final String stage;
  bool fail = true;
  @override
  Future<void> open(PlaybackPlan plan, Duration position) async {
    await super.open(plan, position);
    if (fail && stage == 'open') throw StateError('decoder');
  }

  @override
  Future<void> play() async {
    await super.play();
    if (fail && stage == 'play') throw StateError('device');
  }
}

void main() {
  for (final stage in ['open', 'play']) {
    test('预览$stage失败立即停止释放并可重试', () async {
      final store = await openStore();
      final repo = PreviewRepository();
      final backend = FailingStartBackend(stage);
      final preview = TheaterPreview(repo, store, backend: () => backend);
      preview.select(drama('failed-start'));
      preview.setVisible(true);
      await flushPreview();
      expect(preview.error, isNotNull);
      expect(preview.loading, isFalse);
      expect(backend.playing, isFalse);
      expect(repo.released, [drama('failed-start').id]);
      backend.done.add(true);
      expect(preview.ended, isFalse);
      backend.fail = false;
      preview.retry();
      await flushPreview();
      expect(backend.playing, isTrue);
      expect(preview.error, isNull);
      expect(repo.released.length, 1);
      preview.dispose();
      await flushPreview();
    });
  }

  test('首个可用推荐不等慢缓存、分类或其他目录，后台加载锁仍防重复', () async {
    final store = await openStore();
    final repo = SlowStartupRepository();
    final feed = TheaterFeed(repo, store);
    addTearDown(feed.dispose);
    for (var i = 0; i < 30; i++) {
      await Future<void>.value();
    }
    expect(feed.loading, isFalse);
    expect(feed.items.first.drama.title, '首部立即播放');
    expect(repo.slowCache.isCompleted, isFalse);
    expect(repo.slowDirectory.isCompleted, isFalse);
    expect(repo.categoryCalls, 0);
    expect(feed.loadingMore, isTrue);
    repo.finish();
    for (var i = 0; i < 50; i++) {
      await Future<void>.value();
    }
    expect(feed.loadingMore, isFalse);
  });

  testWidgets('首次open等待表面也能起播，标题左上且入口内收上移透明黑底', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await openStore();
    final repo = SlowStartupRepository();
    final backend = SurfaceFirstBackend();
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: TheaterPage(store: store, previewBackend: () => backend),
      ),
    );
    // 后台慢接口与加载动画未结束，不使用 pumpAndSettle 等待全部网络。
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(backend.playing, isTrue);
    expect(backend.opens, [Duration.zero]);
    expect(repo.slowDirectory.isCompleted, isFalse);
    expect(find.text('剧场 · 首集预览'), findsNothing);
    expect(find.textContaining('因为你看过'), findsNothing);
    expect(find.textContaining('默认推荐'), findsNothing);
    final title = find.byKey(const ValueKey('theater-drama-title'));
    expect(tester.widget<Text>(title).data, '首部立即播放');
    expect(tester.getTopLeft(title).dy, lessThan(70));
    final entry = find.byKey(const ValueKey('theater-open-full')).first;
    final rect = tester.getRect(entry);
    expect(rect.left, greaterThanOrEqualTo(28));
    expect(rect.right, lessThanOrEqualTo(362));
    expect(rect.bottom, 832);
    expect(rect.height, lessThanOrEqualTo(40));
    final glass = tester.widget<GlassSurface>(
      find.ancestor(of: entry, matching: find.byType(GlassSurface)).first,
    );
    expect(glass.style!.tint.r, 0);
    expect(glass.style!.tint.a, lessThan(.25));
    await tester.pumpWidget(const SizedBox.shrink());
    repo.finish();
    await tester.pump();
  });
}
