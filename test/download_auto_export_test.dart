import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/app_device.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/download_auto_export.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/fakes.dart';

class _ExportRepository extends FakeRepository {
  final removed = <String>[];
  @override
  Future<PlaybackPlan?> localPlayback(
    Drama drama,
    Episode episode, {
    bool playback = false,
  }) async => const PlaybackPlan(url: '/local/episode.mp4', local: true);
  @override
  Future<void> removeExportedDownload(DownloadJob job) async =>
      removed.add(job.id);
}

class _DelayedExportStorage extends InMemorySharedPreferencesStore {
  _DelayedExportStorage() : super.empty();
  final entered = Completer<void>();
  final release = Completer<bool>();
  bool hold = true;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (hold && key.startsWith('flutter.downloadAutoExport.v1.')) {
      hold = false;
      entered.complete();
      if (!await release.future) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final saved in [true, false]) {
    test('待办落盘期间收到完成快照，落盘成功前不能导出或删除 saved=$saved', () async {
      SharedPreferences.resetStatic();
      final platform = _DelayedExportStorage();
      SharedPreferencesStorePlatform.instance = platform;
      final store = LocalStore(
        await SharedPreferences.getInstance(),
        runWatchBatch: inlineWatchBatch,
      );
      addTearDown(store.dispose);
      await store.setAutoExport(true);
      await store.setDeleteAfterAutoExport(true);
      final job = downloadJob(drama('persist-first'), 1);
      final repository = FakeRepository()..jobs = [];
      final overview = DownloadOverview(repository, store);
      addTearDown(overview.dispose);
      var copies = 0, deletes = 0;
      final exporter = DownloadAutoExporter(
        repository,
        overview,
        supported: true,
        export: (job, delete, check) async {
          check();
          copies++;
          if (delete) deletes++;
        },
      );
      addTearDown(exporter.dispose);
      final queued = expectLater(
        exporter.queue(job),
        saved ? completes : throwsA(isA<AppFailure>()),
      );
      await platform.entered.future;
      repository.jobs = [job];
      await overview.refresh();
      await pumpEventQueue();
      final beforeSaved = (copies, deletes);
      platform.release.complete(saved);
      await queued;
      await pumpEventQueue();
      expect(beforeSaved, (0, 0));
      expect((copies, deletes), saved ? (1, 1) : (0, 0));
      if (!saved) {
        expect(exporter.error, contains('无法保存自动导出待办'));
        await exporter.retry();
        await pumpEventQueue();
        expect((copies, deletes), (1, 1));
        expect(exporter.error, isNull);
      }
    });
  }

  test('旧导出结束不删除重新下载的新待办', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final old = downloadJob(drama('replaced'), 1, created: 1);
    final fresh = downloadJob(old.drama, 1, created: 2);
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    final started = Completer<void>();
    final release = Completer<void>();
    final copies = <int>[];
    final exporter = DownloadAutoExporter(
      repository,
      overview,
      supported: true,
      export: (job, delete, check) async {
        copies.add(job.created);
        if (job.created == 1) {
          started.complete();
          await release.future;
          check();
        }
      },
    );
    addTearDown(exporter.dispose);
    await exporter.queue(old);
    repository.jobs = [old];
    await overview.refresh();
    await started.future;
    repository.jobs = [fresh];
    await overview.refresh();
    await exporter.queue(fresh);
    release.complete();
    await pumpEventQueue();
    expect(copies, [1, 2]);
    expect(exporter.error, isNull);
  });

  test('仅导出开启后登记的任务；完成快照早于待办落盘也不漏跑', () async {
    final store = await openStore();
    final old = downloadJob(drama('old'), 1);
    final fresh = downloadJob(drama('new'), 1);
    final repo = FakeRepository()..jobs = [old, fresh];
    final overview = DownloadOverview(repo, store);
    addTearDown(overview.dispose);
    await overview.refresh();
    final copies = <String>[];
    final exporter = DownloadAutoExporter(
      repo,
      overview,
      supported: true,
      export: (job, _, check) async {
        check();
        copies.add(job.id);
      },
    );
    addTearDown(exporter.dispose);
    await exporter.queue(old);
    await store.setAutoExport(true);
    await pumpEventQueue();
    expect(copies, isEmpty);
    await exporter.queue(fresh);
    await pumpEventQueue();
    expect(copies, [fresh.id]);
    await store.setAutoExport(false);
    await exporter.queue(old);
    await overview.refresh();
    expect(copies, [fresh.id]);
  });

  for (final timing in ['before', 'during', 'keep', 'allow']) {
    test('导出删除同时尊重登记与当前授权 $timing', () async {
      final store = await openStore();
      await store.setAutoExport(true);
      await store.setDeleteAfterAutoExport(timing != 'keep');
      final repository = _ExportRepository()..jobs = [];
      final overview = DownloadOverview(repository, store);
      addTearDown(overview.dispose);
      final exporter = DownloadAutoExporter(
        repository,
        overview,
        supported: true,
      );
      addTearDown(exporter.dispose);
      final copied = Completer<void>();
      final finish = Completer<void>();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var copies = 0;
      messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
        if (call.method == 'requestVideoExport') return true;
        if (call.method == 'exportVideo') {
          copies++;
          copied.complete();
          if (timing == 'during') await finish.future;
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(AppDevice.channel, null),
      );
      final item = drama('delete-preference');
      await exporter.queue(
        downloadJob(item, 1, state: 'converting', created: 1),
      );
      if (timing == 'before') await store.setDeleteAfterAutoExport(false);
      if (timing == 'keep') await store.setDeleteAfterAutoExport(true);
      repository.jobs = [downloadJob(item, 1, created: 1)];
      await overview.refresh();
      await copied.future;
      if (timing == 'during') {
        await store.setDeleteAfterAutoExport(false);
        finish.complete();
      }
      await pumpEventQueue();
      expect(copies, 1);
      expect(
        repository.removed,
        timing == 'allow' ? [repository.jobs!.single.id] : isEmpty,
      );
      expect(exporter.error, isNull);
      expect(
        jsonDecode(
          store.preferences.getString(
            'downloadAutoExport.v1.${store.profile.id}',
          )!,
        ),
        isEmpty,
      );
    });
  }

  test('损坏待办保留原文，重试和新增都不覆盖', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final key = 'downloadAutoExport.v1.${store.profile.id}';
    await store.preferences.setString(key, '{broken');
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    final exporter = DownloadAutoExporter(
      repository,
      overview,
      supported: true,
    );
    addTearDown(exporter.dispose);
    await expectLater(
      exporter.queue(downloadJob(drama('broken'), 1)),
      throwsA(isA<AppFailure>()),
    );
    await exporter.retry();
    expect(store.preferences.getString(key), '{broken');
    expect(exporter.error, contains('原记录已保留'));
  });

  test('自动导出失败保留待办，刷新不循环，用户重试成功后清除', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final job = downloadJob(drama('auto'), 1);
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    var copies = 0;
    var fail = true;
    final exporter = DownloadAutoExporter(
      repository,
      overview,
      supported: true,
      export: (job, delete, check) async {
        copies++;
        check();
        if (fail) throw AppFailure('存储空间不足');
      },
    );
    addTearDown(exporter.dispose);
    await exporter.queue(job);
    repository.jobs = [job];
    await overview.refresh();
    await pumpEventQueue();
    expect(copies, 1);
    expect(exporter.error, contains('存储空间不足'));
    await overview.refresh();
    await pumpEventQueue();
    expect(copies, 1);
    final key = 'downloadAutoExport.v1.${store.profile.id}';
    expect(jsonDecode(store.preferences.getString(key)!) as Map, isNotEmpty);
    fail = false;
    await exporter.retry();
    await pumpEventQueue();
    expect(copies, 2);
    expect(exporter.error, isNull);
    expect(jsonDecode(store.preferences.getString(key)!), isEmpty);
  });

  test('重建后恢复待导出，不自动导出未登记的历史分集', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final job = downloadJob(drama('recover'), 1);
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    final first = DownloadAutoExporter(repository, overview, supported: true);
    await first.queue(job);
    first.dispose();
    var copies = 0;
    final restarted = DownloadAutoExporter(
      repository,
      overview,
      supported: true,
      export: (job, delete, check) async {
        check();
        copies++;
      },
    );
    addTearDown(restarted.dispose);
    repository.jobs = [job, downloadJob(drama('historical'), 1)];
    await overview.refresh();
    await pumpEventQueue();
    expect(copies, 1);
    expect(restarted.error, isNull);
  });

  test('导出期间切换用户，删除前检查拒绝清理内部副本', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final job = downloadJob(drama('switch'), 1);
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    final copied = Completer<void>();
    final release = Completer<void>();
    var deleted = false;
    final exporter = DownloadAutoExporter(
      repository,
      overview,
      supported: true,
      export: (job, delete, check) async {
        copied.complete();
        await release.future;
        check();
        deleted = true;
      },
    );
    addTearDown(exporter.dispose);
    await exporter.queue(job);
    repository.jobs = [job];
    await overview.refresh();
    await copied.future;
    await store.switchProfile(store.profile.id);
    release.complete();
    await pumpEventQueue();
    expect(deleted, isFalse);
    expect(exporter.error, contains('用户或权限已变更'));
  });
}
