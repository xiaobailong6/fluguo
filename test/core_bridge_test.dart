import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/diary_service.dart';
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
    () => repository.seasons(drama),
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

  Map<String, dynamic> downloadRow(String id, {double progress = 0}) => {
    'id': id,
    'drama': drama(id).toJson(),
    'chapter': <String, dynamic>{},
    'index': 1,
    'state': 'downloading',
    'progress': progress,
  };

  test('下载增量串行应用，复用未变化模型，权限变化重新过滤', () async {
    final store = await openStore();
    final first = Completer<Map<String, dynamic>>();
    final calls = <Map<String, dynamic>>[];
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _QueueWorker((input) {
          calls.add(input);
          if (calls.length == 1) return first.future;
          return Future.value({
            'ok': true,
            'data': calls.length == 2
                ? {
                    'fingerprint': 'v2',
                    'base': 'v1',
                    'changed': [downloadRow('a', progress: .5)],
                    'removed': [],
                  }
                : {'fingerprint': 'v2'},
          });
        }),
      ),
    )..access = store;
    final a = repository.downloads();
    final b = repository.downloads();
    await pumpEventQueue();
    expect(calls, hasLength(1));
    first.complete({
      'ok': true,
      'data': {
        'fingerprint': 'v1',
        'jobs': [downloadRow('a'), downloadRow('b')],
      },
    });
    final before = await a;
    final after = await b;
    expect(calls[1]['since'], 'v1');
    expect(calls.every((input) => input['delta'] == true), isTrue);
    expect(after.first.progress, .5);
    expect(after.last, same(before.last));
    expect(await repository.downloads(), same(after));
    await store.setSourceEnabled('hongguo', false);
    expect(await repository.downloads(), isEmpty);
    await store.setSourceEnabled('hongguo', true);
    expect((await repository.downloads()).last, same(after.last));
  });

  test('下载游标不匹配自动全量恢复，兼容旧核心快照', () async {
    var reads = 0;
    final since = <Object?>[];
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _QueueWorker((input) async {
          since.add(input['since']);
          final data = switch (++reads) {
            1 => {
              'fingerprint': 'legacy',
              'jobs': [downloadRow('old')],
            },
            2 => {
              'fingerprint': 'new',
              'base': 'wrong',
              'changed': [],
              'removed': ['old'],
            },
            _ => {
              'fingerprint': 'new',
              'jobs': [downloadRow('new')],
            },
          };
          return {'ok': true, 'data': data};
        }),
      ),
    );
    expect((await repository.downloads()).single.id, 'old');
    expect((await repository.downloads()).single.id, 'new');
    expect(since, ['', 'legacy', '']);
  });

  test('下载同步失败不阻断后续读取', () async {
    var reads = 0;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _QueueWorker(
          (input) async => ++reads == 1
              ? {'ok': false, 'error': '读取失败'}
              : {
                  'ok': true,
                  'data': {
                    'fingerprint': 'ok',
                    'jobs': [downloadRow('ok')],
                  },
                },
        ),
      ),
    );
    await expectLater(repository.downloads(), _failure('读取失败'));
    expect((await repository.downloads()).single.id, 'ok');
  });

  tearDown(() {
    DiaryService.traceEnabled = false;
  });

  test('原生日志设置读取和保存成功后同步媒体调试开关', () async {
    var enabled = true;
    var saveFails = false;
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _QueueWorker((input) async {
          if (input['action'] == 'saveResourceSettings') {
            if (saveFails) return {'ok': false, 'error': '保存失败'};
            enabled = (input['settings'] as Map)['traceEnabled'] == true;
          }
          return {
            'ok': true,
            'data': {'traceEnabled': enabled},
          };
        }),
      ),
    );
    DiaryService.traceEnabled = false;
    final settings = await repository.resourceSettings();
    expect(DiaryService.traceEnabled, isTrue);
    saveFails = true;
    await expectLater(
      repository.saveResourceSettings(settings.copyWith(traceEnabled: false)),
      throwsA(isA<AppFailure>()),
    );
    expect(DiaryService.traceEnabled, isTrue);
    saveFails = false;
    await repository.saveResourceSettings(
      settings.copyWith(traceEnabled: false),
    );
    expect(DiaryService.traceEnabled, isFalse);
  });

  test('导出清理向原生传递预期任务身份', () async {
    final calls = <Map<String, dynamic>>[];
    final repository = NativeRepository(
      dispatcher: NativeRequestDispatcher(
        () async => _QueueWorker((input) async {
          calls.add(input);
          return {'ok': true, 'data': <String, dynamic>{}};
        }),
      ),
    );
    final job = DownloadJob(
      id: 'hongguo:identity:1',
      drama: drama('identity'),
      episode: Episode(const {}, 1),
      state: 'completed',
      created: 100,
      revision: 2,
    );
    await repository.removeExportedDownload(job);
    expect(calls.single['action'], 'controlDownloads');
    expect(calls.single['command'], 'remove');
    expect(calls.single['downloadIdentity'], {'created': 100, 'revision': 2});
  });

  test('开始转换已在原生执行后切用户，失效响应会配对释放占用', () async {
    final store = await openStore();
    final started = Completer<Map<String, dynamic>>();
    final calls = <Map<String, dynamic>>[];
    final dispatcher = NativeRequestDispatcher(
      () async => _QueueWorker((input) {
        calls.add(input);
        if (input['action'] == 'beginConversion') return started.future;
        return Future.value({'ok': true, 'data': <String, dynamic>{}});
      }),
      concurrency: 1,
    );
    final repository = NativeRepository(dispatcher: dispatcher)..access = store;
    final result = expectLater(
      repository.beginConversion('job-1'),
      _failure('用户已切换，请重新操作'),
    );
    await pumpEventQueue();
    expect(calls.single['action'], 'beginConversion');
    await store.switchProfile(store.profile.id);
    started.complete({
      'ok': true,
      'data': {'input': '/raw.mp4', 'output': '/out.mp4', 'key': ''},
    });
    await result;
    expect(calls, hasLength(2));
    expect(calls.last['action'], 'finishConversion');
    expect(calls.last['jobId'], 'job-1');
    expect(calls.last['command'], 'cancel');
  });
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
            : repository.localPlayback(item, firstEpisode, playback: true),
        _failure('请求已取消'),
      );
      final latest = repository.localPlayback(
        item,
        secondEpisode,
        playback: true,
      );
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
    await repository.updateDownloadCollection(DramaDetail(item, [episode]), [
      episode,
    ]);
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
