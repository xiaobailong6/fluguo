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
import 'package:duanju_app/theater_preview.dart';
import 'package:duanju_app/theater_preview_backend.dart';
import 'package:flutter/services.dart';
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

class FakePreviewBackend implements PreviewBackend {
  final done = StreamController<bool>.broadcast(sync: true);
  final failures = StreamController<String>.broadcast(sync: true);
  final opens = <Duration>[];
  final events = <String>[];
  bool playing = false;
  Completer<void>? heldOpen;
  @override
  Duration position = Duration.zero;
  @override
  Stream<bool> get completed => done.stream;
  @override
  Stream<String> get errors => failures.stream;
  @override
  Widget buildVideo() => const SizedBox(key: ValueKey('fake-preview-video'));
  @override
  Future<void> open(PlaybackPlan plan, Duration start) async {
    events.add('open');
    opens.add(start);
    position = start;
    await heldOpen?.future;
  }

  @override
  Future<void> play() async {
    events.add('play');
    playing = true;
  }

  @override
  Future<void> stop() async {
    events.add('stop');
    playing = false;
  }

  @override
  Future<void> dispose() async {
    events.add('dispose');
    await done.close();
    await failures.close();
  }
}

class PreviewRepository extends FakeRepository {
  final resolved = <String>[];
  final released = <String>[];
  final requested = <String>[];
  Completer<DramaDetail>? heldDetail;
  Completer<PlaybackPlan>? heldResolve;
  bool emptyDetail = false;
  @override
  Future<DramaDetail> detail(Drama drama) async {
    requested.add(drama.id);
    if (detailFailure.isNotEmpty) throw StateError(detailFailure);
    if (emptyDetail) return DramaDetail(drama, []);
    final held = heldDetail;
    heldDetail = null;
    if (held != null) return held.future;
    return previewDetail(drama);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolved.add('${drama.id}:${episode.number}');
    final held = heldResolve;
    heldResolve = null;
    return held == null
        ? PlaybackPlan(url: 'https://example.invalid/video', session: drama.id)
        : held.future;
  }

  @override
  Future<void> release(String session) async {
    released.add(session);
  }
}

DramaDetail previewDetail(Drama item) => DramaDetail(item, [
  Episode({'id': 'one', 'title': '第一集'}, 1),
  Episode({'id': 'two'}, 2),
]);

Future<void> flushPreview() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.value();
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

  test('首集从零、不续历史、不自动下一集、不保存历史', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final item = drama('preview');
    await store.saveWatch(watching(item, episode: 2, position: 40));
    final before = jsonEncode(store.history.map((e) => e.toJson()).toList());
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(item);
    preview.setVisible(true);
    await flushPreview();
    expect(backend.opens, [Duration.zero]);
    expect(repo.resolved, ['${item.id}:1']);
    backend.done.add(true);
    await flushPreview();
    expect(preview.ended, isTrue);
    expect(repo.resolved.length, 1);
    expect(jsonEncode(store.history.map((e) => e.toJson()).toList()), before);
    preview.dispose();
    await flushPreview();
    expect(backend.events.last, 'dispose');
  });

  test('快滑仅一个在途详情，保留最后意图，隐藏拒绝迟到 resolve', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final held = Completer<DramaDetail>();
    repo.heldDetail = held;
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('a'));
    preview.setVisible(true);
    preview.select(drama('b'));
    preview.select(drama('c'));
    expect(repo.requested.length, 1);
    held.complete(previewDetail(drama('a')));
    await flushPreview();
    expect(repo.requested, [drama('a').id, drama('c').id]);
    expect(repo.resolved, ['${drama('c').id}:1']);
    final resolve = Completer<PlaybackPlan>();
    repo.heldResolve = resolve;
    preview.select(drama('d'));
    await flushPreview();
    await preview.suspend();
    resolve.complete(
      const PlaybackPlan(url: 'https://secret.invalid', session: 'late'),
    );
    await flushPreview();
    expect(backend.opens.length, 1);
    expect(backend.playing, isFalse);
    expect(repo.released, contains('late'));
    preview.dispose();
    await flushPreview();
  });

  test('实际 open 串行，过期 open 不 play，dispose 不叠播', () async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend()..heldOpen = Completer<void>();
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('a'));
    preview.setVisible(true);
    await flushPreview();
    preview.select(drama('b'));
    preview.select(drama('c'));
    expect(backend.opens.length, 1);
    backend.heldOpen!.complete();
    backend.heldOpen = null;
    await flushPreview();
    expect(backend.opens.length, 2);
    expect(backend.events.where((e) => e == 'play').length, 1);
    preview.dispose();
    await flushPreview();
    expect(backend.playing, isFalse);
  });

  testWidgets('整宽看全集 push、恢复位置与 TickerMode/lifecycle 停音', (tester) async {
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final visible = ValueNotifier(true);
    DramaDetail? opened;
    Duration? start;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, enabled, _) => TickerMode(
            enabled: enabled,
            child: TheaterPage(
              store: store,
              previewBackend: () => backend,
              onOpenFull: (context, detail, position) async {
                expect(backend.playing, isFalse);
                opened = detail;
                start = position;
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) =>
                        const Scaffold(body: Text('full playback test')),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    backend.position = const Duration(seconds: 12);
    await tester.tap(find.byKey(const ValueKey('theater-open-full')).first);
    await tester.pumpAndSettle();
    expect(opened!.episodes.length, 2);
    final originating = opened!.drama.id;
    // Real playback progress can reshuffle/filter feed candidates while covered.
    await store.saveWatch(watching(opened!.drama, episode: 2, position: 100));
    await tester.pumpAndSettle();
    expect(start, const Duration(seconds: 12));
    Navigator.of(tester.element(find.text('full playback test'))).pop();
    await tester.pumpAndSettle();
    expect(backend.opens.last, const Duration(seconds: 12));
    expect(repo.resolved.last, '$originating:1');
    visible.value = false;
    await tester.pumpAndSettle();
    expect(backend.playing, isFalse);
    visible.value = true;
    await tester.pumpAndSettle();
    expect(backend.playing, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(backend.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(backend.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    visible.dispose();
  });

  test('失败与空剧集可重试，权限撤销和 dispose 拒绝旧详情', () async {
    final store = await openStore();
    final repo = PreviewRepository()
      ..detailFailure = 'https://secret.invalid/token';
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('retry'));
    preview.setVisible(true);
    await flushPreview();
    expect(preview.error, '预览加载失败，请重试');
    expect(backend.opens, isEmpty);
    repo.detailFailure = '';
    repo.emptyDetail = true;
    preview.retry();
    await flushPreview();
    expect(preview.error, isNotNull);
    repo.emptyDetail = false;
    preview.retry();
    await flushPreview();
    expect(backend.playing, isTrue);
    final held = Completer<DramaDetail>();
    repo.heldDetail = held;
    preview.select(drama('late'));
    await flushPreview();
    await store.setSourceEnabled('hongguo', false);
    await flushPreview();
    expect(backend.playing, isFalse);
    preview.dispose();
    held.complete(previewDetail(drama('late')));
    await flushPreview();
    expect(backend.opens.length, 1);
    expect(backend.events.last, 'dispose');
  });

  testWidgets('320 大字体与 TV 上下键切剧/回顶导航', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final entry = FocusNode();
    var exits = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.television,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
        home: TheaterPage(
          store: store,
          entryFocus: entry,
          onExitUp: () => exits++,
          previewBackend: () => backend,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    entry.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(exits, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(backend.opens.length, 2);
    expect(find.byKey(const ValueKey('fake-preview-video')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(backend.opens.last, Duration.zero);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    entry.dispose();
  });

  test('切用户/锁定使预览失效；清空列表丢弃排队意图', () async {
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
        LocalProfile(
          id: 'viewer',
          name: '访客',
          sources: ['hongguo'],
          salt: salt,
          pinHash: pinHash,
        ).toJson(),
      ]),
    });
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(repo, store, backend: () => backend);
    preview.select(drama('first'));
    preview.setVisible(true);
    await flushPreview();
    expect(backend.playing, isTrue);
    await store.switchProfile('viewer', pin: '1234');
    await flushPreview();
    expect(backend.playing, isFalse);
    expect(preview.drama, isNull);
    preview.select(drama('viewer'));
    preview.setVisible(true);
    await flushPreview();
    expect(backend.playing, isTrue);
    store.lock();
    await flushPreview();
    expect(backend.playing, isFalse);
    preview.dispose();
    await flushPreview();

    final secondStore = await openStore();
    final secondRepo = PreviewRepository();
    final held = Completer<DramaDetail>();
    secondRepo.heldDetail = held;
    final secondBackend = FakePreviewBackend();
    final second = TheaterPreview(
      secondRepo,
      secondStore,
      backend: () => secondBackend,
    );
    second.select(drama('a'));
    second.setVisible(true);
    second.select(drama('b'));
    second.select(null);
    held.complete(previewDetail(drama('a')));
    await flushPreview();
    expect(secondRepo.requested.length, 1);
    expect(secondRepo.resolved, isEmpty);
    expect(second.loading, isFalse);
    second.dispose();
    await flushPreview();
  });

  testWidgets('手机320两倍字体，非全集路由覆盖也停止预览', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await openStore();
    final repo = PreviewRepository();
    final backend = FakePreviewBackend();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: repo,
          formFactor: FormFactor.phone,
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
        ),
        home: TheaterPage(store: store, previewBackend: () => backend),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('看全集 · 共2集'), findsOneWidget);
    final navigator = Navigator.of(tester.element(find.byType(TheaterPage)));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('overlay')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(backend.playing, isFalse);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(backend.playing, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
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
      final repo = PreviewRepository();
      final backend = FakePreviewBackend();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) =>
              AppScope(repository: repo, formFactor: form, child: child!),
          home: PreviewBackendScope(
            factory: () => backend,
            child: AppShell(store: store),
          ),
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
      expect(find.text('剧场 · 首集预览'), findsOneWidget);
      expect(find.byType(PageView), findsOneWidget);
      expect(backend.opens, [Duration.zero]);
      expect(backend.playing, isTrue);
      expect(find.byKey(const ValueKey('fake-preview-video')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final requestCount = repo.recommendRequests.length;
      final page = tester.widget<PageView>(find.byType(PageView));
      page.controller!.jumpToPage(1);
      await tester.pumpAndSettle();
      expect(backend.opens.length, 2);
      expect(repo.recommendRequests.length, requestCount);
      await tester.tap(find.byKey(const ValueKey('nav-explore')));
      await tester.pumpAndSettle();
      expect(backend.playing, isFalse);
      await tester.tap(find.byKey(const ValueKey('nav-theater')));
      await tester.pumpAndSettle();
      expect(find.byType(TheaterPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
