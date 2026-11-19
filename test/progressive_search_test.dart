import 'dart:async';

import 'package:duanju_app/app_failure.dart';
import 'package:duanju_app/drama_feed.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_content_motion_test.dart'
    show PendingSearchRepository, mountSearch, submit;
import 'support/fakes.dart';

class _SearchRepository extends PendingSearchRepository {
  final cache = Completer<CatalogPage>();
  int cacheReads = 0;
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) {
    cacheReads++;
    return cache.future;
  }
}

void main() {
  testWidgets('缓存匹配先出现，远端替换去重且只请求一次搜索', (tester) async {
    final store = await openStore();
    final repository = _SearchRepository();
    await mountSearch(tester, store, repository);
    expect(repository.pending.containsKey(('first', 1)), isTrue);
    repository.cache.complete(
      CatalogPage([
        drama('cached', title: 'First cached'),
        drama('cached', title: 'First duplicate'),
        drama('unmatched', title: 'Other title'),
        drama('blocked', title: 'First blocked', source: 'dsd'),
      ]),
    );
    await tester.pump();
    expect(find.text('First cached'), findsOneWidget);
    expect(find.text('First duplicate'), findsNothing);
    expect(find.text('Other title'), findsNothing);
    expect(find.text('First blocked'), findsNothing);
    expect(find.text('本地匹配，正在联网搜索'), findsOneWidget);
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('fresh', title: 'Fresh first')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh first'), findsOneWidget);
    expect(find.text('First cached'), findsNothing);
    expect(find.text('已找到 1 部'), findsOneWidget);
    expect(
      tester.state<ScrollableState>(
        find.descendant(
          of: find.byType(CustomScrollView),
          matching: find.byType(Scrollable),
        ),
      ),
      same(scroll),
    );
    expect(repository.catalogRequests, ['hongguo|first|1']);
    expect(repository.cacheReads, 1);
  });

  testWidgets('远端先到不等慢缓存，迟到缓存不覆盖结果', (tester) async {
    final store = await openStore();
    final repository = _SearchRepository();
    await mountSearch(tester, store, repository);
    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('fresh', title: 'Fresh first')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fresh first'), findsOneWidget);
    repository.cache.complete(
      CatalogPage([drama('stale', title: 'First stale')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('First stale'), findsNothing);
    expect(find.text('Fresh first'), findsOneWidget);
  });

  testWidgets('远端失败保留缓存，并显示结构化网络恢复入口', (tester) async {
    final store = await openStore();
    final repository = _SearchRepository();
    await mountSearch(tester, store, repository);
    repository.cache.complete(
      CatalogPage([drama('cache', title: 'First cache')]),
    );
    await tester.pump();
    repository.pending[('first', 1)]!.completeError(
      const AppFailure('网络不可用', code: 'network'),
    );
    await tester.pumpAndSettle();
    expect(find.text('First cache'), findsOneWidget);
    expect(find.text('暂时显示本地匹配'), findsOneWidget);
    expect(find.text('网络设置'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(find.text('First cache'), findsOneWidget);
    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('recovered', title: 'Recovered first')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Recovered first'), findsOneWidget);
    expect(repository.cacheReads, 1);
  });

  testWidgets('查询切换和用户切换后旧缓存与旧响应不能显示', (tester) async {
    final store = await openStore();
    final repository = _SearchRepository();
    await mountSearch(tester, store, repository);
    await submit(tester, 'second');
    repository.cache.complete(CatalogPage([drama('old', title: 'First old')]));
    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('late', title: 'First late')]),
    );
    await tester.pump();
    expect(find.text('First old'), findsNothing);
    expect(find.text('First late'), findsNothing);
    await store.switchProfile(store.profile.id);
    await tester.pump();
    repository.pending[('second', 1)]!.complete(
      CatalogPage([drama('wrong', title: 'Second wrong')]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Second wrong'), findsNothing);
    expect(find.text('访问权限已变更'), findsOneWidget);
  });

  test('并行缓存失败或销毁不会产生迟到通知', () async {
    final cache = Completer<CatalogPage>();
    final remote = Completer<CatalogPage>();
    final feed = DramaFeed(
      load: (_, _) => remote.future,
      cached: () => cache.future,
      cacheAlongsideLoad: true,
    );
    var notifications = 0;
    feed.addListener(() => notifications++);
    final work = feed.reload();
    feed.dispose();
    cache.completeError(StateError('cache unavailable'));
    remote.complete(CatalogPage([drama('late')]));
    await work;
    await pumpEventQueue();
    expect(notifications, 1);
  });
}
