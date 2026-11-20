import 'package:duanju_app/download_collections.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/download_view.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Task extends Fake implements MergeTask {
  _Task(this.id, this.drama);
  @override
  final int id;
  @override
  final Drama drama;
  @override
  MergeState state = MergeState.running;
}

void main() {
  final target = drama('target');
  final other = drama('other');
  List<DownloadJob> snapshot(double progress, {String state = 'downloading'}) =>
      [
        for (var i = 0; i < 1000; i++)
          downloadJob(drama('archive-$i'), 1, created: i),
        downloadJob(target, 2, created: 2, bytes: 20),
        downloadJob(drama('target', title: '最新资料'), 1, created: 3, bytes: 10),
        downloadJob(target, 3, state: state, progress: progress),
        downloadJob(other, 1, state: 'downloading', progress: progress),
      ];
  DownloadView view(
    DownloadViewProjection projection,
    List<DownloadJob> jobs,
    int tab,
  ) => projection.project(
    jobs: jobs,
    videos: [],
    tasks: [],
    canDownload: true,
    allowsSource: (_) => true,
    tab: tab,
    selectedSource: '',
    selection: null,
  );

  test('活跃页派生，十次新进度快照不重新分组排序1002条归档', () {
    final projection = DownloadViewProjection();
    final first = snapshot(.1);
    view(projection, first, 0);
    expect(projection.pendingComputations, 1);
    expect(projection.archiveComputations, 0);
    view(projection, first, 1);
    final archive = projection.downloaded;
    expect(projection.archiveComputations, 1);
    for (var i = 0; i < 10; i++) {
      view(projection, snapshot(i / 10), 1);
      expect(projection.downloaded, same(archive));
    }
    expect(projection.archiveComputations, 1);
    expect(projection.pendingComputations, 1);
    view(projection, snapshot(1, state: 'removing'), 1);
    expect(projection.archiveComputations, 1, reason: '徽标变化也不重排归档');
    expect(
      projection.downloaded
          .firstWhere((item) => item.drama.id == target.id)
          .pending,
      0,
    );
    view(projection, snapshot(1, state: 'completed'), 1);
    expect(projection.archiveComputations, 2);
    expect(
      projection.downloaded
          .firstWhere((item) => item.drama.id == target.id)
          .episodes,
      hasLength(3),
    );
  });

  test('单剧只排序目标两集，同身份不扫描，无关进度跨身份仍复用', () {
    final projection = DownloadedDramaProjection();
    final jobs = snapshot(.1);
    final item = projection.project(jobs, target.id)!;
    expect(item.drama.title, '最新资料');
    expect(item.episodes.map((job) => job.episode.number), [1, 2]);
    expect(item.bytes, 30);
    expect(item.pending, 1);
    for (var i = 0; i < 10; i++) {
      expect(projection.project(jobs, target.id), same(item));
    }
    expect(projection.scans, 1);
    for (var i = 0; i < 10; i++) {
      expect(projection.project(snapshot(i / 10), target.id), same(item));
    }
    expect(projection.sorts, 1);
    final removing = projection.project(
      snapshot(.5, state: 'removing'),
      target.id,
    )!;
    expect(removing.pending, 0);
    expect(removing.episodes, same(item.episodes));
    expect(projection.sorts, 1);
    final completed = projection.project(
      snapshot(1, state: 'completed'),
      target.id,
    )!;
    expect(completed.episodes, hasLength(3));
    expect(projection.sorts, 2);
    expect(projection.project(jobs, 'missing'), isNull);
    expect(projection.project(jobs, target.id)?.drama.title, '最新资料');
  });

  test('同一tasks和videos实例原地状态与权限变化立即修正选择', () {
    final task = _Task(1, target);
    final tasks = [task];
    final videos = <MergedVideo>[];
    final projection = DownloadViewProjection();
    var allowed = true;
    var canDownload = true;
    DownloadView current() => projection.project(
      jobs: [],
      videos: videos,
      tasks: tasks,
      canDownload: canDownload,
      allowsSource: (_) => allowed,
      tab: 2,
      selectedSource: 'hongguo',
      selection: {'task:1'},
    );
    expect(current().selection, {'task:1'});
    task.state = MergeState.done;
    expect(current().selection, isEmpty);
    task.state = MergeState.failed;
    expect(current().selection, {'task:1'});
    allowed = false;
    expect(current().source, '');
    expect(current().tasks, isEmpty);
    allowed = true;
    canDownload = false;
    expect(current().tasks, isEmpty);
    expect(projection.archiveComputations, 0);
    expect(projection.pendingComputations, 0);
  });

  test('总览进度只通知目标行，终态/元数据/删除错误立即通知结构', () async {
    final repository = FakeRepository()..jobs = snapshot(.1);
    final store = await openStore();
    final overview = DownloadOverview(
      repository,
      store,
      interval: const Duration(hours: 1),
    );
    addTearDown(overview.dispose);
    await overview.refresh();
    final structural = overview.structureJobs;
    final oldArchive = overview.jobs.first;
    var structures = 0, rows = 0, unrelated = 0, legacy = 0;
    overview.ui.structure.addListener(() => structures++);
    overview.ui.row('${target.id}:3').addListener(() => rows++);
    overview.ui.row(oldArchive.id).addListener(() => unrelated++);
    overview.addListener(() => legacy++);
    for (var i = 2; i <= 6; i++) {
      repository.jobs = snapshot(i / 10);
      await overview.refresh();
      expect(overview.structureJobs, same(structural));
      expect(overview.jobs.first, same(oldArchive));
    }
    expect([structures, rows, unrelated, legacy], [0, 5, 0, 5]);
    expect(overview.jobById('${target.id}:3')?.progress, .6);
    repository.jobs = snapshot(1, state: 'completed');
    await overview.refresh();
    expect(structures, 1);
    expect(overview.completed, 1003);
    repository.jobs = [
      DownloadJob(
        id: 'remove',
        drama: target,
        episode: Episode(const {}, 1),
        state: 'removing',
        error: '被占用',
      ),
    ];
    await overview.refresh();
    expect(structures, 2);
    expect(pendingDownloads(overview.structureJobs).single.error, '被占用');
    repository.jobs = [
      downloadJob(drama('target', title: '重下载资料'), 1, created: 10),
    ];
    await overview.refresh();
    expect(structures, 3);
    expect(overview.jobs.single.created, 10);
    expect(overview.jobs.single.drama.title, '重下载资料');
    await store.switchProfile('default');
    expect(overview.structureJobs, isEmpty, reason: '用户切换同步清理旧结构');
    await overview.refresh();
  });
}
