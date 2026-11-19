import 'package:duanju_app/download_collections.dart';
import 'package:duanju_app/download_view.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Task extends Fake implements MergeTask {
  _Task(this.id, this.drama, this.state);
  @override
  final int id;
  @override
  final Drama drama;
  @override
  MergeState state;
}

MergedVideo _video(String id, Drama item) => MergedVideo(
  id: id,
  drama: item,
  episodes: [1, 2],
  bytes: 10,
  createdAt: DateTime.utc(2030),
  fileName: '$id.mp4',
);

void main() {
  final first = drama('a');
  final second = drama('b', source: 'fanguo');
  final jobs = [
    downloadJob(first, 2, state: 'paused', created: 3),
    downloadJob(first, 1, created: 1),
    downloadJob(second, 1, state: 'failed', created: 2),
    downloadJob(second, 2, created: 4),
  ];

  test('列表缓存按身份复用，新列表和显式失效重新派生', () {
    final projection = DownloadViewProjection()..derive(jobs);
    final pending = projection.pending;
    final downloaded = projection.downloaded;
    final completed = projection.completed;
    projection.derive(jobs);
    expect(projection.pending, same(pending));
    expect(projection.downloaded, same(downloaded));
    expect(projection.completed, same(completed));
    projection.derive(List.of(jobs));
    expect(projection.pending, isNot(same(pending)));
    expect(
      projection.pending.map((job) => job.id),
      pendingDownloads(jobs).map((job) => job.id),
    );
    final latest = projection.pending;
    projection.invalidate();
    projection.derive(jobs);
    expect(projection.pending, isNot(same(latest)));
  });

  test('下载中按分集选择，已下载按剧集选择且来源失效回全部', () {
    final projection = DownloadViewProjection();
    DownloadView view(int tab, String source) => projection.project(
      jobs: jobs,
      videos: [],
      tasks: [],
      canDownload: true,
      allowsSource: (_) => true,
      tab: tab,
      selectedSource: source,
      selection: {'hongguo:a:2', 'hongguo:a', 'missing'},
    );
    final pending = view(0, 'hongguo');
    expect(pending.pending.map((job) => job.id), ['hongguo:a:2']);
    expect(pending.selectable, {'hongguo:a:2'});
    expect(pending.selection, {'hongguo:a:2'});
    final complete = view(1, 'hongguo');
    expect(complete.selectable, {'hongguo:a'});
    expect(complete.selection, {'hongguo:a'});
    final all = view(1, 'missing-source');
    expect(all.source, '');
    expect(all.downloaded.map((item) => item.drama.id), [
      'fanguo:b',
      'hongguo:a',
    ]);
    expect(all.sources.map((site) => site.id), ['hongguo', 'fanguo']);
  });

  test('合并任务倒序且与成品身份分离，完成任务不再显示', () {
    final tasks = [
      _Task(1, first, MergeState.failed),
      _Task(2, first, MergeState.running),
      _Task(3, second, MergeState.done),
    ];
    final selected = {'task:1', 'task:2', 'task:3', '1'};
    final view = DownloadViewProjection().project(
      jobs: jobs,
      videos: [_video('1', first)],
      tasks: tasks,
      canDownload: true,
      allowsSource: (_) => true,
      tab: 2,
      selectedSource: '',
      selection: selected,
    );
    expect(view.tasks.map((task) => task.id), [2, 1]);
    expect(view.selectable, {'task:1', 'task:2', '1'});
    expect(view.selection, view.selectable);
    expect(selected, {
      'task:1',
      'task:2',
      'task:3',
      '1',
    }, reason: '不修改页面拥有的选择集合');
  });

  test('同一列表下权限与可变任务状态仍即时重算', () {
    final projection = DownloadViewProjection();
    final task = _Task(1, second, MergeState.failed);
    var allowed = true;
    DownloadView view() => projection.project(
      jobs: jobs,
      videos: [_video('f', second)],
      tasks: [task],
      canDownload: true,
      allowsSource: (_) => allowed,
      tab: 2,
      selectedSource: 'fanguo',
      selection: {'task:1', 'f'},
    );
    expect(view().selection, {'task:1', 'f'});
    task.state = MergeState.done;
    expect(view().selection, {'f'});
    allowed = false;
    final denied = view();
    expect(denied.tasks, isEmpty);
    expect(denied.merged, isEmpty);
    expect(denied.sources, isEmpty);
    expect(denied.source, '');
    expect(denied.selection, isEmpty);
  });

  test('非编辑态仍为null，其他页不构建合并任务列表', () {
    final view = DownloadViewProjection().project(
      jobs: jobs,
      videos: [],
      tasks: [_Task(1, first, MergeState.failed)],
      canDownload: true,
      allowsSource: (_) => true,
      tab: 0,
      selectedSource: '',
      selection: null,
    );
    expect(view.selection, isNull);
    expect(view.tasks, isEmpty);
  });
}
