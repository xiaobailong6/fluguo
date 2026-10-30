import 'dart:async';

import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/live_feed.dart';
import 'package:flutter_test/flutter_test.dart';

const area = LiveCategory(name: '英雄联盟', parentId: '2', areaId: '86');
const otherArea = LiveCategory(name: '绝地求生', parentId: '2', areaId: '93');
const parent = LiveCategory(
  name: '网游',
  parentId: '2',
  children: [area, otherArea],
);
const room = LiveRoom(
  roomId: '1',
  title: '直播',
  anchor: '主播',
  cover: '',
  area: '英雄联盟',
  online: '1万',
);

class FakeLive extends LivePlatform {
  FakeLive({this.key = 'fake'});
  final String key;
  Object? categoryError;
  Future<List<LiveRoom>> Function(LiveCategory, int)? onRooms;
  final calls = <(String, String, int)>[];

  @override
  String get id => key;
  @override
  String get name => '测试';
  @override
  Future<List<LiveCategory>> categories() async {
    if (categoryError case final error?) throw error;
    return const [parent];
  }

  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async {
    calls.add((category.parentId, category.areaId, page));
    return onRooms == null ? const [room] : await onRooms!(category, page);
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 10000}) async =>
      const LiveStream(
        url: 'https://example.test/live.flv',
        quality: '高清',
        headers: {},
      );
}

void main() {
  test('打开平台、选择一级只显示二级，点击二级后才请求房间', () async {
    final platform = FakeLive();
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    expect(feed.areas, [area, otherArea]);
    expect(feed.area, isNull);
    expect(feed.rooms, isEmpty);
    expect(platform.calls, isEmpty);
    await feed.selectArea(area);
    expect(platform.calls, [('2', '86', 1)]);
    expect(feed.rooms, [room]);
    feed.backToAreas();
    expect(feed.area, isNull);
    expect(feed.rooms, isEmpty);
  });

  test('切回分区后忽略迟到的房间响应', () async {
    final response = Completer<List<LiveRoom>>();
    final platform = FakeLive()..onRooms = (_, _) => response.future;
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    final request = feed.selectArea(area);
    feed.backToAreas();
    response.complete(const [room]);
    await request;
    expect(feed.rooms, isEmpty);
    expect(feed.area, isNull);
    expect(feed.loadingRooms, isFalse);
  });

  test('快速切换二级分区时旧请求不会覆盖新列表', () async {
    final old = Completer<List<LiveRoom>>();
    final platform = FakeLive()
      ..onRooms = (category, _) =>
          category == area ? old.future : Future.value(const []);
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    final oldRequest = feed.selectArea(area);
    await feed.selectArea(otherArea);
    old.complete(const [room]);
    await oldRequest;
    expect(feed.area, otherArea);
    expect(feed.rooms, isEmpty);
  });

  test('分类失败保持错误，不自动刷新覆盖错误；刷新可恢复', () async {
    final platform = FakeLive()..categoryError = StateError('分区请求失败');
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    expect(feed.error, '分区请求失败');
    expect(feed.loadingCategories, isFalse);
    platform.categoryError = null;
    await feed.refresh();
    expect(feed.category, parent);
    expect(feed.error, isEmpty);
    expect(platform.calls, isEmpty);
  });

  test('分页去重且重复整页后停止继续加载', () async {
    final page = List.generate(
      livePageSize,
      (i) => LiveRoom(
        roomId: '$i',
        title: '直播$i',
        anchor: '',
        cover: '',
        area: '',
        online: '',
      ),
    );
    final platform = FakeLive()..onRooms = (_, _) async => page;
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    await feed.selectArea(area);
    await feed.loadMore();
    expect(feed.rooms.length, livePageSize);
    expect(feed.end, isTrue);
    await feed.loadMore();
    expect(platform.calls.length, 2);
  });

  test('dispose 后完成请求不再通知或开始新请求', () async {
    final response = Completer<List<LiveRoom>>();
    final platform = FakeLive()..onRooms = (_, _) => response.future;
    final feed = LiveFeed(platform);
    await feed.start();
    final request = feed.selectArea(area);
    feed.dispose();
    response.complete(const [room]);
    await request;
    await feed.refresh();
    expect(platform.calls.length, 1);
  });
}
