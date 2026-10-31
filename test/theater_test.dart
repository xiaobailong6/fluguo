import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/theater_feed.dart';
import 'package:duanju_app/theater_recommendations.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:flutter/material.dart';
import 'package:duanju_app/ui/detail/detail_page.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> settleFeed(TheaterFeed feed) async {
  for (var i = 0; i < 200 && feed.loading; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(feed.loading, false);
  await Future<void>.delayed(Duration.zero);
}

class HeldTheaterRepository extends FakeRepository {
  final pending = <Completer<CatalogPage>>[];
  int active = 0;
  int peak = 0;
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    active++;
    peak = max(peak, active);
    final completer = Completer<CatalogPage>();
    pending.add(completer);
    try {
      return await completer.future;
    } finally {
      active--;
    }
  }
}

class FailingTheaterRepository extends FakeRepository {
  bool fails = true;
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    if (fails) throw StateError('offline');
    return super.cached(source, category: category);
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    if (fails) throw StateError('offline');
    return super.categories(source, force: force);
  }

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    if (fails) throw StateError('offline');
    return super.recommendations(genre, more: more, force: force);
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    if (fails) throw StateError('offline');
    return super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      force: force,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('请求失败可重试，候选耗尽保持空状态', () async {
    final store = await openStore();
    final repo = FailingTheaterRepository();
    final feed = TheaterFeed(repo, store);
    addTearDown(feed.dispose);
    await settleFeed(feed);
    expect(feed.error, isNotNull);
    expect(feed.items, isEmpty);
    repo.fails = false;
    await feed.reload();
    expect(feed.error, isNull);
    expect(feed.items, isNotEmpty);
    await feed.nextBatch();
    expect(feed.items, isEmpty);
    expect(feed.error, isNull);
  });
  final now = DateTime(2026, 10, 29);
  List<TheaterPick> sample(
    List<Drama> pool, {
    List<WatchEntry> history = const [],
    Set<String> excluded = const {},
    int count = 10,
  }) => theaterSample(
    candidates: pool,
    history: history,
    allowedSources: {'hongguo'},
    excluded: excluded,
    random: Random(42),
    now: now,
    count: count,
  );

  test('固定种子、70/30 配额、去重、权限与完成/曝光过滤', () {
    final watched = drama('done', category: '甜宠', episodes: 2);
    final history = [watching(watched, episode: 2, position: 100)];
    final pool = [
      for (var i = 0; i < 20; i++) drama('m$i', category: '甜宠'),
      for (var i = 0; i < 20; i++) drama('e$i', category: '悬疑'),
      watched,
      drama('denied', source: 'yeguo'),
    ];
    final picks = sample(
      [...pool, ...pool],
      history: history,
      excluded: {theaterIdentity(pool.first)},
    );
    expect(
      picks.map((p) => p.drama.id),
      sample(
        pool,
        history: history,
        excluded: {theaterIdentity(pool.first)},
      ).map((p) => p.drama.id),
    );
    expect(picks.where((p) => p.drama.category == '甜宠').length, 7);
    expect(picks.map((p) => theaterIdentity(p.drama)).toSet().length, 10);
    expect(
      picks.any(
        (p) =>
            p.drama.id == watched.id ||
            p.drama.source != 'hongguo' ||
            p.drama.id == pool.first.id,
      ),
      false,
    );
    expect(sample([drama('empty')]).single.reason, contains('默认推荐'));
  });

  test('倒数第二集完成不视作整剧看完，最后一集才过滤', () {
    final item = drama('boundary', episodes: 2);
    expect(
      theaterCompleted(watching(item, episode: 1, position: 100)),
      isFalse,
    );
    expect(theaterCompleted(watching(item, episode: 2, position: 100)), isTrue);
  });

  test('最近 30 部不同剧、时间衰减和适度进度权重', () {
    WatchEntry entry(String id, DateTime time, {int episode = 0}) => WatchEntry(
      drama: drama(id, category: id, episodes: 10),
      episode: episode,
      position: 1,
      duration: 100,
      updatedAt: time,
    );
    final entries = [
      entry('new', now, episode: 8),
      entry('old', now.subtract(const Duration(days: 14))),
    ];
    final weights = theaterInterests(entries, now);
    expect(weights['new']!, greaterThan(weights['old']! * 2));
    expect(
      theaterInterests([entries.first, entries.first], now),
      theaterInterests([entries.first], now),
    );
    expect(
      theaterInterests([
        for (var i = 0; i < 40; i++)
          entry('$i', now.subtract(Duration(hours: i))),
      ], now).length,
      30,
    );
  });

  test('换批不重复、不感兴趣持久化、进度保存不发请求', () async {
    final store = await openStore();
    final repo = FakeRepository()
      ..recommended = [for (var i = 0; i < 40; i++) drama('$i')];
    final feed = TheaterFeed(repo, store, random: Random(1));
    addTearDown(feed.dispose);
    await settleFeed(feed);
    final first = feed.items.map((p) => p.drama.id).toSet();
    final hidden = feed.items.first.drama;
    await feed.hide(hidden);
    expect(
      store.preferences.getStringList('theater.hidden.default'),
      contains(theaterIdentity(hidden)),
    );
    final requests = repo.recommendRequests.length;
    await store.saveWatch(watching(hidden));
    await store.saveWatch(watching(hidden, position: 15));
    expect(repo.recommendRequests.length, requests);
    await feed.nextBatch();
    expect(feed.items.any((p) => first.contains(p.drama.id)), false);
    expect(feed.items, isNotEmpty);
  });

  test('切用户丢弃旧请求/曝光，权限变化立即清空且请求上限 2', () async {
    final salt = '0' * 32;
    final pinHash = await hashProfilePin('1234', salt);
    final store = await openStore({
      'forceLogin': false,
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理',
          admin: true,
          salt: salt,
          pinHash: pinHash,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '访客',
          sources: ['hongguo'],
        ).toJson(),
      ]),
    });
    final repo = HeldTheaterRepository();
    final feed = TheaterFeed(repo, store);
    addTearDown(feed.dispose);
    await Future<void>.delayed(Duration.zero);
    await store.switchProfile('viewer');
    expect(feed.items, isEmpty);
    await Future<void>.delayed(Duration.zero);
    repo.pending.first.complete(CatalogPage([drama('old')]));
    for (final c in repo.pending.skip(1)) {
      c.complete(CatalogPage([drama('new')]));
    }
    // 全站源还有排队的缓存请求，逐轮释放直到当前用户加载完成。
    for (var i = 0; i < 200 && feed.loading; i++) {
      for (final c in repo.pending.where((c) => !c.isCompleted)) {
        c.complete(CatalogPage([drama('new')]));
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    await settleFeed(feed);
    expect(feed.items.any((p) => p.drama.id == drama('old').id), false);
    expect(feed.items.any((p) => p.drama.id == drama('new').id), true);
    expect(store.preferences.getString('theater.exposed.default'), isNull);
    expect(store.preferences.getString('theater.exposed.viewer'), isNotNull);
    expect(repo.peak, lessThanOrEqualTo(2));
    await store.switchProfile('default', pin: '1234');
    await store.setSourceEnabled('hongguo', false);
    expect(feed.items.any((p) => p.drama.source == 'hongguo'), false);
    for (final c in repo.pending.where((c) => !c.isCompleted)) {
      c.complete(CatalogPage([]));
    }
  });

  for (final form in FormFactor.values) {
    testWidgets('剧场入口懒创建与五导航无溢出 ${form.name}', (tester) async {
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(320, 800)
          : const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      final repo = FakeRepository();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppScope(repository: repo, formFactor: form, child: child!),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TheaterPage), findsNothing);
      for (final tab in AppTab.values) {
        expect(find.byKey(ValueKey('nav-${tab.name}')), findsOneWidget);
      }
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await tester.pumpAndSettle();
      expect(find.byType(TheaterPage), findsOneWidget);
      expect(find.text('为你推荐'), findsOneWidget);
      expect(find.textContaining('本地推荐：'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final requestCount = repo.recommendRequests.length;
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(TheaterPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      scroll.position.jumpTo(80);
      await tester.pumpAndSettle();
      final offset = scroll.position.pixels;
      await tester.tap(find.byType(DramaTile).first);
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsOneWidget);
      Navigator.of(tester.element(find.byType(DetailPage))).pop();
      await tester.pumpAndSettle();
      expect(find.byType(TheaterPage), findsOneWidget);
      expect(scroll.position.pixels, offset);
      expect(repo.recommendRequests.length, requestCount);
      await tester.tap(find.byKey(const ValueKey('nav-explore')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await tester.pumpAndSettle();
      expect(find.byType(TheaterPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
