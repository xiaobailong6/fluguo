import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:duanju_app/drama_details.dart';
import 'package:duanju_app/explore_feed.dart';
import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/hongguo_series.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/metadata_publication.dart';
import 'package:duanju_app/metadata_refresh.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/fakes.dart';

class _Platform extends InMemorySharedPreferencesStore {
  _Platform(Map<String, Object> values)
    : super.withData({
        for (final entry in values.entries) 'flutter.${entry.key}': entry.value,
      });
  int writes = 0;
  String failure = '';
  Completer<void>? entered;
  Completer<void>? release;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes++;
    if (key.endsWith(LocalSnapshot.storageKey) && release != null) {
      entered!.complete();
      await release!.future;
      release = null;
    }
    if (failure == 'false') return false;
    if (failure == 'throw') throw StateError('write failed');
    if (failure == 'after') {
      failure = '';
      await super.setValue(type, key, value);
      throw StateError('confirmation failed');
    }
    return super.setValue(type, key, value);
  }
}

class _Store extends LocalStore {
  _Store(super.preferences, MetadataRefreshStats stats)
    : super(metadataRefreshStats: stats, runWatchBatch: inlineWatchBatch);
  int singleCalls = 0;
  @override
  Future<void> refreshDrama(Drama drama) {
    singleCalls++;
    return super.refreshDrama(drama);
  }
}

class _Repository extends FakeRepository {
  final supplement = Completer<Drama?>();
  @override
  Future<Drama?> supplementMetadata(Drama drama) => supplement.future;
  @override
  Future<List<DramaSeason>> seasons(Drama drama) async => const [];
}

Future<({_Store store, _Platform platform, MetadataRefreshStats stats})> _open([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.resetStatic();
  final platform = _Platform(initial);
  SharedPreferencesStorePlatform.instance = platform;
  final stats = MetadataRefreshStats();
  final store = _Store(await SharedPreferences.getInstance(), stats);
  addTearDown(store.dispose);
  await pumpEventQueue();
  platform.writes = 0;
  stats.reset();
  return (store: store, platform: platform, stats: stats);
}

Drama _patch(
  String id, {
  String title = '',
  String description = '',
  int episodes = 0,
  String cover = '',
}) => Drama(
  id: 'hongguo:$id',
  source: 'hongguo',
  title: title,
  description: description,
  episodes: episodes,
  cover: cover,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'field comparison covers every serialized field, including nullable VIP',
    () {
      final item = drama('a');
      final fields = <String, Object>{
        'id': 'hongguo:other',
        'source': 'fanguo',
        'sourceId': 'native-id',
        'title': 'new',
        'description': 'description',
        'cover': 'cover',
        'episodes': 81,
        'category': '爱情',
        'vip': false,
        'heat': '100',
        'views': '200',
        'onlineDate': '2026',
        'score': '9',
        'tags': ['甜宠'],
        'releaseStatus': 'finished',
        'badge': 'new',
      };
      for (final entry in fields.entries) {
        final changed = Drama.fromJson({
          ...item.toJson(),
          entry.key: entry.value,
        });
        expect(sameDramaMetadata(item, changed), isFalse, reason: entry.key);
      }
      expect(sameDramaMetadata(item, Drama.fromJson(item.toJson())), isTrue);
      expect(mergeDramaMetadata(item, _patch('a')), same(item));
    },
  );

  test(
    'batched episode observation matches sequential observe across legacy baselines',
    () {
      for (final savedEpisodes in [0, 20]) {
        for (final before in [
          const FollowState(),
          const FollowState(knownEpisodes: 5),
          const FollowState(knownEpisodes: 20, readEpisodes: 10),
        ]) {
          for (final counts in [
            [0, 10, 30, 20],
            [30, 10, 0],
            [0, 0],
            [10, 0, 40],
          ]) {
            final item = drama('a', episodes: savedEpisodes);
            var expectedDrama = item;
            var expectedState = before;
            final updates = counts
                .map((count) => _patch('a', episodes: count))
                .toList();
            final merged = MetadataUpdate(updates.first, cacheCandidate: false);
            for (final update in updates.skip(1)) {
              merged.add(update, cacheCandidate: false);
            }
            for (final update in updates) {
              expectedDrama = expectedDrama.merge(update);
              expectedState = expectedState.observe(expectedDrama);
            }
            final actual = prepareMetadataRefresh(
              updates: {item.id: merged},
              favorites: {item.id: item},
              history: {},
              states: {item.id: before},
              candidates: {},
            );
            expect(
              (actual.states?[item.id] ?? before).toJson(),
              expectedState.toJson(),
            );
            expect(
              (actual.favorites?[item.id] ?? item).toJson(),
              expectedDrama.toJson(),
            );
          }
        }
      }
    },
  );

  test(
    'file backend persists dirty metadata and candidates without schema changes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'metadata-refresh-',
      );
      addTearDown(() => directory.delete(recursive: true));
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = await LocalStore.open(preferences, directory);
      addTearDown(store.dispose);
      final item = drama('s1', title: '系列第一季');
      await store.toggleFavorite(item);
      await store.saveWatch(watching(item, position: 25));
      await store.refreshDramas([
        _patch('s1', description: 'detail'),
        drama('s2', title: '系列第二季'),
      ]);
      final reopened = await LocalStore.open(preferences, directory);
      addTearDown(reopened.dispose);
      expect(reopened.favorites.single.description, 'detail');
      expect(reopened.watched(item.id)!.position, 25);
      expect(reopened.watched(item.id)!.drama.description, 'detail');
      expect(
        reopened.following(item.id)!.seriesSeasons,
        contains('hongguo:s2'),
      );
      expect(
        reopened.seriesDramasFor(item).map((row) => row.id),
        contains('hongguo:s2'),
      );
      expect(preferences.getString('seriesCandidates.default'), isNull);
    },
  );

  test(
    'metadata commits preserve pending watch progress and latest detail',
    () async {
      final f = await _open();
      final item = drama('a');
      await f.store.toggleFavorite(item);
      await f.store.saveWatch(watching(item, position: 15));
      await f.store.saveWatch(watching(item, position: 45), quiet: true);
      await f.store.refreshDrama(_patch('a', description: 'new metadata'));
      final reopened = restartStore(f.store);
      expect(reopened.watched(item.id)!.position, 45);
      expect(reopened.watched(item.id)!.drama.description, 'new metadata');
    },
  );

  test(
    'refresh scheduled after source enable observes the queued authorization',
    () async {
      final f = await _open();
      await f.store.toggleFavorite(drama('a'));
      await f.store.setSourceEnabled('hongguo', false);
      final enabled = f.store.setSourceEnabled('hongguo', true);
      final update = f.store.refreshDrama(_patch('a', title: 'enabled'));
      await Future.wait([enabled, update]);
      expect(f.store.favorites.single.title, 'enabled');
    },
  );

  test(
    'separate users cannot receive one another\'s queued metadata',
    () async {
      final f = await _open({
        ...viewerPreferences,
        'activeProfile': 'default',
        'forceLogin': false,
      });
      await f.store.toggleFavorite(drama('a', title: 'admin'));
      final adminUpdate = f.store.refreshDrama(
        _patch('a', title: 'admin updated'),
      );
      final switchUser = f.store.switchProfile('viewer');
      final stale = f.store.refreshDrama(_patch('a', title: 'stale admin'));
      await Future.wait([adminUpdate, switchUser, stale]);
      expect(f.store.favorites, isEmpty);
      await f.store.toggleFavorite(drama('a', title: 'viewer'));
      await f.store.refreshDrama(_patch('a', description: 'viewer detail'));
      final values =
          (jsonDecode(f.store.preferences.getString(LocalSnapshot.storageKey)!)
                  as Map)['values']
              as Map;
      expect(
        (jsonDecode(values['favorites']) as List).single['title'],
        'admin updated',
      );
      expect(
        (jsonDecode(values['profile.viewer.favorites']) as List)
            .single['title'],
        'viewer',
      );
    },
  );

  test('deterministic series-index differential cases preserve notice rules', () {
    final random = Random(71);
    for (var sample = 0; sample < 60; sample++) {
      final rows = [
        for (var i = 0; i < 30; i++)
          drama(
            '$i',
            title:
                '故事${random.nextInt(4)}${['', '第一季', '第二季', '第3季', '第十部', '第二部'][random.nextInt(6)]}',
          ),
      ];
      final index = HongguoSeriesIndex(rows);
      for (final anchor in rows) {
        final before = FollowState.initial(anchor);
        final favorites = {anchor.id, rows.first.id};
        final expected = observeHongguoSeriesSeasons(
          anchor: anchor,
          state: before,
          candidates: rows,
          favoriteIds: favorites,
        );
        final actual = observeHongguoSeriesSeasons(
          anchor: anchor,
          state: before,
          candidates: rows,
          favoriteIds: favorites,
          index: index,
        );
        expect(actual.toJson(), expected.toJson());
      }
    }
  });

  test(
    'unchanged refresh: zero copies, encodes, writes and notifications',
    () async {
      final fixture = await _open();
      final item = drama('a');
      await fixture.store.toggleFavorite(item);
      await fixture.store.saveWatch(watching(item));
      await fixture.store.refreshDramas([item]);
      fixture.stats.reset();
      fixture.platform.writes = 0;
      var notifications = 0;
      fixture.store.addListener(() => notifications++);
      await Future.wait([
        fixture.store.refreshDrama(Drama.fromJson(item.toJson())),
        fixture.store.refreshDramas([item, item]),
      ]);
      expect(fixture.stats.batches, 1);
      expect(fixture.stats.dramaIds, 1);
      expect(fixture.stats.mapCopies, 0);
      expect(fixture.stats.encodedGroups, 0);
      expect(fixture.platform.writes, 0);
      expect(notifications, 0);
    },
  );

  test(
    'adjacent duplicate IDs merge later fields and encode only dirty groups',
    () async {
      final f = await _open();
      await f.store.toggleFavorite(drama('a'));
      f.stats.reset();
      f.platform.writes = 0;
      final first = f.store.refreshDrama(
        _patch('a', title: '新名', cover: 'cover'),
      );
      final second = f.store.refreshDrama(_patch('a', description: '补充'));
      expect(identical(first, second), isTrue);
      await second;
      expect(f.store.favorites.single.title, '新名');
      expect(f.store.favorites.single.description, '补充');
      expect(f.store.favorites.single.cover, 'cover');
      expect(f.stats.batches, 1);
      expect(f.stats.dramaIds, 1);
      expect(f.stats.mapCopies, 1);
      expect(f.stats.encodedGroups, 1);
      expect(f.platform.writes, 1);
    },
  );

  test('episode peaks and initial read baseline survive coalescing', () async {
    final f = await _open();
    await f.store.toggleFavorite(drama('a', episodes: 0));
    await Future.wait([
      f.store.refreshDrama(_patch('a', episodes: 10)),
      f.store.refreshDrama(_patch('a', episodes: 30)),
      f.store.refreshDrama(_patch('a', episodes: 20)),
    ]);
    expect(f.store.favorites.single.episodes, 20);
    expect(f.store.following('hongguo:a')?.knownEpisodes, 30);
    expect(f.store.following('hongguo:a')?.readEpisodes, 10);
  });

  test(
    'mark-read is a queue barrier, not moved after a later refresh',
    () async {
      final f = await _open();
      await f.store.toggleFavorite(drama('a', episodes: 10));
      f.stats.reset();
      final first = f.store.refreshDrama(_patch('a', episodes: 20));
      final read = f.store.markUpdatesRead('hongguo:a');
      final last = f.store.refreshDrama(_patch('a', episodes: 30));
      await Future.wait([first, read, last]);
      expect(f.stats.batches, 2);
      expect(f.store.following('hongguo:a')?.newEpisodes, 10);
    },
  );

  test('updates arriving during a write form the next ordered batch', () async {
    final f = await _open();
    await f.store.toggleFavorite(drama('a'));
    f.stats.reset();
    f.platform.entered = Completer<void>();
    final release = f.platform.release = Completer<void>();
    final first = f.store.refreshDrama(_patch('a', title: 'first'));
    await f.platform.entered!.future;
    final second = f.store.refreshDrama(_patch('a', description: 'later'));
    final third = f.store.refreshDrama(_patch('a', title: 'last'));
    release.complete();
    await Future.wait([first, second, third]);
    expect(f.stats.batches, 2);
    expect(f.store.favorites.single.title, 'last');
    expect(f.store.favorites.single.description, 'later');
  });

  test('queued profile switch invalidates old epoch refresh', () async {
    final f = await _open(viewerPreferences);
    await f.store.toggleFavorite(drama('a', title: 'before'));
    final switchUser = f.store.switchProfile('viewer');
    final stale = f.store.refreshDrama(_patch('a', title: 'stale'));
    await Future.wait([switchUser, stale]);
    expect(f.store.favorites.single.title, 'before');
    await f.store.refreshDrama(_patch('a', title: 'current'));
    expect(f.store.favorites.single.title, 'current');
  });

  test('source authorization is rechecked at execution', () async {
    final f = await _open();
    await f.store.toggleFavorite(drama('a'));
    final disable = f.store.setSourceEnabled('hongguo', false);
    final stale = f.store.refreshDrama(_patch('a', title: 'forbidden'));
    await Future.wait([disable, stale]);
    await f.store.setSourceEnabled('hongguo', true);
    expect(f.store.favorites.single.title, 'a');
  });

  for (final failure in ['false', 'throw', 'after']) {
    test(
      '$failure write failure does not poison retry or publish memory',
      () async {
        final f = await _open();
        await f.store.toggleFavorite(drama('a'));
        f.platform.failure = failure;
        await expectLater(
          f.store.refreshDrama(_patch('a', title: 'new')),
          throwsStateError,
        );
        expect(f.store.favorites.single.title, 'a');
        f.platform.failure = '';
        await f.store.refreshDrama(_patch('a', title: 'new'));
        expect(restartStore(f.store).favorites.single.title, 'new');
      },
    );
  }

  test(
    'candidate-only batches respect budget and skip unchanged writes',
    () async {
      final f = await _open();
      final rows = [
        for (var i = 0; i < 2005; i++) drama(i.toString().padLeft(4, '0')),
      ];
      await f.store.refreshDramas(rows);
      expect(
        jsonDecode(f.store.preferences.getString('seriesCandidates.default')!),
        hasLength(2000),
      );
      f.stats.reset();
      f.platform.writes = 0;
      await f.store.refreshDramas(rows);
      expect(f.platform.writes, 0);
      expect(f.stats.encodedGroups, 0);
      f.platform.failure = 'false';
      await expectLater(
        f.store.refreshDramas([_patch('0000', title: 'changed')]),
        throwsStateError,
      );
      f.platform.failure = '';
      await f.store.refreshDramas([_patch('0000', title: 'changed')]);
      expect(f.store.seriesDramasFor(rows.first).first.title, 'changed');
    },
  );

  test(
    'series notices are observed on unchanged input and preserve read status',
    () async {
      final f = await _open();
      final first = drama('s1', title: '故事第一季');
      final second = drama('s2', title: '故事第二季');
      await f.store.toggleFavorite(first);
      await f.store.refreshDramas([second]);
      expect(
        f.store.following(first.id)!.seriesSeasons[second.id]!.read,
        isFalse,
      );
      await f.store.markSeriesSeasonRead(first.id, second.id);
      await f.store.refreshDramas([second]);
      expect(
        f.store.following(first.id)!.seriesSeasons[second.id]!.read,
        isTrue,
      );
      await f.store.toggleFavorite(second);
      await f.store.refreshDrama(first);
      expect(f.store.following(first.id)!.seriesSeasons, isEmpty);
      await f.store.toggleFavorite(second);
      await f.store.refreshDrama(second);
      expect(
        f.store.following(first.id)!.seriesSeasons[second.id]!.read,
        isFalse,
      );
    },
  );

  test(
    'batch series index matches legacy parsing, unit choice and ordering',
    () {
      final rows = [
        drama('base', title: '故事'),
        drama('s2', title: '故事第二季'),
        drama('s3', title: '故事第3季！'),
        drama('b2', title: '故事第二部'),
        drama('other', title: '另一个故事第二季'),
        drama('invalid', title: '故事第201季'),
        drama('foreign', source: 'fanguo', title: '故事第四季'),
      ];
      Object signature(List<HongguoSeriesEntry> entries) => [
        for (final entry in entries)
          (entry.drama.id, entry.drama.title, entry.season, entry.unit),
      ];
      for (final candidates in [
        rows,
        rows.reversed.toList(),
        rows.skip(1).toList(),
      ]) {
        final index = HongguoSeriesIndex(candidates);
        for (final anchor in [...rows, drama('external', title: '故事第一季')]) {
          expect(
            signature(index.entries(anchor)),
            signature(hongguoSeriesEntries(anchor, candidates)),
          );
        }
      }
    },
  );

  test('large unrelated library parses candidates once, never F times C', () {
    final favorites = {
      for (var i = 0; i < 1000; i++)
        'hongguo:$i': drama('$i', title: '故事$i第一季'),
    };
    final states = {
      for (final row in favorites.values) row.id: FollowState.initial(row),
    };
    final stats = MetadataRefreshStats();
    final result = prepareMetadataRefresh(
      updates: {
        for (final row in favorites.values)
          row.id: MetadataUpdate(row, cacheCandidate: false),
      },
      favorites: favorites,
      history: {},
      states: states,
      candidates: {},
      stats: stats,
    );
    expect(stats.parsedCandidates, 1000);
    expect(stats.mapCopies, 0);
    expect(result.favorites, isNull);
    expect(result.states, isNull);
  });

  test(
    'nested catalog publishers are not suppressed by detail ownership',
    () async {
      final f = await _open();
      final repo = _Repository();
      await f.store.toggleFavorite(drama('r1'));
      final explore = ExploreFeed(repo, f.store);
      addTearDown(explore.dispose);
      await pumpEventQueue();
      var nested = false;
      void publishNested() {
        if (nested) return;
        nested = true;
        repo.catalogUpdates.publish(
          _patch('r1', description: 'nested supplement'),
        );
      }

      repo.catalogUpdates.addListener(publishNested);
      addTearDown(() => repo.catalogUpdates.removeListener(publishNested));
      await publishPersistedMetadata(
        repo.catalogUpdates,
        f.store,
        _patch('r1', title: 'owned'),
      );
      await pumpEventQueue();
      expect(f.store.favorites.single.title, 'owned');
      expect(f.store.favorites.single.description, 'nested supplement');
    },
  );

  test(
    'details without explore still persist and discard supplements from old users',
    () async {
      final f = await _open({
        ...viewerPreferences,
        'activeProfile': 'default',
        'forceLogin': false,
      });
      final repo = _Repository();
      final item = drama('a');
      await f.store.toggleFavorite(item);
      repo.details[item.id] = dramaDetail(_patch('a', title: 'detail only'));
      final details = DramaDetails(repo, f.store, item);
      addTearDown(details.dispose);
      await pumpEventQueue();
      expect(f.store.favorites.single.title, 'detail only');
      await f.store.switchProfile('viewer');
      await f.store.toggleFavorite(item);
      repo.supplement.complete(_patch('a', description: 'wrong user'));
      await pumpEventQueue();
      expect(f.store.favorites.single.description, isEmpty);
    },
  );

  test(
    'details owns persistence, supplements survive, other publications still save',
    () async {
      final f = await _open();
      final repo = _Repository();
      final item = drama('r1');
      await f.store.toggleFavorite(item);
      final explore = ExploreFeed(repo, f.store);
      addTearDown(explore.dispose);
      await pumpEventQueue();
      f.store.singleCalls = 0;
      repo.details[item.id] = dramaDetail(_patch('r1', title: 'detail'));
      final details = DramaDetails(repo, f.store, item);
      addTearDown(details.dispose);
      await pumpEventQueue();
      expect(f.store.singleCalls, 1);
      repo.supplement.complete(_patch('r1', description: 'late supplement'));
      await pumpEventQueue();
      expect(f.store.singleCalls, 2);
      expect(f.store.favorites.single.description, 'late supplement');
      repo.catalogUpdates.publish(_patch('r1', title: 'background'));
      await pumpEventQueue();
      expect(f.store.singleCalls, 3);
      expect(f.store.favorites.single.title, 'background');
    },
  );
}
