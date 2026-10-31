import 'dart:convert';

import 'package:duanju_app/live_favorites.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const room = LiveRoom(
  roomId: '123',
  title: '直播',
  anchor: '主播',
  cover: '',
  area: '游戏',
  online: '',
);

void main() {
  test('收藏按平台区分同号房间，切换收藏和重启后保持一致', () async {
    final store = await openStore();
    await store.toggleLiveFavorite('bilibili', room);
    await store.toggleLiveFavorite('douyu', room);
    expect(store.liveFavorites, hasLength(2));
    expect(store.isLiveFavorite('bilibili', '123'), isTrue);
    final restarted = restartStore(store);
    expect(restarted.isLiveFavorite('douyu', '123'), isTrue);
    await restarted.toggleLiveFavorite('bilibili', room);
    expect(restarted.isLiveFavorite('bilibili', '123'), isFalse);
    expect(restarted.isLiveFavorite('douyu', '123'), isTrue);
  });

  test('收藏跟随当前用户隔离，快照认识用户级直播收藏', () async {
    final store = await openStore();
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: ['hongguo'],
      download: true,
      pin: '123456',
    );
    await store.toggleLiveFavorite('huya', room);
    await store.saveProfile(name: '家人', sources: ['hongguo'], download: false);
    final other = store.profiles.firstWhere(
      (profile) => profile.id != 'default',
    );
    await store.switchProfile(other.id);
    expect(store.liveFavorites, isEmpty);
    await store.toggleLiveFavorite('douyu', room);
    await store.switchProfile('default', pin: '123456');
    expect(store.isLiveFavorite('huya', '123'), isTrue);
    expect(store.isLiveFavorite('douyu', '123'), isFalse);
    expect(LocalSnapshot.owns('profile.${other.id}.liveFavorites'), isTrue);
  });

  test('收藏进入备份且不包含播放地址，旧备份没有该字段仍可恢复', () async {
    final store = await openStore();
    await store.toggleLiveFavorite('douyu', room);
    final backup = await store.exportBackup();
    final data = jsonDecode(backup) as Map<String, dynamic>;
    final library = (data['libraries'] as Map)['default'] as Map;
    expect((library['liveFavorites'] as List).length, 1);
    expect(backup.contains('enc_data'), isFalse);
    expect(backup.contains('wsSecret'), isFalse);
    await store.toggleLiveFavorite('douyu', room);
    await store.importBackup(backup);
    expect(store.isLiveFavorite('douyu', '123'), isTrue);
    library.remove('liveFavorites');
    await store.importBackup(jsonEncode(data));
    expect(store.liveFavorites, isEmpty);
  });

  test('重复与无效收藏备份被拒绝', () {
    final value = LiveFavorite(platformId: 'huya', room: room).toJson();
    expect(
      () => LiveFavorite.validateList([value, value]),
      throwsFormatException,
    );
    expect(
      () =>
          LiveFavorite.fromJson({'platform': '../bad', 'room': room.toJson()}),
      throwsFormatException,
    );
    expect(
      () => LiveRoom.fromJson({...room.toJson(), 'roomId': '../bad'}),
      throwsFormatException,
    );
    expect(() => LiveFavorite.validateList(null), returnsNormally);
  });
  test('批量取消收藏只移除所选平台和房间，缓存随写入失效', () async {
    final store = await openStore();
    await store.toggleLiveFavorite('bilibili', room);
    await store.toggleLiveFavorite('douyu', room);
    await store.toggleLiveFavorite('huya', room);
    final cached = store.liveFavorites;
    expect(identical(cached, store.liveFavorites), isTrue);
    await store.removeLiveFavorites({'bilibili:123', 'huya:123'});
    expect(store.liveFavorites.map((entry) => entry.key), ['douyu:123']);
    expect(identical(cached, store.liveFavorites), isFalse);
    expect(restartStore(store).liveFavorites.single.platformId, 'douyu');
  });
}
