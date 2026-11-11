import 'dart:async';

import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';

import '../../live_bilibili.dart';
import '../../live_favorites.dart';
import '../../local_store.dart';
import '../widgets/poster_menu.dart';
import '../widgets/status_view.dart';
import 'live_navigation.dart';
import 'live_room_card.dart';

class LiveFavoritesPage extends StatefulWidget {
  const LiveFavoritesPage({super.key, required this.store});
  final LocalStore store;

  @override
  State<LiveFavoritesPage> createState() => _LiveFavoritesPageState();
}

class _LiveFavoritesPageState extends State<LiveFavoritesPage> {
  final _selected = <String>{};
  bool _managing = false;
  bool _busy = false;
  late int _epoch;

  /// 上次通知时的收藏列表实例：内容没变就不重建整页（含封面网格）。
  Object? _favorites;

  @override
  void initState() {
    super.initState();
    _epoch = widget.store.profileEpoch;
    widget.store.addListener(_changed);
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    final epoch = widget.store.profileEpoch;
    final favorites = widget.store.liveFavorites;
    // 只有这一页真正依赖的内容变了才重建：Store 的通知很密（例如每 15 秒一次
    // 的观看进度落盘），让整页收藏网格跟着重建是纯浪费。
    if (epoch == _epoch && identical(favorites, _favorites)) return;
    _favorites = favorites;
    final switched = epoch != _epoch;
    _epoch = epoch;
    setState(() {
      if (switched) {
        _managing = false;
        _selected.clear();
      }
      final available = widget.store.liveFavorites
          .map((entry) => entry.key)
          .toSet();
      _selected.removeWhere((key) => !available.contains(key));
    });
  }

  void _toggle(String key) => setState(() {
    if (!_selected.add(key)) _selected.remove(key);
  });

  /// 与直播页、海报共用同一个三点菜单和退场时序。
  Future<void> _showCardMenu(Offset anchor, LiveFavorite entry) async {
    if (_busy) return;
    final epoch = widget.store.profileEpoch;
    final saved = widget.store.isLiveFavorite(
      entry.platformId,
      entry.room.roomId,
    );
    final action = await showPosterMenu<bool>(context, anchor, [
      PosterMenuItem(
        true,
        saved ? '取消收藏' : '收藏',
        saved ? Icons.bookmark_remove_rounded : Icons.bookmark_add_outlined,
      ),
    ]);
    if (action == null ||
        !mounted ||
        _busy ||
        widget.store.profileEpoch != epoch ||
        widget.store.isLiveFavorite(entry.platformId, entry.room.roomId) !=
            saved) {
      return;
    }
    try {
      await widget.store.toggleLiveFavorite(entry.platformId, entry.room);
      if (!mounted || widget.store.profileEpoch != epoch) return;
      showAppNotice(context, saved ? '已取消收藏该主播' : '已收藏该主播');
    } catch (_) {
      if (mounted) showAppNotice(context, '未能保存直播收藏，请重试');
    }
  }

  Future<void> _remove() async {
    if (_busy || _selected.isEmpty) return;
    final epoch = widget.store.profileEpoch;
    final selected = Set<String>.of(_selected);
    setState(() => _busy = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('取消收藏 ${selected.length} 个主播？'),
          content: const Text('只移除选中的直播收藏，不影响其他收藏和观看记录。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('保留'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('取消收藏'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true || epoch != widget.store.profileEpoch)
        return;
      await widget.store.removeLiveFavorites(selected);
      if (mounted) setState(_selected.clear);
    } catch (_) {
      if (mounted) {
        showAppNotice(context, '未能取消收藏，请重试');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.store.liveFavorites;
    return PopScope(
      canPop: !_managing && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy)
          setState(() {
            _managing = false;
            _selected.clear();
          });
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_managing ? '已选 ${_selected.length} 项' : '直播收藏'),
          actions: [
            if (_managing)
              IconButton(
                tooltip: _selected.length == entries.length ? '取消全选' : '全选',
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        if (_selected.length == entries.length) {
                          _selected.clear();
                        } else {
                          _selected.addAll(entries.map((entry) => entry.key));
                        }
                      }),
                icon: const Icon(Icons.select_all_rounded),
              ),
            TextButton(
              onPressed: _busy || entries.isEmpty
                  ? null
                  : () => setState(() {
                      _managing = !_managing;
                      _selected.clear();
                    }),
              child: Text(_managing ? '完成' : '管理'),
            ),
          ],
        ),
        bottomNavigationBar: _managing
            ? SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: _busy || _selected.isEmpty
                        ? null
                        : () => unawaited(_remove()),
                    icon: const Icon(Icons.bookmark_remove_outlined),
                    label: Text(_busy ? '正在处理…' : '取消收藏（${_selected.length}）'),
                  ),
                ),
              )
            : null,
        body: entries.isEmpty
            ? const StatusView(
                title: '还没有收藏主播',
                message: '在直播播放页点击收藏按钮，主播会出现在这里',
                icon: Icons.bookmark_border_rounded,
              )
            : GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: LiveRoomCard.gridDelegate(context),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final platform = livePlatformById(entry.platformId);
                  return LiveRoomCard(
                    key: ValueKey('favorite-${entry.key}'),
                    room: entry.room,
                    platformName: platform?.name ?? entry.platformId,
                    selected: _managing ? _selected.contains(entry.key) : null,
                    onMore: _busy || _managing
                        ? null
                        : (anchor) => _showCardMenu(anchor, entry),
                    onLongPress: _busy
                        ? null
                        : () => setState(() {
                            _managing = true;
                            _selected.add(entry.key);
                          }),
                    onTap: () {
                      if (_busy) return;
                      if (_managing) {
                        _toggle(entry.key);
                        return;
                      }
                      if (platform == null) {
                        showAppNotice(context, '这个直播平台当前不可用，收藏已保留');
                      } else {
                        unawaited(
                          openLivePlayer(
                            context,
                            widget.store,
                            platform,
                            entry.room,
                          ),
                        );
                      }
                    },
                  );
                },
              ),
      ),
    );
  }
}
