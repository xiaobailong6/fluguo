import 'package:flutter/foundation.dart';

import 'live_bilibili.dart';

const livePageSize = 30;

String liveErrorText(Object failure) {
  final text = '$failure';
  for (final prefix in const ['Bad state: ', 'Exception: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

/// 平台 → 一级分区 → 用户选择二级分区 → 房间。
/// 请求序号同时保护分类和分页，旧请求不能覆盖后来选择的分区。
class LiveFeed extends ChangeNotifier {
  LiveFeed(this.platform);

  LivePlatform platform;
  final categories = <LiveCategory>[];
  LiveCategory? category;
  LiveCategory? area;
  final rooms = <LiveRoom>[];
  bool loadingCategories = false;
  bool loadingRooms = false;
  bool loadingMore = false;
  String error = '';
  bool end = false;
  int _page = 1;
  int _generation = 0;
  bool _disposed = false;

  List<LiveCategory> get areas => category?.hot == true
      ? const [LiveCategory(name: '热门直播', parentId: '0')]
      : category?.children ?? const [];

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> start() async {
    if (_disposed) return;
    final generation = ++_generation;
    loadingCategories = true;
    _clearRooms();
    categories.clear();
    category = null;
    _notify();
    try {
      final list = await platform.categories();
      if (_stale(generation)) return;
      categories.addAll(list);
      category = list.firstOrNull;
    } catch (failure) {
      if (_stale(generation)) return;
      error = liveErrorText(failure);
    }
    loadingCategories = false;
    _notify();
  }

  /// 一级分类只展示二级入口，不请求房间。
  Future<void> select(LiveCategory next) async {
    if (_disposed || next == category) return;
    _generation++;
    category = next;
    _clearRooms();
    _notify();
  }

  Future<void> selectArea(LiveCategory next) async {
    if (_disposed || !areas.contains(next)) return;
    area = next;
    rooms.clear();
    await refresh();
  }

  void backToAreas() {
    if (_disposed) return;
    _generation++;
    _clearRooms();
    _notify();
  }

  /// 没有二级选择时只刷新分类，不会悄悄加载整个一级分区。
  Future<void> refresh() async {
    if (_disposed) return;
    final target = area;
    if (target == null) {
      await start();
      return;
    }
    final generation = ++_generation;
    loadingRooms = true;
    loadingMore = false;
    _page = 1;
    end = false;
    error = '';
    _notify();
    try {
      final list = await platform.rooms(target, page: 1);
      if (_stale(generation)) return;
      rooms
        ..clear()
        ..addAll(list);
      end = list.length < livePageSize;
    } catch (failure) {
      if (_stale(generation)) return;
      rooms.clear();
      error = liveErrorText(failure);
    }
    loadingRooms = false;
    _notify();
  }

  Future<void> loadMore() async {
    final target = area;
    if (_disposed ||
        target == null ||
        loadingRooms ||
        loadingMore ||
        end ||
        error.isNotEmpty)
      return;
    final generation = _generation;
    loadingMore = true;
    _notify();
    try {
      final list = await platform.rooms(target, page: _page + 1);
      if (_stale(generation)) return;
      final ids = rooms.map((room) => room.roomId).toSet();
      final additions = list.where((room) => ids.add(room.roomId)).toList();
      rooms.addAll(additions);
      _page++;
      end = list.length < livePageSize || additions.isEmpty;
    } catch (failure) {
      if (_stale(generation)) return;
      error = liveErrorText(failure);
    }
    loadingMore = false;
    _notify();
  }

  Future<void> retryMore() async {
    if (_disposed) return;
    error = '';
    await loadMore();
  }

  Future<void> switchPlatform(LivePlatform next) async {
    if (_disposed || next.id == platform.id) return;
    platform = next;
    await start();
  }

  void _clearRooms() {
    area = null;
    rooms.clear();
    loadingRooms = false;
    loadingMore = false;
    _page = 1;
    end = false;
    error = '';
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
