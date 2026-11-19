import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_progress_writer.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/fake_player.dart';

class _RecordingStore extends LocalStore {
  _RecordingStore(super.preferences) : super(runWatchBatch: inlineWatchBatch);
  bool fail = true;
  final saves = <({WatchEntry entry, bool quiet})>[];

  @override
  Future<void> saveWatch(WatchEntry entry, {bool quiet = false}) async {
    saves.add((entry: entry, quiet: quiet));
    if (fail) throw StateError('disk full');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final detail = dramaDetail(drama('progress'), count: 3);
  late List<({WatchEntry entry, bool quiet})> writes;
  late List<(String, WatchEntry)> mediaWrites;
  late PlaybackProgressWriter writer;
  late int notifications;
  late bool fail;

  setUp(() {
    writes = [];
    mediaWrites = [];
    notifications = 0;
    fail = false;
    writer = PlaybackProgressWriter(
      saveWatch: (entry, {quiet = false}) async {
        writes.add((entry: entry, quiet: quiet));
        if (fail) throw StateError('disk full');
      },
      saveMediaWatch: (id, entry) async => mediaWrites.add((id, entry)),
      currentDrama: (item) => item,
      onWarningChanged: () => notifications++,
      clock: () => DateTime.utc(2030),
    );
  });

  Future<void> save({
    double position = 12,
    double duration = 100,
    bool quiet = false,
    int index = 0,
  }) => writer.save(
    detail: detail,
    openedIndex: index,
    position: position,
    duration: duration,
    quiet: quiet,
  );

  test('低于原阈值不保存，边界值及实际集号保持不变', () async {
    await save(position: .099);
    expect(writes, isEmpty);
    await save(position: .1, index: 1);
    expect(writes.single.entry.episode, 2);
    expect(writes.single.entry.position, .1);
    expect(writes.single.entry.updatedAt, DateTime.utc(2030));
    expect(notifications, 0);
  });

  test('静默去重之后仍保留一次显式保存，之后不重复写', () async {
    await save(quiet: true);
    await save(quiet: true);
    await save();
    await save();
    await save(quiet: true);
    expect(writes.map((value) => value.quiet), [true, false]);
    expect(writer.warning, isNull);
    expect(notifications, 0);
  });

  test('集数、位置、时长与剧集身份均参与去重', () async {
    await save();
    await save(index: 1);
    await save(index: 1, position: 13);
    await save(index: 1, position: 13, duration: 101);
    await writer.save(
      detail: dramaDetail(drama('other')),
      openedIndex: 1,
      position: 13,
      duration: 101,
    );
    expect(writes, hasLength(5));
  });

  test('失败不消费去重键，重复失败只提示一次，成功清除提示', () async {
    fail = true;
    await save(quiet: true);
    await save(quiet: true);
    expect(writes, hasLength(2));
    expect(writer.warning, '观看进度尚未保存，请检查存储空间后重试。');
    expect(notifications, 1);
    fail = false;
    await save(quiet: true);
    await save(quiet: true);
    expect(writes, hasLength(3));
    expect(writer.warning, isNull);
    expect(notifications, 2);
    await save();
    expect(writes, hasLength(4));
  });

  test('使用最新元数据，合并视频走独立历史而非分集保存', () async {
    final latest = drama('progress', title: '更新后的标题');
    writer = PlaybackProgressWriter(
      saveWatch: (entry, {quiet = false}) async =>
          writes.add((entry: entry, quiet: quiet)),
      saveMediaWatch: (id, entry) async => mediaWrites.add((id, entry)),
      currentDrama: (_) => latest,
      onWarningChanged: () => notifications++,
      mediaHistoryId: 'merged-1',
    );
    await save(quiet: true);
    await save();
    expect(writes, isEmpty);
    expect(mediaWrites, hasLength(2));
    expect(mediaWrites.first.$1, 'merged-1');
    expect(mediaWrites.first.$2.drama, same(latest));
  });

  test('保留原异步约定，未完成写入不提前去重', () async {
    final gates = <Completer<void>>[];
    writer = PlaybackProgressWriter(
      saveWatch: (entry, {quiet = false}) {
        writes.add((entry: entry, quiet: quiet));
        final gate = Completer<void>();
        gates.add(gate);
        return gate.future;
      },
      saveMediaWatch: (id, entry) async {},
      currentDrama: (item) => item,
      onWarningChanged: () => notifications++,
    );
    final first = save();
    final second = save();
    expect(writes, hasLength(2));
    gates[0].complete();
    gates[1].complete();
    await Future.wait([first, second]);
    await save();
    expect(writes, hasLength(2));
  });
  test('真实会话保持保存提示通知、显式刷新和退出后的通知保护', () async {
    SharedPreferences.setMockInitialValues({});
    final store = _RecordingStore(await SharedPreferences.getInstance());
    final repository = FakeRepository();
    final player = FakePlayer();
    final session = PlaybackSession(
      repository: repository,
      store: store,
      detail: detail,
      player: player,
      index: 0,
      adoptedPlan: const PlaybackPlan(url: 'https://fixture.invalid/media'),
    );
    await pumpEventQueue();
    var changed = 0;
    session.addListener(() => changed++);
    player.progress(
      const Duration(seconds: 12),
      duration: const Duration(seconds: 100),
    );
    await session.saveProgress(quiet: true);
    expect(session.saveWarning, '观看进度尚未保存，请检查存储空间后重试。');
    expect(changed, 1);
    await session.saveProgress(quiet: true);
    expect(changed, 1);
    store.fail = false;
    await session.saveProgress(quiet: true);
    expect(session.saveWarning, isNull);
    expect(changed, 2);
    await session.saveProgress(quiet: true);
    expect(store.saves, hasLength(3));
    await session.saveProgress();
    expect(store.saves.map((value) => value.quiet), [true, true, true, false]);
    player.progress(const Duration(seconds: 15));
    store.fail = true;
    session.dispose();
    await pumpEventQueue();
    expect(changed, 2, reason: '退出后的写入失败不通知已销毁的会话');
    expect(store.saves.last.entry.position, 15);
    store.dispose();
  });
}
