import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/history_retention.dart';
import 'package:duanju_app/live_history.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/ui/app.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

WatchEntry at(String id, DateTime date) => WatchEntry(
  drama: drama(id),
  episode: 1,
  position: 12,
  duration: 100,
  updatedAt: date,
);
Map<String, dynamic> liveAt(String id, DateTime date) => LiveHistoryEntry(
  platformId: 'douyin',
  room: LiveRoom(
    roomId: id,
    title: id,
    anchor: '主播',
    cover: '',
    area: '',
    online: '',
  ),
  updatedAt: date,
).toJson();

void main() {
  testWidgets('恢复前台和持续运行的日级检查删除过期持久化记录', (tester) async {
    var now = DateTime(2026, 10, 31, 12);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs, clock: () => now);
    addTearDown(store.dispose);
    await store.saveWatch(
      at('resume-expired', now.subtract(const Duration(days: 30))),
    );
    await tester.pumpWidget(
      DuanjuApp(repository: FakeRepository(), store: store),
    );
    await tester.pumpAndSettle();
    now = now.add(const Duration(days: 1));
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
    expect(jsonDecode(LocalSnapshot(prefs).getString('history')!), isEmpty);
    await store.saveWatch(
      at('timer-expired', now.subtract(const Duration(days: 30))),
    );
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(hours: 1));
    await tester.pumpAndSettle();
    expect(jsonDecode(LocalSnapshot(prefs).getString('history')!), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('按滚动30天清理两类历史及其他用户，不改收藏和损坏原始值', () {
    final now = DateTime(2026, 10, 31, 12);
    final old = at('old', now.subtract(const Duration(days: 31))).toJson();
    final edge = at('edge', now.subtract(const Duration(days: 30))).toJson();
    final values = <String, Object>{
      'history': jsonEncode([old, edge]),
      'profile.viewer.liveHistory': jsonEncode([
        liveAt('1', now.subtract(const Duration(days: 31))),
        liveAt('2', now),
      ]),
      'favorites': jsonEncode([old]),
      'profile.bad.history': 'broken',
    };
    pruneWatchHistoryValues(values, now);
    expect((jsonDecode(values['history'] as String) as List).length, 1);
    expect(
      (jsonDecode(values['profile.viewer.liveHistory'] as String) as List)
          .length,
      1,
    );
    expect(values['favorites'], jsonEncode([old]));
    expect(values['profile.bad.history'], 'broken');
    expect(
      retainedWatchTime(now.subtract(const Duration(days: 30)), now),
      isTrue,
    );
  });

  test('启动及跨日清理落盘，旧写入不能恢复过期记录，设置开关重启保留', () async {
    var now = DateTime(2026, 10, 31, 12);
    SharedPreferences.setMockInitialValues({
      'history': jsonEncode([
        at('old', now.subtract(const Duration(days: 31))).toJson(),
        at('edge', now.subtract(const Duration(days: 30))).toJson(),
      ]),
      'liveHistory': jsonEncode([
        liveAt('1', now.subtract(const Duration(days: 31))),
        liveAt('2', now),
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs, clock: () => now);
    addTearDown(store.dispose);
    await store.pruneExpiredHistory();
    expect(store.history.single.drama.id, drama('edge').id);
    expect(store.liveHistory.single.room.roomId, '2');
    now = now.add(const Duration(days: 1));
    await store.pruneExpiredHistory();
    expect(store.history, isEmpty);
    await store.saveWatch(
      at('late-old', now.subtract(const Duration(days: 40))),
    );
    expect(store.history, isEmpty);
    expect(store.showDramaDetails, isTrue);
    await store.setShowDramaDetails(false);
    final restarted = LocalStore(prefs, clock: () => now);
    addTearDown(restarted.dispose);
    expect(restarted.showDramaDetails, isFalse);
    expect(restarted.history, isEmpty);
    await restarted.pruneExpiredHistory();
  });

  test('分文件存储清理后重启不恢复旧记录', () async {
    final dir = await Directory.systemTemp.createTemp('fluguo-retention-');
    addTearDown(() => dir.delete(recursive: true));
    SharedPreferences.setMockInitialValues({
      'history': jsonEncode([
        at('expired', DateTime(2000)).toJson(),
        at('fresh', DateTime.now()).toJson(),
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final store = await LocalStore.open(prefs, dir);
    await store.pruneExpiredHistory();
    expect(store.history.single.drama.id, drama('fresh').id);
    store.dispose();
    final restarted = await LocalStore.open(prefs, dir);
    addTearDown(restarted.dispose);
    await restarted.pruneExpiredHistory();
    expect(restarted.history.single.drama.id, drama('fresh').id);
  });
}
