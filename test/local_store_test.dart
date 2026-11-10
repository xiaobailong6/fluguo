import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_file_store.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/theme_color.dart';
import 'package:duanju_app/ui/settings/backup_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/fakes.dart';

class _FailingPlatform extends InMemorySharedPreferencesStore {
  _FailingPlatform(super.data) : super.withData();
  String failure = '';
  int snapshotWrites = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith(LocalSnapshot.storageKey)) {
      snapshotWrites++;
      switch (failure) {
        case 'false':
          return false;
        case 'throw':
          throw StateError('写入失败');
        case 'after':
          failure = '';
          await super.setValue(valueType, key, value);
          throw StateError('写入后确认失败');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

/// 记录真实 worker 返回的对象，检查保存入口没有再编码或复制字节。
class _RecoveryStore extends LocalStore {
  _RecoveryStore(super.preferences);

  Uint8List? exported;

  @override
  Future<Uint8List> exportRecoveryData() async {
    final bytes = await super.exportRecoveryData();
    exported = bytes;
    return bytes;
  }
}

Map<String, Object?> _snapshotValues(LocalStore store) =>
    (jsonDecode(store.preferences.getString(LocalSnapshot.storageKey)!)
            as Map)['values']
        as Map<String, Object?>;

String _snapshot(Map<String, Object> values) => jsonEncode({
  'version': 1,
  'values': {
    'profiles': jsonEncode([
      const LocalProfile(id: 'default', name: '管理员', admin: true).toJson(),
    ]),
    ...values,
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final first = drama('1', title: '旧资料');
  final second = drama('2', title: '新资料');

  group('compatibility', () {
    test('the snapshot recognizes legacy and current library fields', () {
      expect(LocalSnapshot.globalKeys, {
        'profiles',
        'activeProfile',
        'displayMode',
        'themeMode',
        'autoExport',
        'navigationOrder',
        'navigationVisible',
        'exportPosters',
        'sourceSwitches',
        'forceLogin',
      });
      expect(LocalSnapshot.libraryKeys, {
        'history',
        'favorites',
        'liveFavorites',
        'liveHistory',
        'followStates',
        'followChecks',
        'seriesCandidates',
        'mediaHistory',
        'source',
        'hideVip',
        'playback',
        'downloadPreferences',
        'catalogView',
        'recentSearches',
      });
    });

    test('settings added by the rebuild stay outside the snapshot', () async {
      final store = await openStore();
      await store.setFollowSystemColor(false);
      await store.setThemeColor(ThemeColor.teal);
      await store.setSideBarExpanded(false);
      await store.setMiniWindow((left: -12, top: 40, extent: 640));
      await store.setAutoExport(true);
      await store.setDeleteAfterAutoExport(true);
      await store.setDeleteAfterManualExport(true);
      await store.setDisplayMode('pad');
      await store.rememberSearch('剧名');

      final values = _snapshotValues(store);
      expect(values.keys.where((key) => !LocalSnapshot.owns(key)), isEmpty);
      expect(values['displayMode'], 'pad');

      final restarted = restartStore(store);
      expect(restarted.followSystemColor, isFalse);
      expect(restarted.themeColor, ThemeColor.teal);
      expect(restarted.sideBarExpanded, isFalse);
      expect(restarted.miniWindow, (left: -12.0, top: 40.0, extent: 640.0));
      expect(restarted.autoExport, isTrue);
      expect(restarted.deleteAfterAutoExport, isTrue);
      expect(restarted.deleteAfterManualExport, isTrue);
      expect(restarted.displayMode, 'pad');
      expect(restarted.recentSearches, ['剧名']);
    });

    test('records saved before the snapshot load and move into it', () async {
      final store = await openStore({
        'favorites': jsonEncode([first.toJson()]),
        'history': jsonEncode([watching(first, episode: 3).toJson()]),
        'themeMode': 'dark',
        'plugin_secret': 'not-ours',
      });
      expect(store.configurationError, isNull);
      expect(store.favorites.single.id, first.id);
      expect(store.watched(first.id)?.episode, 3);
      expect(store.themeMode, 'dark');

      await store.toggleFavorite(second);
      final values = _snapshotValues(store);
      expect(values['themeMode'], 'dark');
      expect(values, isNot(contains('plugin_secret')));
      final restarted = restartStore(store);
      expect(restarted.favorites.map((item) => item.id), [second.id, first.id]);
      expect(restarted.watched(first.id)?.episode, 3);
    });

    test('values written by other versions fall back to defaults', () async {
      final store = await openStore({
        LocalSnapshot.storageKey: _snapshot({
          'displayMode': 'standard',
          'themeMode': 'sepia',
          'sourceSwitches': 'not json',
          'sourceGateEnabled': false,
          'sourceGateHash': '',
        }),
        'themeColor': 'unknown',
        'miniWindow': '1,2',
      });
      expect(store.configurationError, isNull);
      expect(store.miniWindow, isNull);
      expect(store.playbackPreferences.autoPictureInPicture, isFalse);
      expect(store.displayMode, 'auto');
      expect(store.themeMode, 'system');
      expect(store.themeColor, ThemeColor.orange);
      expect(store.sourceEnabled('hongguo'), isTrue);
      expect(store.sourceEnabled('huangdou'), isFalse);

      await store.setThemeMode('dark');
      expect(_snapshotValues(store).keys, isNot(contains('sourceGateEnabled')));
    });

    for (final (name, records) in [
      (
        'an unknown snapshot field',
        {
          LocalSnapshot.storageKey: _snapshot({
            'favorites': jsonEncode([first.toJson()]),
            'newerFeature': 'on',
          }),
        },
      ),
      (
        'unreadable profiles',
        {
          'profiles': 'broken-json',
          'favorites': jsonEncode([first.toJson()]),
        },
      ),
      (
        'an invalid profile',
        {
          'profiles': jsonEncode([
            {
              'id': 'default',
              'name': '管理员',
              'admin': true,
              'sources': [],
              'salt': 'bad',
            },
          ]),
          'favorites': jsonEncode([first.toJson()]),
        },
      ),
    ]) {
      test('$name locks access and keeps the raw records', () async {
        final store = await openStore(records);
        expect(store.configurationError, isNotNull);
        expect(store.locked, isTrue);
        expect(store.canDownload, isFalse);
        expect(store.favorites, isEmpty);
        expect(store.sources, isEmpty);
        await expectLater(store.switchProfile('default'), throwsStateError);
        await store.toggleFavorite(second);

        for (final entry in records.entries) {
          expect(store.preferences.get(entry.key), entry.value);
        }
        final bytes = await store.exportRecoveryData();
        expect(bytes, isA<Uint8List>());
        final content = utf8.decode(bytes);
        expect(content, contains('旧资料'));
        expect(jsonDecode(content), {
          'app': 'zhenguojian',
          'recovery': true,
          'values': records,
        });
      });
    }
  });

  group('recovery export', () {
    test('正常配置拒绝恢复导出，异步报告资格错误', () async {
      final store = await openStore();
      await expectLater(store.exportRecoveryData(), throwsStateError);
    });

    test('旧 preferences-only 仅导出允许键，保留原文和原始类型快照', () async {
      const raw = ' \r\n{ "values": [损坏快照] }\n';
      final allowed = <String, Object>{
        LocalSnapshot.storageKey: raw,
        'profiles': '{broken',
        'history': <String>['原始', '记录'],
        'hideVip': true,
        'autoExport': 7,
        'navigationOrder': 1.5,
        'profile.viewer.favorites': ' [ 1, 2 ]\r\n',
      };
      final store = await openStore({
        ...allowed,
        'plugin_secret': 'not-ours',
        'themeColor': 'teal',
        'seriesCandidates.default': 'legacy-auxiliary',
        'profile.viewer.unknown': 'not-ours',
      });
      final pending = store.exportRecoveryData();
      await store.preferences.setString('profiles', 'changed-after-snapshot');
      await store.preferences.setStringList('history', ['changed']);
      expect(jsonDecode(utf8.decode(await pending)), {
        'app': 'zhenguojian',
        'recovery': true,
        'values': allowed,
      });
      expect(store.preferences.getString(LocalSnapshot.storageKey), raw);
    });

    test('分文件入口只传路径，保留损坏主文件、bak 和偏好原文', () async {
      final directory = await Directory.systemTemp.createTemp(
        'recovery-store-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final canonical = Directory(await directory.resolveSymbolicLinks());
      const raw = ' \r\n{ "profiles": 损坏 }\n';
      const backup = '{"version":1,"values":{}}\n';
      final original = File('${canonical.path}/users.json');
      final bak = File('${original.path}.bak');
      await original.writeAsString(raw);
      await bak.writeAsString(backup);
      SharedPreferences.setMockInitialValues({
        LocalSnapshot.storageKey: '{legacy',
        'plugin_secret': 'not-ours',
      });
      // 故意在验证器中捕获不可发送对象；导出不应传递 LocalFileStore 本身。
      final port = ReceivePort();
      addTearDown(port.close);
      final files = LocalFileStore(
        canonical,
        validateProfiles: (_) => port.close(),
      )..loadError = const FormatException('损坏');
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        fileStore: files,
      );
      addTearDown(store.dispose);
      expect(jsonDecode(utf8.decode(await store.exportRecoveryData())), {
        'app': 'zhenguojian',
        'recovery': true,
        'values': {LocalSnapshot.storageKey: '{legacy'},
        'files': {'users.json': raw, 'users.json.bak': backup},
      });
      expect(await original.readAsString(), raw);
      expect(await bak.readAsString(), backup);
      expect(await File('${canonical.path}/initialized').exists(), isFalse);
    });

    for (final saved in <String?>[null, 'saved.json']) {
      test('保存回调返回 $saved：取消无成功提示，字节直接交给主 isolate', () async {
        SharedPreferences.setMockInitialValues({'profiles': '{broken'});
        final store = _RecoveryStore(await SharedPreferences.getInstance());
        addTearDown(store.dispose);
        final mainIsolate = Isolate.current;
        var calls = 0;
        final message = await exportRecoveryFile(
          store,
          saveFile: ({
            required fileName,
            required bytes,
            required mimeType,
          }) async {
            calls++;
            expect(Isolate.current.controlPort, mainIsolate.controlPort);
            expect(bytes, same(store.exported));
            expect(fileName, '$appSlug-recovery.json');
            expect(mimeType, 'application/json');
            expect(jsonDecode(utf8.decode(bytes)), {
              'app': 'zhenguojian',
              'recovery': true,
              'values': {'profiles': '{broken'},
            });
            return saved;
          },
        );
        expect(calls, 1);
        expect(message, saved == null ? null : '原始配置已保存');
      });
    }

    test('保存失败上抛，不返回成功提示', () async {
      final store = await openStore({'profiles': '{broken'});
      final failure = FileSystemException('保存失败');
      await expectLater(
        exportRecoveryFile(
          store,
          saveFile: ({
            required fileName,
            required bytes,
            required mimeType,
          }) async {
            throw failure;
          },
        ),
        throwsA(same(failure)),
      );
    });

    test('扫描失败上抛，不调用文件选择器', () async {
      final directory = await Directory.systemTemp.createTemp(
        'recovery-gone-',
      );
      await directory.delete();
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        fileStore: LocalFileStore(directory)
          ..loadError = const FormatException(),
      );
      addTearDown(store.dispose);
      var called = false;
      await expectLater(
        exportRecoveryFile(
          store,
          saveFile: ({
            required fileName,
            required bytes,
            required mimeType,
          }) async {
            called = true;
            return 'unexpected.json';
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(called, isFalse);
    });
  });

  group('failed writes', () {
    Future<LocalStore> launch(
      _FailingPlatform platform, {
      DateTime Function()? clock,
    }) async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = platform;
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        clock: clock ?? () => DateTime(2026, 10, 21),
      );
      addTearDown(store.dispose);
      return store;
    }

    for (final failure in ['false', 'throw', 'after']) {
      test('a "$failure" failure leaves memory and disk unchanged', () async {
        final platform = _FailingPlatform({'flutter.plugin_secret': 'kept'});
        final store = await launch(platform);
        await store.toggleFavorite(first);
        await store.saveWatch(watching(first, position: 15));

        for (final change in <Future<void> Function()>[
          () => store.toggleFavorite(second),
          () => store.clearHistory(),
          () => store.setThemeMode('light'),
          () => store.setPlaybackPreferences(
            const PlaybackPreferences(speed: 2, autoAdvance: false),
          ),
        ]) {
          platform.failure = failure;
          await expectLater(change(), throwsStateError);
          for (final current in [store, await launch(platform)]) {
            expect(current.favorites.map((item) => item.id), [first.id]);
            expect(current.watched(first.id)?.position, 15);
            expect(current.themeMode, 'system');
            expect(current.playbackPreferences.speed, 1);
          }
          expect(store.preferences.getString('plugin_secret'), 'kept');
        }

        platform.failure = '';
        await store.toggleFavorite(second);
        expect((await launch(platform)).favorites, hasLength(2));
      });
    }

    for (final failure in ['false', 'throw', 'after']) {
      for (final retry in ['setting', 'backup']) {
        test('进度写入 $failure 失败后通过 $retry 补存，不丢待保存数据', () async {
          final platform = _FailingPlatform({});
          final store = await launch(platform);
          await store.toggleFavorite(first);
          await store.saveWatch(watching(first, position: 15));
          platform.failure = failure;
          await expectLater(
            store.saveWatch(watching(first, position: 45)),
            throwsStateError,
          );
          expect(store.watched(first.id)?.position, 45);
          final disk =
              jsonDecode(_snapshotValues(store)['history'] as String) as List;
          expect((disk.single as Map)['position'], 15);

          platform.failure = '';
          if (retry == 'setting') {
            await store.setThemeMode('dark');
          } else {
            final backup = jsonDecode(await store.exportBackup()) as Map;
            final library = (backup['libraries'] as Map)['default'] as Map;
            expect(
              ((library['history'] as List).single as Map)['position'],
              45,
            );
          }
          expect((await launch(platform)).watched(first.id)?.position, 45);
        });
      }
    }

    test('导出与重新读取遇到进度落盘失败时报告失败并保留重试数据', () async {
      final platform = _FailingPlatform({});
      final store = await launch(platform);
      await store.saveWatch(watching(first, position: 15));
      platform.failure = 'false';
      await expectLater(
        store.saveWatch(watching(first, position: 45)),
        throwsStateError,
      );
      await expectLater(store.exportBackup(), throwsStateError);
      await expectLater(store.reload(), throwsStateError);
      expect(store.watched(first.id)?.position, 45);
      platform.failure = '';
      await store.reload();
      expect(store.watched(first.id)?.position, 45);
    });

    test('清空历史成功后不恢复先前失败的待保存进度', () async {
      final platform = _FailingPlatform({});
      final store = await launch(platform);
      await store.saveWatch(watching(first, position: 15));
      platform.failure = 'false';
      await expectLater(
        store.saveWatch(watching(first, position: 45)),
        throwsStateError,
      );
      platform.failure = '';
      await store.clearHistory();
      await store.setThemeMode('dark');
      expect(store.history, isEmpty);
      expect((await launch(platform)).history, isEmpty);
    });

    test('写入失败后跨日清理先补存进度，不用旧磁盘记录覆盖新位置', () async {
      final platform = _FailingPlatform({});
      var now = DateTime(2026, 10, 20);
      final store = await launch(platform, clock: () => now);
      WatchEntry progress(Drama item, double position, DateTime updatedAt) =>
          WatchEntry(
            drama: item,
            episode: 1,
            position: position,
            duration: 100,
            updatedAt: updatedAt,
          );
      await store.saveWatch(progress(first, 15, now));
      await store.saveWatch(
        progress(second, 10, now.subtract(const Duration(days: 29))),
      );
      now = now.add(const Duration(days: 2));
      platform.failure = 'false';
      await expectLater(
        store.saveWatch(progress(first, 45, now)),
        throwsStateError,
      );
      await expectLater(store.pruneExpiredHistory(), throwsStateError);
      platform.failure = '';
      await store.pruneExpiredHistory();
      expect(store.history.map((entry) => entry.drama.id), [first.id]);
      expect(store.watched(first.id)?.position, 45);
      final restarted = await launch(platform, clock: () => now);
      expect(restarted.watched(first.id)?.position, 45);
      expect(restarted.watched(second.id), isNull);
    });

    test('a failed backup import keeps every old record', () async {
      final platform = _FailingPlatform({});
      final store = await launch(platform);
      await store.toggleFavorite(first);
      final old = await store.exportBackup();
      final backup = jsonDecode(old) as Map<String, dynamic>;
      ((backup['libraries'] as Map)['default'] as Map)
        ..['favorites'] = [second.toJson()]
        ..['followStates'] = {};
      final content = jsonEncode(backup);

      for (final failure in ['false', 'throw', 'after']) {
        platform.failure = failure;
        await expectLater(store.importBackup(content), throwsStateError);
        expect(await store.exportBackup(), old);
        expect(await (await launch(platform)).exportBackup(), old);
      }

      platform.failure = '';
      final before = platform.snapshotWrites;
      await store.importBackup(content);
      expect(platform.snapshotWrites - before, 1);
      expect((await launch(platform)).favorites.single.id, second.id);
    });
  });

  group('backup', () {
    test('a round trip restores records and theme, nothing else', () async {
      final store = await openStore({'plugin_secret': 'stays-local'});
      await store.toggleFavorite(first);
      await store.saveWatch(watching(first, episode: 2, position: 11));
      await store.setThemeMode('dark');
      await store.setFollowSystemColor(false);
      await store.setThemeColor(ThemeColor.violet);
      final backup = await store.exportBackup();
      expect(backup, isNot(contains('stays-local')));

      await store.toggleFavorite(first);
      await store.clearHistory();
      await store.setThemeMode('light');
      await store.setFollowSystemColor(true);
      await store.setThemeColor(ThemeColor.blue);
      await store.importBackup(backup);

      final restarted = restartStore(store);
      expect(restarted.favorites.single.id, first.id);
      expect(restarted.watched(first.id)?.position, 11);
      expect(restarted.themeMode, 'dark');
      expect(restarted.followSystemColor, isFalse);
      expect(restarted.themeColor, ThemeColor.violet);
      expect(restarted.preferences.getString('plugin_secret'), 'stays-local');
    });

    test('older backups without newer fields still import', () async {
      final store = await openStore();
      await store.toggleFavorite(first);
      final backup = jsonDecode(await store.exportBackup()) as Map;
      for (final key in ['themeMode', 'followSystemColor', 'themeColor']) {
        backup.remove(key);
      }
      final library = (backup['libraries'] as Map)['default'] as Map;
      for (final key in [
        'playback',
        'downloadPreferences',
        'catalogView',
        'recentSearches',
        'seriesCandidates',
      ]) {
        library.remove(key);
      }

      await store.toggleFavorite(first);
      await store.setThemeMode('dark');
      await store.setThemeColor(ThemeColor.rose);
      await store.importBackup(jsonEncode(backup));
      expect(store.favorites.single.id, first.id);
      expect(store.themeMode, 'dark');
      expect(store.themeColor, ThemeColor.rose);
      expect(
        store.playbackPreferences.toJson(),
        const PlaybackPreferences().toJson(),
      );
    });

    test('device link records from older versions are ignored', () async {
      final store = await openStore();
      await store.toggleFavorite(first);
      final backup = jsonDecode(await store.exportBackup()) as Map;
      final library = (backup['libraries'] as Map)['default'] as Map;
      expect(library, isNot(contains('followSync')));
      library['followSync'] = [
        {'id': 'broken'},
      ];

      await store.toggleFavorite(first);
      await store.importBackup(jsonEncode(backup));
      expect(store.favorites.single.id, first.id);
      expect(_snapshotValues(store).keys, isNot(contains('lanRecords')));
    });

    for (final (name, change) in <(String, void Function(Map))>[
      ('another app', (data) => data['app'] = 'other'),
      ('an unknown theme mode', (data) => data['themeMode'] = 'sepia'),
      ('an unknown theme color', (data) => data['themeColor'] = 'gold'),
      (
        'a profile id with a path',
        (data) => (data['profiles'] as List).add({
          'id': '../escape',
          'name': '坏数据',
          'admin': false,
          'sources': [],
        }),
      ),
    ]) {
      test('a backup from $name is rejected before anything changes', () async {
        final store = await openStore();
        await store.toggleFavorite(first);
        final old = await store.exportBackup();
        final data = jsonDecode(old) as Map;
        change(data);
        await expectLater(
          store.importBackup(jsonEncode(data)),
          throwsA(anything),
        );
        expect(await store.exportBackup(), old);
      });
    }
  });

  group('follows', () {
    test('three-state records from older versions still load', () async {
      final store = await openStore({
        LocalSnapshot.storageKey: _snapshot({
          'favorites': jsonEncode([first.toJson(), second.toJson()]),
          'followStates': jsonEncode({
            first.id: {
              'status': 'watched',
              'manuallyWatched': true,
              'knownEpisodes': 90,
              'readEpisodes': 80,
            },
            second.id: {
              'status': 'planned',
              'manuallyWatched': false,
              'knownEpisodes': 80,
              'readEpisodes': 80,
            },
          }),
          'lanRecords': '{}',
          'profile.viewer.lanSettings': '{}',
        }),
      });
      expect(store.configurationError, isNull);
      expect(store.following(first.id)?.newEpisodes, 10);
      expect(store.following(second.id)?.hasUpdates, isFalse);

      await store.markUpdatesRead(first.id);
      final values = _snapshotValues(store);
      expect(values.keys.where((key) => key.contains('lan')), isEmpty);
      final states = jsonDecode(values['followStates'] as String) as Map;
      expect(states[first.id], {'knownEpisodes': 90, 'readEpisodes': 90});
      expect(restartStore(store).following(first.id)?.hasUpdates, isFalse);
    });

    test('new episodes stay marked until read, not until watched', () async {
      final store = await openStore();
      await store.toggleFavorite(first);
      expect(store.following(first.id)?.hasUpdates, isFalse);

      await store.refreshDrama(drama('1', title: '旧资料', episodes: 86));
      expect(store.following(first.id)?.newEpisodes, 6);
      await store.saveWatch(watching(first, episode: 86));
      expect(store.following(first.id)?.newEpisodes, 6);

      await store.markUpdatesRead(first.id);
      expect(store.following(first.id)?.hasUpdates, isFalse);
      await store.refreshDrama(drama('1', title: '旧资料', episodes: 80));
      expect(store.following(first.id)?.hasUpdates, isFalse);
    });

    test('unfollowing skips switched-off sources and keeps them', () async {
      final store = await openStore();
      final third = drama('3', title: '第三部');
      for (final item in [first, second, third]) {
        await store.toggleFavorite(item);
      }
      await store.saveWatch(watching(first));
      await store.setSourceEnabled('hongguo', false);
      await store.removeFavorites({first.id});
      await store.setSourceEnabled('hongguo', true);
      expect(store.favorites, hasLength(3));

      await store.removeFavorites({first.id, third.id, 'hongguo:missing'});
      expect(store.favorites.map((item) => item.id), [second.id]);
      expect(store.following(first.id), isNull);
      expect(store.watched(first.id), isNotNull);
      expect(restartStore(store).favorites.single.id, second.id);
    });
  });

  group('history', () {
    test(
      'removing entries skips switched-off sources and keeps them',
      () async {
        final store = await openStore();
        final third = drama('3', title: '第三部');
        for (final item in [first, second, third]) {
          await store.saveWatch(watching(item));
        }
        await store.setSourceEnabled('hongguo', false);
        await store.removeHistory({first.id});
        await store.setSourceEnabled('hongguo', true);
        expect(store.history, hasLength(3));

        await store.removeHistory({first.id, third.id, 'hongguo:missing'});
        expect(store.history.map((entry) => entry.drama.id), [second.id]);
        expect(restartStore(store).history.single.drama.id, second.id);
      },
    );
  });
}
