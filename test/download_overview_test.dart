import 'dart:async';

import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/widgets.dart';

import 'support/fakes.dart';

DownloadOverview _watch(FakeRepository repository, LocalStore store) {
  final overview = DownloadOverview(
    repository,
    store,
    interval: const Duration(hours: 1),
  );
  addTearDown(overview.dispose);
  return overview;
}

class _PollingRepository extends FakeRepository {
  bool enabled = true;
  bool fail = false;
  Completer<List<DownloadJob>>? pending;

  @override
  bool get supportsDownloads => enabled;

  @override
  Future<List<DownloadJob>> downloads() async {
    downloadRequests++;
    if (pending case final request?) return request.future;
    if (fail) throw StateError('poll failed');
    return jobs ?? const [];
  }
}

void main() {
  final first = drama('a', title: '剧甲');
  final second = drama('b', title: '剧乙');

  test('summarizes running and finished jobs', () async {
    final repository = FakeRepository()
      ..jobs = [
        downloadJob(first, 1, bytes: 300 << 20),
        downloadJob(first, 2, state: 'queued', progress: 0),
        downloadJob(second, 5, state: 'downloading', progress: .45),
      ];
    final overview = _watch(repository, await openStore());
    await pumpEventQueue();

    expect(overview.active, 2);
    expect(overview.current?.drama.id, second.id);
    expect(overview.current?.episode.number, 5);
    expect(overview.completed, 1);
    expect(overview.completedBytes, 300 << 20);
  });

  test('notifies only when the jobs change', () async {
    final repository = FakeRepository()..jobs = [downloadJob(first, 1)];
    final overview = _watch(repository, await openStore());
    var changes = 0;
    overview.addListener(() => changes++);
    await pumpEventQueue();
    await overview.refresh();
    expect(changes, 1);

    repository.jobs = [downloadJob(first, 1, state: 'queued', progress: 0)];
    await overview.refresh();
    expect(changes, 2);
    expect(overview.active, 1);
  });

  test('users without download permission are never polled', () async {
    final repository = FakeRepository()..jobs = [downloadJob(first, 1)];
    final overview = _watch(repository, await openStore(viewerPreferences));
    await pumpEventQueue();

    expect(repository.downloadRequests, 0);
    expect(overview.completed, 0);
  });

  testWidgets('空闲10秒、活动2秒，操作通知立即刷新且读列表不自激', (tester) async {
    final repository = _PollingRepository()..jobs = [];
    final overview = DownloadOverview(repository, await openStore());
    await tester.pump();
    expect(repository.downloadRequests, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(repository.downloadRequests, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(repository.downloadRequests, 2);

    for (final state in ['queued', 'downloading', 'converting', 'removing']) {
      repository.jobs = [downloadJob(first, 1, state: state)];
      final before = repository.downloadRequests;
      repository.downloadChanges.value++;
      await tester.pump();
      expect(repository.downloadRequests, before + 1);
      expect(overview.jobs.single.state, state);
      await tester.pump(const Duration(seconds: 2));
      expect(repository.downloadRequests, before + 2);
    }
    for (final state in ['completed', 'paused', 'failed']) {
      repository.jobs = [downloadJob(first, 1, state: state)];
      repository.downloadChanges.value++;
      await tester.pump();
      final before = repository.downloadRequests;
      await tester.pump(const Duration(seconds: 9));
      expect(repository.downloadRequests, before);
      await tester.pump(const Duration(seconds: 1));
      expect(repository.downloadRequests, before + 1);
    }
    overview.dispose();
  });

  testWidgets('错误按2/4/8/10秒退避，手动刷新和成功后重置', (tester) async {
    final repository = _PollingRepository()..fail = true;
    final overview = DownloadOverview(repository, await openStore());
    await tester.pump();
    for (final delay in [2, 4, 8, 10, 10]) {
      final before = repository.downloadRequests;
      await tester.pump(Duration(seconds: delay - 1));
      expect(repository.downloadRequests, before);
      await tester.pump(const Duration(seconds: 1));
      expect(repository.downloadRequests, before + 1);
    }
    final before = repository.downloadRequests;
    await overview.refresh();
    expect(repository.downloadRequests, before + 1);
    await tester.pump(const Duration(seconds: 2));
    expect(repository.downloadRequests, before + 2);
    repository.fail = false;
    repository.downloadChanges.value++;
    await tester.pump();
    final recovered = repository.downloadRequests;
    await tester.pump(const Duration(seconds: 9));
    expect(repository.downloadRequests, recovered);
    await tester.pump(const Duration(seconds: 1));
    expect(repository.downloadRequests, recovered + 1);
    overview.dispose();
  });

  testWidgets('在途多个操作合并一次后续刷新，刷新Future等到最新快照', (tester) async {
    final pending = Completer<List<DownloadJob>>();
    final repository = _PollingRepository()..pending = pending;
    final overview = DownloadOverview(repository, await openStore());
    await tester.pump();
    final firstRefresh = overview.refresh();
    final secondRefresh = overview.refresh();
    expect(identical(firstRefresh, secondRefresh), isTrue);
    for (var i = 0; i < 5; i++) {
      repository.downloadChanges.value++;
    }
    expect(repository.downloadRequests, 1);
    repository
      ..pending = null
      ..jobs = [downloadJob(first, 1, state: 'queued')];
    pending.complete([]);
    await tester.pump();
    await firstRefresh;
    expect(repository.downloadRequests, 2);
    expect(overview.jobs.single.state, 'queued');
    overview.dispose();
  });

  testWidgets('后台只停定时轮询，显式刷新仍读取最新任务', (tester) async {
    final repository = _PollingRepository()..jobs = [];
    final overview = DownloadOverview(repository, await openStore());
    await tester.pump();
    expect(repository.downloadRequests, 1);

    overview.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 30));
    expect(repository.downloadRequests, 1);

    // 转换收尾依赖显式刷新：后台拿不到最新列表，多集转换就会停住。
    repository.jobs = [downloadJob(first, 1, state: 'converting')];
    await overview.refresh();
    expect(repository.downloadRequests, 2);
    expect(overview.jobs.single.state, 'converting');

    overview.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(repository.downloadRequests, 3);
    overview.didChangeAppLifecycleState(AppLifecycleState.inactive);
    await tester.pump();
    expect(repository.downloadRequests, 3);
    overview.dispose();
  });

  testWidgets('用户切换丢弃旧响应，权限恢复立即刷新', (tester) async {
    final pending = Completer<List<DownloadJob>>();
    final repository = _PollingRepository()..pending = pending;
    final store = await openStore();
    final overview = DownloadOverview(repository, store);
    await tester.pump();
    await store.switchProfile('default');
    repository
      ..pending = null
      ..jobs = [downloadJob(second, 1)];
    pending.complete([downloadJob(first, 1)]);
    await tester.pump();
    expect(repository.downloadRequests, 2);
    expect(overview.jobs.single.drama.id, second.id);
    repository.enabled = false;
    await store.setThemeMode('dark');
    expect(overview.jobs, isEmpty);
    await tester.pump(const Duration(seconds: 30));
    expect(repository.downloadRequests, 2);
    repository.enabled = true;
    await store.setThemeMode('light');
    await tester.pump();
    expect(repository.downloadRequests, 3);
    overview.dispose();
  });

  testWidgets('销毁取消定时器与变更监听，迟到结果不通知', (tester) async {
    final pending = Completer<List<DownloadJob>>();
    final repository = _PollingRepository()..pending = pending;
    final overview = DownloadOverview(repository, await openStore());
    var notifications = 0;
    overview.addListener(() => notifications++);
    await tester.pump();
    overview.dispose();
    pending.complete([downloadJob(first, 1)]);
    await tester.pump();
    repository.downloadChanges.value++;
    await overview.refresh();
    await tester.pump(const Duration(seconds: 30));
    expect(repository.downloadRequests, 1);
    expect(notifications, 0);
    expect(repository.downloadChanges.hasListeners, isFalse);
  });
}
