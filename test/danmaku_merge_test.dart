import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

/// 只关心“同一页里怎么合并”，因此固定返回一份合成条目，不做真实请求。
class _MergeRepository extends FakeRepository {
  _MergeRepository(this.items);
  final List<DanmakuItem> items;
  int requests = 0;

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    requests++;
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: durationMs,
      items: items,
    );
  }

  @override
  Future<void> cancelDanmaku() async {}
}

const _plan = PlaybackPlan(
  url: 'https://media.example.test/synthetic.mp4',
  session: 'current',
  danmakuId: '1001',
);

List<DanmakuItem> _source() => [
  DanmakuItem(id: 'a1', text: '一样', timeMs: 0),
  DanmakuItem(id: 'a1', text: '一样', timeMs: 0),
  DanmakuItem(id: 'b1', text: '别的', timeMs: 5000),
  DanmakuItem(id: 'a2', text: '一样', timeMs: 9000),
  DanmakuItem(id: 'a3', text: '一样', timeMs: 10000),
];

Future<DanmakuController> _open(
  _MergeRepository repository, {
  DanmakuMerge merge = DanmakuMerge.off,
}) async {
  final controller = DanmakuController(repository)
    ..setMergeWindow(merge)
    ..setPlan(_plan);
  addTearDown(controller.dispose);
  controller.update(
    position: Duration.zero,
    duration: const Duration(seconds: 180),
    speed: 1,
    playing: true,
    buffering: false,
    foreground: true,
    available: true,
  );
  for (var i = 0; i < 8; i++) {
    await Future<void>.value();
  }
  return controller;
}

void main() {
  test('关闭时不合并，仍按原 ID 去重', () async {
    final repository = _MergeRepository(_source());
    final controller = await _open(repository);
    expect(repository.requests, 1);
    expect(controller.items.map((item) => item.id), ['a1', 'b1', 'a2', 'a3']);
    expect(controller.items.map((item) => item.count), [1, 1, 1, 1]);
  });

  test('窗口按首条时间固定计算，恰好到边界另开一组', () async {
    final repository = _MergeRepository(_source());
    final controller = await _open(repository, merge: DanmakuMerge.ten);
    // a1/a2 相差 9 秒并入同组；a3 与组首相差 10 秒另起一组。
    expect(controller.items.map((item) => item.id), ['a1', 'b1', 'a3']);
    expect(controller.items.map((item) => item.count), [2, 1, 1]);
    expect(controller.items.first.timeMs, 0);
    // 只重排显示，不追加任何窗口请求。
    expect(repository.requests, 1);
  });

  test('屏蔽词先于合并生效，计数不属于屏蔽条件', () async {
    final repository = _MergeRepository(_source());
    final controller = await _open(repository, merge: DanmakuMerge.ten);
    controller.setBlockedWords(['别的']);
    for (var i = 0; i < 4; i++) {
      await Future<void>.value();
    }
    expect(controller.items.map((item) => item.id), ['a1', 'a3']);
    expect(controller.items.map((item) => item.count), [2, 1]);
  });

  test('切回关闭恢复原始条目与计数', () async {
    final repository = _MergeRepository(_source());
    final controller = await _open(repository, merge: DanmakuMerge.thirty);
    expect(controller.items.map((item) => item.count), [3, 1]);
    controller.setMergeWindow(DanmakuMerge.off);
    expect(controller.items.map((item) => item.id), ['a1', 'b1', 'a2', 'a3']);
    expect(controller.items.map((item) => item.count), [1, 1, 1, 1]);
    expect(repository.requests, 1);
  });

  test('重复设置同一窗口不重建条目', () async {
    final repository = _MergeRepository(_source());
    final controller = await _open(repository, merge: DanmakuMerge.ten);
    final revision = controller.dataRevision;
    controller.setMergeWindow(DanmakuMerge.ten);
    expect(controller.dataRevision, revision);
  });
}
