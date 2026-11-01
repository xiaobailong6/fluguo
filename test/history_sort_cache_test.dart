import 'package:duanju_app/live_history.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/recent_history.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/history/history_page.dart';
import 'package:duanju_app/ui/widgets/search_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

class _CountingStore extends LocalStore {
  _CountingStore(super.preferences, {super.clock});
  int historyReads = 0;
  int liveReads = 0;
  @override
  List<WatchEntry> get history {
    historyReads++;
    return super.history;
  }

  @override
  List<LiveHistoryEntry> get liveHistory {
    liveReads++;
    return super.liveHistory;
  }
}

const _room = LiveRoom(
  roomId: 'room',
  title: '直播',
  anchor: '主播',
  cover: '',
  area: '',
  online: '',
);

void main() {
  var now = DateTime(2026, 10, 31, 12);
  late _CountingStore store;
  setUp(() async {
    now = DateTime(2026, 10, 31, 12);
    SharedPreferences.setMockInitialValues({});
    store = _CountingStore(
      await SharedPreferences.getInstance(),
      clock: () => now,
    );
    await store.pruneExpiredHistory();
    addTearDown(store.dispose);
  });

  WatchEntry entry(String id, {double position = 10, DateTime? time}) =>
      WatchEntry(
        drama: drama(id, title: '短剧$id'),
        episode: 1,
        position: position,
        duration: 100,
        updatedAt: time ?? now,
      );

  test('排序快照只随完整历史内容变化，类型/搜索和普通设置不使其失效', () async {
    await store.saveWatch(entry('b'));
    await store.saveWatch(entry('a'));
    await store.recordLiveWatch(
      'douyu',
      _room,
      profileEpoch: store.profileEpoch,
    );
    final first = recentHistory(store);
    expect(first.map((e) => e.key), [
      'drama:hongguo:a',
      'drama:hongguo:b',
      'live:douyu:room',
    ]);
    expect(() => first.clear(), throwsUnsupportedError);
    final reads = (store.historyReads, store.liveReads);
    await store.setShowDramaDetails(false);
    expect(identical(recentHistory(store), first), isTrue);
    expect(
      recentHistory(store, kind: HistoryKind.drama).map((e) => e.key),
      first.take(2).map((e) => e.key),
    );
    expect(first.where((e) => e.matches('短剧a')).single.key, 'drama:hongguo:a');
    expect((store.historyReads, store.liveReads), reads);
    await store.saveWatch(entry('a', position: 42));
    final updated = recentHistory(store);
    expect(identical(updated, first), isFalse);
    expect(updated.first.watch!.position, 42);
    await store.removeRecentHistory({
      'live:douyu:room',
    }, profileEpoch: store.profileEpoch);
    expect(recentHistory(store), hasLength(2));
  });

  test('时钟边界、跨日清理、权限、用户及Store身份均隔离', () async {
    await store.saveWatch(
      entry('edge', time: now.subtract(const Duration(days: 30))),
    );
    expect(recentHistory(store), hasLength(1));
    now = now.add(const Duration(microseconds: 1));
    expect(recentHistory(store), isEmpty);
    await store.pruneExpiredHistory(force: true);
    expect(recentHistory(store), isEmpty);
    await store.saveWatch(entry('new'));
    final before = recentHistory(store);
    await store.setSourceEnabled('hongguo', false);
    expect(recentHistory(store), isEmpty);
    await store.setSourceEnabled('hongguo', true);
    expect(recentHistory(store), hasLength(1));
    final cache = RecentHistoryCache();
    final first = cache.read(store);
    final other = _CountingStore(store.preferences, clock: () => now);
    addTearDown(other.dispose);
    expect(identical(cache.read(other), first), isFalse);
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: ['hongguo'],
      download: true,
      pin: '123456',
    );
    await store.saveProfile(name: '家人', sources: ['hongguo'], download: false);
    final profile = store.profiles.firstWhere((p) => p.id != 'default');
    await store.switchProfile(profile.id);
    expect(recentHistory(store), isEmpty);
    await store.switchProfile('default', pin: '123456');
    expect(recentHistory(store).single.key, before.single.key);
    store.lock();
    expect(recentHistory(store), isEmpty);
  });

  testWidgets('页面查询和类型筛选不再读取/排序Store，通知立即刷新可见历史', (tester) async {
    // 在 widget 的模拟时钟内创建写队列，不能复用外层 setUp 的异步链。
    SharedPreferences.setMockInitialValues({});
    final store = _CountingStore(
      await SharedPreferences.getInstance(),
      clock: () => now,
    );
    addTearDown(store.dispose);
    await store.saveWatch(entry('a'));
    await store.recordLiveWatch(
      'douyu',
      _room,
      profileEpoch: store.profileEpoch,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: HistoryPage(store: store),
      ),
    );
    await tester.pumpAndSettle();
    final reads = (store.historyReads, store.liveReads);
    await tester.enterText(find.byType(TextField).first, '短剧');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-kind-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('短剧').last);
    await tester.pumpAndSettle();
    expect((store.historyReads, store.liveReads), reads);
    expect(find.text('短剧a'), findsOneWidget);
    await store.saveWatch(entry('b'));
    await tester.pumpAndSettle();
    expect(find.text('短剧b'), findsOneWidget);
    final beforeExpiryReads = (store.historyReads, store.liveReads);
    now = now.add(const Duration(days: 31));
    await tester.enterText(find.byType(TextField).first, '短');
    await tester.pumpAndSettle();
    final search = tester.widget<SearchField>(find.byType(SearchField).first);
    expect(await search.matches!('短'), isEmpty);
    expect((store.historyReads, store.liveReads), beforeExpiryReads);
    expect(find.text('短剧a'), findsNothing);
    expect(find.text('短剧b'), findsNothing);
    await store.pruneExpiredHistory(force: true);
    await tester.pumpAndSettle();
    expect(find.text('短剧b'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
