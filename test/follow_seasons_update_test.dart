import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/follow_updater.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _anchor = Drama(
  id: 'hongguo:101',
  source: 'hongguo',
  title: '第一季',
  episodes: 80,
  releaseStatus: 'finished',
);
final _second = drama('202', title: '第二季');
final _third = drama('303', title: '第三季');
List<DramaSeason> _rows([List<Drama> extra = const []]) => [
  const DramaSeason(number: 7, drama: _anchor),
  for (var i = 0; i < extra.length; i++)
    DramaSeason(number: i + 2, drama: extra[i]),
];

class _Repository extends FakeRepository {
  int seasonRequests = 0;
  List<DramaSeason> rows = _rows();
  Completer<List<DramaSeason>>? pending;
  @override
  Future<List<DramaSeason>> followSeasons(Drama drama) async {
    seasonRequests++;
    return pending?.future ?? rows;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('首次官方检查建立基线，按官方顺序提醒后续已上线季，不依赖季号大小', () {
    FollowState observe(FollowState state, List<DramaSeason> rows) =>
        state.observeSeasons(
          anchor: _anchor,
          seasons: rows,
          favoriteIds: {_anchor.id},
          watchedIds: {},
        );
    var state = observe(FollowState.initial(_anchor), _rows([_second]));
    expect(state.seasonsSeeded, isTrue);
    expect(state.hasUpdates, isFalse);
    state = observe(state, _rows([_second, _third]));
    expect(state.unreadSeasons.single.id, _third.id);
    expect(state.updateBadge, '第3季已上线');
    state = state.observe(drama('101', episodes: 90));
    expect(state.updateBadge, '10 集更新 · 第3季已上线');
    expect(state.markRead().hasUpdates, isFalse);
  });

  test('空列表可建立基线，未来上线日期与未上线状态不会提前通知', () {
    final seed = FollowState.initial(_anchor).observeSeasons(
      anchor: _anchor,
      seasons: [],
      favoriteIds: {},
      watchedIds: {},
    );
    FollowState observe(Drama next, DateTime now) => seed.observeSeasons(
      anchor: _anchor,
      seasons: _rows([next]),
      favoriteIds: {},
      watchedIds: {},
      now: now,
    );
    const scheduled = Drama(
      id: 'hongguo:202',
      source: 'hongguo',
      title: '待上线',
      episodes: 80,
      onlineDate: '2030-02-02',
    );
    expect(observe(scheduled, DateTime(2030, 2, 1)).hasUpdates, isFalse);
    expect(observe(scheduled, DateTime(2030, 2, 2)).hasUpdates, isTrue);
    const dated = Drama(
      id: 'hongguo:202',
      source: 'hongguo',
      title: '已上线',
      onlineDate: '2030-02-01',
    );
    expect(observe(dated, DateTime(2030, 2, 2)).hasUpdates, isTrue);
    expect(
      observe(drama('202', episodes: 0), DateTime(2030)).hasUpdates,
      isFalse,
    );
  });

  test('旧标题推断不变成官方提醒；不相关、异源或无效季数拒绝建立基线', () {
    const legacy = FollowState(
      seriesSeasons: {
        'hongguo:202': SeriesSeasonNotice(
          id: 'hongguo:202',
          title: '同名第二季',
          season: 2,
          unit: '季',
        ),
      },
    );
    expect(legacy.hasUpdates, isFalse);
    expect(
      legacy
          .observeSeasons(
            anchor: _anchor,
            seasons: _rows(),
            favoriteIds: {},
            watchedIds: {},
          )
          .seriesSeasons,
      isEmpty,
    );
    for (final rows in [
      [DramaSeason(number: 1, drama: _second)],
      [DramaSeason(number: 1, drama: drama('101', source: 'huangdou'))],
      [
        const DramaSeason(number: 7, drama: _anchor),
        DramaSeason(number: 201, drama: _second),
      ],
    ]) {
      expect(
        () => legacy.observeSeasons(
          anchor: _anchor,
          seasons: rows,
          favoriteIds: {},
          watchedIds: {},
        ),
        throwsFormatException,
      );
    }
  });

  test('暂缺关联后重现不重复提醒；观看和追剧消除提醒且持久化', () async {
    final store = await openStore();
    await store.toggleFavorite(_anchor);
    Future<void> observe(List<DramaSeason> rows) =>
        store.observeFollowSeasonsBatch({
          _anchor.id: rows,
        }, epoch: store.profileEpoch);
    await observe(_rows());
    await observe(_rows([_second, _third]));
    expect(store.following(_anchor.id)!.unreadSeasons, hasLength(2));
    await store.saveWatch(watching(_second));
    expect(store.following(_anchor.id)!.unreadSeasons.single.id, _third.id);
    await store.toggleFavorite(_third);
    expect(store.following(_anchor.id)!.hasUpdates, isFalse);
    await store.toggleFavorite(_third);
    await observe([]);
    await observe(_rows([_second, _third]));
    final restarted = restartStore(store);
    expect(restarted.following(_anchor.id)!.hasUpdates, isFalse);
    expect(restarted.following(_anchor.id)!.seriesSeasons, hasLength(2));
    final backup = await store.exportBackup();
    await restarted.importBackup(backup);
    expect(restarted.following(_anchor.id)!.seasonsSeeded, isTrue);
    expect(restarted.following(_anchor.id)!.hasUpdates, isFalse);
  });

  test('已完结作品独立检查新季，按天限频并显示提醒', () async {
    final store = await openStore();
    await store.toggleFavorite(_anchor);
    final repository = _Repository();
    var now = DateTime(2026, 11, 28);
    final updater = FollowUpdater(repository, store, clock: () => now);
    addTearDown(updater.dispose);
    await updater.run();
    expect(repository.detailRequests, 0);
    expect(repository.seasonRequests, 1);
    expect(store.following(_anchor.id)!.seasonsSeeded, isTrue);
    repository.rows = _rows([_second]);
    await updater.run();
    expect(repository.seasonRequests, 1);
    now = now.add(const Duration(days: 1));
    await updater.run();
    expect(store.following(_anchor.id)!.unreadSeasons.single.id, _second.id);
    await store.markUpdatesRead(_anchor.id);
    expect(store.following(_anchor.id)!.hasUpdates, isFalse);
    expect(restartStore(store).followChecks[_anchor.id]!.seasonsCheckedAt, now);
  });

  test('无效官方响应按失败退避，不抹掉已存基线与通知', () async {
    final store = await openStore();
    await store.toggleFavorite(_anchor);
    final repository = _Repository()
      ..rows = [DramaSeason(number: 2, drama: _second)];
    var now = DateTime(2026, 11, 28);
    final updater = FollowUpdater(repository, store, clock: () => now);
    addTearDown(updater.dispose);
    await updater.run();
    expect(store.following(_anchor.id)!.seasonsSeeded, isFalse);
    expect(store.followChecks[_anchor.id]!.seasonFailures, 1);
    now = now.add(const Duration(days: 1));
    await updater.run();
    expect(repository.seasonRequests, 1);
    repository.rows = _rows();
    now = now.add(const Duration(days: 1));
    await updater.run();
    expect(repository.seasonRequests, 2);
    expect(store.followChecks[_anchor.id]!.seasonFailures, 0);
    expect(store.following(_anchor.id)!.seasonsSeeded, isTrue);
  });

  for (final change in ['unfollow', 'source', 'profile']) {
    test('检查中 $change 后丢弃旧响应', () async {
      final store = await openStore(
        change == 'profile'
            ? {
                ...viewerPreferences,
                'profiles': jsonEncode([
                  ...jsonDecode(viewerPreferences['profiles'] as String)
                      as List,
                  const LocalProfile(
                    id: 'other',
                    name: '另一用户',
                    sources: ['hongguo'],
                  ).toJson(),
                ]),
              }
            : {},
      );
      await store.toggleFavorite(_anchor);
      final repository = _Repository()
        ..pending = Completer<List<DramaSeason>>();
      final updater = FollowUpdater(repository, store);
      addTearDown(updater.dispose);
      final running = updater.run();
      await pumpEventQueue();
      switch (change) {
        case 'unfollow':
          await store.toggleFavorite(_anchor);
        case 'source':
          await store.setSourceEnabled('hongguo', false);
        case 'profile':
          await store.switchProfile('other');
      }
      repository.pending!.complete(_rows([_second]));
      await running;
      expect(store.following(_anchor.id), isNull);
    });
  }

  test('旧追剧检查记录兼容，四字段保留两种检查各自退避', () {
    final old = FollowCheck.fromJson([123, 2]);
    expect(old.seasonsCheckedAt, isNull);
    final updated = old.withSeasons(
      DateTime.fromMillisecondsSinceEpoch(456),
      failures: 3,
    );
    final restored = FollowCheck.fromJson(jsonDecode(jsonEncode(updated)));
    expect(restored.toJson(), [123, 2, 456, 3]);
    expect(
      restored.withDetail(DateTime.fromMillisecondsSinceEpoch(789)).toJson(),
      [789, 0, 456, 3],
    );
  });
}
