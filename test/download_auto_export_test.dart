import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/download_auto_export.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      repository, overview, supported: true,
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

  test('损坏待办保留原文，重试和新增都不覆盖', () async {
    final store = await openStore();
    await store.setAutoExport(true);
    final key = 'downloadAutoExport.v1.${store.profile.id}';
    await store.preferences.setString(key, '{broken');
    final repository = FakeRepository()..jobs = [];
    final overview = DownloadOverview(repository, store);
    addTearDown(overview.dispose);
    final exporter = DownloadAutoExporter(repository, overview, supported: true);
    addTearDown(exporter.dispose);
    await expectLater(exporter.queue(downloadJob(drama('broken'), 1)),
      throwsA(isA<AppFailure>()));
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
