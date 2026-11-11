import 'dart:async';
import 'package:flutter/foundation.dart';

import 'live_bilibili.dart';
import 'local_store.dart';

const livePageSize = 30;

String liveErrorText(Object failure) {
  final text = '$failure';
  for (final prefix in const ['Bad state: ', 'Exception: ']) {
    if (text.startsWith(prefix)) return text.substring(prefix.length);
  }
  return text;
}

/// 平台 → 一级分区 → 用户选择二级分区 → 房间。
/// 分类和房间各自用请求序号保护，搜索不必等待分类，也不接受过期响应。
class LiveFeed extends ChangeNotifier {
  LiveFeed(this.platform, {this.store, this.restorePlatform = false}) {
    _profileEpoch = store?.profileEpoch;
    _categoryIds.addAll(store?.liveBrowsePreferences.categoryIds ?? {});
    store?.addListener(_storeChanged);
  }

  final LocalStore? store;
  final bool restorePlatform;
  int? _profileEpoch;
  final _categoryIds = <String, String>{};

  void _storeChanged() {
    final source = store!;
    if (_profileEpoch == source.profileEpoch) return;
    _profileEpoch = source.profileEpoch;
    _generation++;
    _categoryGeneration++;
    _categoryIds
      ..clear()
      ..addAll(source.liveBrowsePreferences.categoryIds);
    categories.clear();
    category = null;
    loadingCategories = false;
    _clearRooms();
    if (restorePlatform) {
      platform =
          livePlatformById(source.liveBrowsePreferences.platformId) ??
          livePlatforms.first;
    }
    _notify();
    if (!source.locked) unawaited(start());
  }

  void _remember() {
    final source = store;
    if (source == null ||
        source.locked ||
        source.profileEpoch != _profileEpoch) {
      return;
    }
    // 持久化失败不改变分类/搜索结果，也不冒泡为未处理异步异常。
    unawaited(
      source
          .rememberLiveBrowse(
            platform.id,
            category?.parentId,
            profileEpoch: _profileEpoch!,
          )
          .catchError((Object _) {}),
    );
  }

  LivePlatform platform;
  final categories = <LiveCategory>[];
  LiveCategory? category;
  LiveCategory? area;
  final rooms = <LiveRoom>[];
  String query = '';
  bool loadingCategories = false;
  bool loadingRooms = false;
  bool loadingMore = false;
  String error = '';
  bool end = false;
  int _page = 1;
  int _generation = 0;
  int _categoryGeneration = 0;
  bool _disposed = false;

  List<LiveCategory> get areas => category?.hot == true
      ? const [LiveCategory(name: '热门直播', parentId: '0')]
      : category?.children ?? const [];

  @override
  void dispose() {
    store?.removeListener(_storeChanged);
    _disposed = true;
    _generation++;
    super.dispose();
  }

  Future<void> start() async {
    if (_disposed || store?.locked == true) return;
    final rememberedId = _categoryIds[platform.id] ?? category?.parentId;
    final generation = ++_generation;
    final categoryGeneration = ++_categoryGeneration;
    loadingCategories = true;
    _clearRooms();
    categories.clear();
    category = null;
    _notify();
    try {
      final list = await platform.categories();
      if (_disposed || categoryGeneration != _categoryGeneration) return;
      categories.addAll(list);
      // 每次请求都使用新实例按稳定 ID 匹配，不保留平台返回的对象。
      category =
          list.where((item) => item.parentId == rememberedId).firstOrNull ??
          list.firstOrNull;
      if (category case final selected?) {
        _categoryIds[platform.id] = selected.parentId;
      }
      _remember();
    } catch (failure) {
      if (_disposed || categoryGeneration != _categoryGeneration) return;
      // 搜索期间分类仍可后台完成，但分类错误不能覆盖搜索状态。
      if (!_stale(generation)) error = liveErrorText(failure);
    }
    loadingCategories = false;
    _notify();
  }

  /// 一级分类只展示二级入口，不请求房间。
  Future<void> select(LiveCategory next) async {
    if (_disposed ||
        store?.locked == true ||
        !categories.contains(next) ||
        (next == category && query.isEmpty && area == null)) {
      return;
    }
    _generation++;
    category = next;
    _categoryIds[platform.id] = next.parentId;
    _remember();
    _clearRooms();
    _notify();
  }

  Future<void> selectArea(LiveCategory next) async {
    if (_disposed || !areas.contains(next)) return;
    area = next;
    query = '';
    rooms.clear();
    await refresh();
  }

  void backToAreas() {
    if (_disposed) return;
    _generation++;
    _clearRooms();
    _notify();
  }

  Future<void> search(String keyword) async {
    if (_disposed) return;
    final text = keyword.trim();
    if (text.isEmpty) {
      backToAreas();
      return;
    }
    query = text;
    area = null;
    rooms.clear();
    await refresh();
  }

  /// 没有二级选择时只刷新分类，不会悄悄加载整个一级分区。
  Future<void> refresh() async {
    if (_disposed) return;
    final target = area;
    final keyword = query;
    if (target == null && keyword.isEmpty) {
      await start();
      return;
    }
    final generation = ++_generation;
    // 搜索不必等待分类；分类响应由独立序号保护，返回分区时仍可使用。
    loadingCategories = false;
    loadingRooms = true;
    loadingMore = false;
    _page = 1;
    end = false;
    error = '';
    _notify();
    try {
      final list = keyword.isEmpty
          ? await platform.rooms(target!, page: 1)
          : await platform.search(keyword, page: 1);
      if (_stale(generation)) return;
      rooms
        ..clear()
        ..addAll(list);
      end = keyword.isEmpty ? list.length < platform.pageSize : list.isEmpty;
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
    final keyword = query;
    if (_disposed ||
        (target == null && keyword.isEmpty) ||
        loadingRooms ||
        loadingMore ||
        end ||
        error.isNotEmpty) {
      return;
    }
    final generation = _generation;
    loadingMore = true;
    _notify();
    try {
      final list = keyword.isEmpty
          ? await platform.rooms(target!, page: _page + 1)
          : await platform.search(keyword, page: _page + 1);
      if (_stale(generation)) return;
      final ids = rooms.map((room) => room.roomId).toSet();
      final additions = list.where((room) => ids.add(room.roomId)).toList();
      rooms.addAll(additions);
      _page++;
      end =
          (keyword.isEmpty && list.length < platform.pageSize) ||
          additions.isEmpty;
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
    category = null;
    _remember();
    await start();
  }

  void _clearRooms() {
    area = null;
    query = '';
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
