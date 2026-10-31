import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/live_history.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/local_file_store.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/recent_history.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

LiveRoom room([String id = '123']) => LiveRoom(
  roomId: id,
  title: '直播房间',
  anchor: '测试主播',
  cover: '',
  area: '游戏',
  online: '',
);
Future<void> record(LocalStore store, String platform, [String id = '123']) =>
    store.recordLiveWatch(platform, room(id), profileEpoch: store.profileEpoch);

void main() {
  test('直播历史按平台和房间去重、更新时间，重启及类型筛选保持顺序', () async {
    final store = await openStore();
    await store.saveWatch(watching(drama('123')));
    await record(store, 'bilibili');
    await record(store, 'douyu');
    await record(store, 'bilibili');
    expect(store.liveHistory.map((e) => e.key), ['bilibili:123', 'douyu:123']);
    final restarted = restartStore(store);
    expect(restarted.liveHistory, hasLength(2));
    final mixed = recentHistory(restarted);
    expect(mixed.map((e) => e.key), [
      'live:bilibili:123',
      'live:douyu:123',
      'drama:hongguo:123',
    ]);
    expect(recentHistory(store, kind: HistoryKind.drama), hasLength(1));
    expect(recentHistory(store, kind: HistoryKind.live), hasLength(2));
    expect(mixed.first.matches('CSZB'), isTrue);
  });

  test('历史有界，新房间挤出最旧记录', () async {
    final store = await openStore();
    for (var i = 0; i <= LiveHistoryEntry.limit; i++) {
      await record(store, 'huya', '$i');
    }
    expect(store.liveHistory, hasLength(300));
    expect(store.liveHistory.first.room.roomId, '300');
    expect(store.liveHistory.any((e) => e.room.roomId == '0'), isFalse);
  });

  test('用户切换及过时代次写入/删除不影响新用户，锁定不暴露历史', () async {
    final store = await openStore();
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: ['hongguo'],
      download: true,
      pin: '123456',
    );
    await record(store, 'huya');
    await store.saveProfile(name: '家人', sources: ['hongguo'], download: false);
    final other = store.profiles.firstWhere((p) => p.id != 'default');
    final oldEpoch = store.profileEpoch;
    await store.switchProfile(other.id);
    expect(store.liveHistory, isEmpty);
    await record(store, 'douyu');
    await store.recordLiveWatch('huya', room(), profileEpoch: oldEpoch);
    await store.removeRecentHistory({'live:douyu:123'}, profileEpoch: oldEpoch);
    expect(store.liveHistory.single.platformId, 'douyu');
    expect(LocalSnapshot.owns('profile.${other.id}.liveHistory'), isTrue);
    await store.switchProfile('default', pin: '123456');
    expect(store.liveHistory.single.platformId, 'huya');
    store.lock();
    expect(store.liveHistory, isEmpty);
  });

  test('混合删除在同一事务中按类型和平台精确匹配，不影响续播与收藏', () async {
    final store = await openStore();
    final watch = watching(drama('123'), episode: 7);
    await store.saveWatch(watch);
    await store.toggleLiveFavorite('bilibili', room());
    await record(store, 'bilibili');
    await record(store, 'douyu');
    await store.removeRecentHistory({
      'live:bilibili:123',
    }, profileEpoch: store.profileEpoch);
    expect(store.history.single.episode, 7);
    expect(store.liveHistory.single.platformId, 'douyu');
    expect(store.liveFavorites, hasLength(1));
    await store.removeRecentHistory({
      'drama:${watch.drama.id}',
    }, profileEpoch: store.profileEpoch);
    expect(store.history, isEmpty);
    expect(store.liveHistory, hasLength(1));
  });

  test('备份往返/旧备份兼容，拒绝重复身份、非法时间、敏感字段与损坏用户身份', () async {
    final store = await openStore();
    await record(store, 'douyu');
    final backup = await store.exportBackup();
    final data = jsonDecode(backup) as Map<String, dynamic>;
    final library = (data['libraries'] as Map)['default'] as Map;
    final row = (library['liveHistory'] as List).single as Map;
    expect(row.keys.toSet(), {'platform', 'room', 'updatedAt'});
    expect(backup, isNot(contains('httpHeaders')));
    await store.importBackup(backup);
    expect(store.liveHistory.single.key, 'douyu:123');
    for (final invalid in [
      {...row, 'platform': '../bad'},
      {...row, 'updatedAt': 'bad'},
      {...row, 'url': 'https://signed.invalid'},
      {
        ...row,
        'room': {...row['room'] as Map, 'cookie': 'secret'},
      },
    ]) {
      library['liveHistory'] = [invalid];
      expect(
        () => store.validateBackup(jsonEncode(data)),
        throwsFormatException,
      );
    }
    library['liveHistory'] = [row, row];
    expect(() => store.validateBackup(jsonEncode(data)), throwsFormatException);
    library.remove('liveHistory');
    await store.importBackup(jsonEncode(data));
    expect(store.liveHistory, isEmpty);
    data['profiles'] = [];
    expect(() => store.validateBackup(jsonEncode(data)), throwsFormatException);
  });

  test('真实分文件迁移、备份恢复与重启保留直播历史且不写入aux键', () async {
    final legacy = await openStore();
    await record(legacy, 'huya');
    final directory = await Directory.systemTemp.createTemp('live-history-');
    addTearDown(() => directory.delete(recursive: true));
    final store = await LocalStore.open(legacy.preferences, directory);
    addTearDown(store.dispose);
    expect(store.configurationError, isNull);
    expect(store.liveHistory.single.key, 'huya:123');
    expect(
      LocalFileStore.fileFor('profile.viewer.liveHistory'),
      'profiles/viewer/liveHistory.json',
    );
    expect(
      await File(
        '${directory.path}/profiles/default/liveHistory.json',
      ).exists(),
      isTrue,
    );
    expect(store.preferences.getString(LocalSnapshot.storageKey), isNull);
    await record(store, 'douyu');
    final backup = await store.exportBackup();
    await store.removeRecentHistory({
      'live:huya:123',
      'live:douyu:123',
    }, profileEpoch: store.profileEpoch);
    await store.importBackup(backup);
    final restarted = await LocalStore.open(legacy.preferences, directory);
    addTearDown(restarted.dispose);
    expect(restarted.liveHistory.map((e) => e.key), ['douyu:123', 'huya:123']);
  });
}
