import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../scripts/check_local_file_store.dart' as disk;
import 'support/fakes.dart';

void main() {
  test('真实磁盘类别隔离、上一版恢复、中断事务和身份保护', () async {
    await disk.main([Directory.systemTemp.path]);
  });

  test('正式入口迁移旧快照和独立用户键，成功后删除旧键', () async {
    final directory = await Directory.systemTemp.createTemp('migration-test-');
    addTearDown(() => directory.delete(recursive: true));
    final oldPlayback = {
      'speed': 1.5,
      'liveQuality': 150,
      'enhancement': {'mode': 'quality'},
    };
    final values = <String, Object>{
      'profiles': jsonEncode([
        const LocalProfile(id: 'default', name: '管理员', admin: true).toJson(),
      ]),
      'activeProfile': 'default',
      'history': jsonEncode([watching(drama('watched')).toJson()]),
      'favorites': jsonEncode([drama('followed').toJson()]),
      'playback': jsonEncode(oldPlayback),
      'autoExport': true,
      'catalogView': '{"sort":"heat","release":"finished"}',
    };
    SharedPreferences.setMockInitialValues({
      LocalSnapshot.storageKey: jsonEncode({'version': 1, 'values': values}),
      'seriesCandidates.default': jsonEncode([drama('season2').toJson()]),
      'followChecks.default': '{}',
      'unrelatedKey': 'keep',
    });
    final preferences = await SharedPreferences.getInstance();
    final store = await LocalStore.open(preferences, directory);
    addTearDown(store.dispose);
    expect(store.configurationError, isNull);
    expect(store.history.single.drama.id, 'hongguo:watched');
    expect(store.favorites.single.id, 'hongguo:followed');
    expect(store.playbackPreferences.speed, 1.5);
    expect(store.playbackPreferences.liveQuality, 150);
    expect(store.autoExport, isTrue);
    expect(preferences.getString(LocalSnapshot.storageKey), isNull);
    expect(preferences.getString('seriesCandidates.default'), isNull);
    expect(preferences.getString('followChecks.default'), isNull);
    expect(preferences.getString('unrelatedKey'), 'keep');
    expect(store.fileStore!.values.containsKey('catalogView'), isFalse);
    expect(
      jsonDecode(store.fileStore!.values['playback'] as String),
      isNot(contains('enhancement')),
    );
    expect(store.fileStore!.values['seriesCandidates'], contains('season2'));
    await store.saveWatch(watching(drama('watched'), episode: 2));
    final restored = await LocalStore.open(preferences, directory);
    addTearDown(restored.dispose);
    expect(restored.history.single.episode, 2);
    expect(restored.autoExport, isTrue);
    final backup = await store.exportBackup();
    await restored.importBackup(backup);
    expect(restored.favorites.single.id, 'hongguo:followed');
    expect(restored.fileStore!.values['seriesCandidates'], contains('season2'));
  });

  test('旧非用户类别损坏只清空该类，损坏身份不迁移或删除原快照', () async {
    final directory = await Directory.systemTemp.createTemp(
      'migration-corrupt-',
    );
    addTearDown(() => directory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      'history': 'invalid JSON',
      'favorites': jsonEncode([drama('safe').toJson()]),
    });
    final preferences = await SharedPreferences.getInstance();
    final store = await LocalStore.open(preferences, directory);
    addTearDown(store.dispose);
    expect(store.configurationError, isNull);
    expect(store.history, isEmpty);
    expect(store.favorites.single.id, 'hongguo:safe');
    final badDirectory = await Directory.systemTemp.createTemp(
      'identity-corrupt-',
    );
    addTearDown(() => badDirectory.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      LocalSnapshot.storageKey: '{broken',
    });
    final badPreferences = await SharedPreferences.getInstance();
    final blocked = await LocalStore.open(badPreferences, badDirectory);
    addTearDown(blocked.dispose);
    expect(blocked.locked, isTrue);
    expect(badPreferences.getString(LocalSnapshot.storageKey), '{broken');
    expect(await File('${badDirectory.path}/initialized').exists(), isFalse);
  });
}
