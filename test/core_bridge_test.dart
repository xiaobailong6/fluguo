import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

List<Future<Object?> Function()> _requests(
  NativeRepository repository,
  Drama drama,
) {
  final episode = Episode({'id': '1'}, 1);
  return [
    () => repository.catalog(drama.source),
    () => repository.cached(drama.source),
    () => repository.categories(drama.source),
    () => repository.detail(drama),
    () => repository.cover(drama),
    () => repository.resolve(drama, episode),
    () => repository.enqueueDownloads(DramaDetail(drama, [episode]), [episode]),
    () => repository.localPlayback(drama, episode),
  ];
}

Matcher _failure(Object message) => throwsA(
  isA<AppFailure>().having((failure) => failure.message, 'message', message),
);

class _QueueWorker implements NativeRequestWorker {
  _QueueWorker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final _dead = Completer<void>();

  @override
  Future<void> get dead => _dead.future;

  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sources outside this edition never reach the native core', () async {
    final repository = NativeRepository(background: true);
    for (final source in [
      ...SourceSite.allValues
          .where((site) => !SourceSite.isAvailable(site.id))
          .map((site) => site.id),
      'unknown',
    ]) {
      for (final request in _requests(repository, drama('1', source: source))) {
        await expectLater(request(), _failure('当前版本不包含此站源'));
      }
    }
  });

  test('a user without the source or downloads is stopped first', () async {
    final store = await openStore({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '只看红果',
          sources: ['hongguo'],
          download: false,
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
    });
    final repository = NativeRepository()..access = store;
    expect(repository.supportsDownloads, isFalse);

    final denied = drama('2', source: 'huangdou');
    for (final request in _requests(repository, denied)) {
      await expectLater(
        request(),
        _failure(allSourcesEnabled ? '当前用户没有此操作权限' : '当前版本不包含此站源'),
      );
    }
    final allowed = drama('1');
    final episode = Episode({'id': '1'}, 1);
    for (final request in [
      () => repository.enqueueDownloads(DramaDetail(allowed, [episode]), [
        episode,
      ]),
      () => repository.localPlayback(allowed, episode),
    ]) {
      await expectLater(request(), _failure('当前用户没有此操作权限'));
    }
    await expectLater(repository.downloads(), _failure('当前用户仅支持在线观看'));
  });

  test('a locked administrator is stopped before any request', () async {
    final store = await openStore({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
      ]),
    });
    expect(store.locked, isTrue);
    final repository = NativeRepository()..access = store;
    await expectLater(repository.catalog('hongguo'), _failure('请先解锁当前用户'));
  });

  for (final previous in ['resolve', 'localPlayback']) {
    test('新本地播放意图淘汰排队的 $previous 请求', () async {
      final blocked = Completer<Map<String, dynamic>>();
      final actions = <Map<String, dynamic>>[];
      final dispatcher = NativeRequestDispatcher(
        () async => _QueueWorker((input) {
          actions.add(input);
          return input['action'] == 'resourceSettings'
              ? blocked.future
              : Future.value({'ok': true, 'data': <String, dynamic>{}});
        }),
        concurrency: 1,
      );
      final repository = NativeRepository(dispatcher: dispatcher);
      final item = drama('queued-playback');
      final firstEpisode = Episode({'id': '1'}, 1);
      final secondEpisode = Episode({'id': '2'}, 2);
      final busy = repository.resourceSettings();
      await pumpEventQueue();
      final old = expectLater(
        previous == 'resolve'
            ? repository.resolve(item, firstEpisode)
            : repository.localPlayback(item, firstEpisode),
        _failure('请求已取消'),
      );
      final latest = repository.localPlayback(item, secondEpisode);
      blocked.complete({'ok': true, 'data': <String, dynamic>{}});
      await busy;
      await old;
      expect(await latest, isNull);
      final played = actions.where(
        (input) => input['action'] != 'resourceSettings',
      );
      expect(played, hasLength(1));
      expect(played.single['action'], 'localPlayback');
      expect(played.single['index'], 2);
      expect(played.single['sequence'], isA<int>());
    });
  }

  test('下载写操作发变更通知，列表读取不通知且部分失败也可核对', () async {
    final item = drama('notify');
    final episode = Episode({'id': '1'}, 1);
    final dispatcher = NativeRequestDispatcher(
      () async => _QueueWorker((input) async {
        final action = input['action'];
        if (action == 'beginConversion') {
          return {'ok': false, 'error': '已恢复完成，无需再次转换'};
        }
        return {
          'ok': true,
          'data': switch (action) {
            'downloads' => {
              'fingerprint': '1',
              'jobs': [
                {
                  'id': 'job-1',
                  'drama': item.toJson(),
                  'chapter': episode.raw,
                  'index': 1,
                  'state': 'completed',
                },
              ],
            },
            'enqueueDownloads' => {'added': 1},
            'controlDownloadBatch' => {
              'completed': ['job-1'],
              'failures': <String, String>{},
            },
            _ => <String, dynamic>{},
          },
        };
      }),
    );
    final repository = NativeRepository(dispatcher: dispatcher);
    var notifications = 0;
    repository.downloadChanges.addListener(() => notifications++);
    await repository.downloads();
    expect(notifications, 0);
    await repository.enqueueDownloads(DramaDetail(item, [episode]), [episode]);
    expect(notifications, 1);
    await repository.updateDownloadCollection(
      DramaDetail(item, [episode]),
      [episode],
    );
    expect(notifications, 2);
    await repository.controlDownloads('pause', id: 'job-1');
    expect(notifications, 3);
    await repository.controlDownloadBatch('archive', ['job-1']);
    expect(notifications, 4);
    await repository.finishConversion('job-1', 'done');
    expect(notifications, 5);
    await repository.moveDownloads('test-target');
    expect(notifications, 6);
    await expectLater(
      repository.beginConversion('job-1'),
      _failure('已恢复完成，无需再次转换'),
    );
    expect(notifications, 7);
    await repository.downloads();
    expect(notifications, 7);
  });
}
