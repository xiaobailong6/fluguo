import 'package:flutter/foundation.dart';

import 'live_bilibili.dart';

/// 房间列表每页条数，和接口的 `page_size` 保持一致。
const livePageSize = 30;

/// 把异常变成能直接给用户看的一句话。
String liveErrorText(Object failure) {
  final text = '$failure';
  for (final prefix in const ['Bad state: ', 'Exception: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

/// 直播列表状态：平台 → 一级分区 → 房间。
///
/// 和 `ExploreFeed` 一个路子：ChangeNotifier 持有列表、加载中、错误和分页，
/// 页面只管照着重画。
class LiveFeed extends ChangeNotifier {
  LiveFeed(this.platform);

  LivePlatform platform;

  final categories = <LiveCategory>[];
  LiveCategory? category;
  final rooms = <LiveRoom>[];

  bool loadingCategories = false;
  bool loadingRooms = false;
  bool loadingMore = false;

  /// 最近一次失败的原因，空串表示没有错误。
  String error = '';

  int _page = 1;
  bool _end = false;
  int _generation = 0;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// 首屏：先拿分区，再拿第一个分区的房间。
  Future<void> start() async {
    await _loadCategories();
    await refresh();
  }

  /// 重新拉当前分区第一页。
  Future<void> refresh() async {
    final generation = ++_generation;
    final target = category;
    loadingRooms = true;
    loadingMore = false;
    _page = 1;
    _end = false;
    error = '';
    _notify();
    if (target == null) {
      loadingRooms = false;
      _notify();
      return;
    }
    try {
      final list = await platform.rooms(target, page: 1);
      if (_stale(generation)) return;
      rooms
        ..clear()
        ..addAll(list);
      _end = list.length < livePageSize;
    } catch (failure) {
      if (_stale(generation)) return;
      rooms.clear();
      error = liveErrorText(failure);
    }
    loadingRooms = false;
    _notify();
  }

  /// 滚到底部继续加载下一页。
  Future<void> loadMore() async {
    final target = category;
    if (target == null || loadingRooms || loadingMore || _end) return;
    if (error.isNotEmpty) return;
    final generation = _generation;
    loadingMore = true;
    _notify();
    try {
      final next = _page + 1;
      final list = await platform.rooms(target, page: next);
      if (_stale(generation)) return;
      if (list.isEmpty) {
        _end = true;
      } else {
        _page = next;
        rooms.addAll(list);
        _end = list.length < livePageSize;
      }
    } catch (failure) {
      if (_stale(generation)) return;
      error = liveErrorText(failure);
    }
    loadingMore = false;
    _notify();
  }

  /// 切分区：清空列表重新拉。
  Future<void> select(LiveCategory next) async {
    if (next == category) return;
    category = next;
    rooms.clear();
    _page = 1;
    _end = false;
    _notify();
    await refresh();
  }

  /// 切平台：分区和房间都要重来。
  Future<void> switchPlatform(LivePlatform next) async {
    if (next == platform) return;
    platform = next;
    category = null;
    categories.clear();
    rooms.clear();
    error = '';
    _page = 1;
    _end = false;
    _generation++;
    _notify();
    await start();
  }

  Future<void> _loadCategories() async {
    loadingCategories = true;
    error = '';
    _notify();
    try {
      final list = await platform.categories();
      if (_disposed) return;
      categories
        ..clear()
        ..addAll(list);
      category = list.isEmpty ? null : list.first;
    } catch (failure) {
      if (_disposed) return;
      categories.clear();
      category = null;
      error = liveErrorText(failure);
    }
    loadingCategories = false;
    _notify();
  }

  bool _stale(int generation) => _disposed || generation != _generation;

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}