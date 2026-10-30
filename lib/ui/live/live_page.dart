import 'dart:async';

import 'package:flutter/material.dart';

import '../../live_bilibili.dart';
import '../../live_feed.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../theme/glass_style.dart';
import '../widgets/glass/glass_header.dart';
import '../widgets/glass/glass_surface.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/status_view.dart';
import 'live_player_page.dart';

/// 与发现页共用玻璃顶栏；未选择二级分区之前不展示直播卡片。
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage> {
  late final LiveFeed _feed;
  double _headerHeight = 120;

  @override
  void initState() {
    super.initState();
    _feed = LiveFeed(livePlatforms.first);
    unawaited(_feed.start());
  }

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  Future<void> _pickPlatform(BuildContext anchor) async {
    final box = anchor.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(Offset.zero);
    final size = MediaQuery.sizeOf(context);
    final width = (size.width - 32).clamp(0.0, 260.0).toDouble();
    final left = origin.dx.clamp(16.0, size.width - width - 16).toDouble();
    final selected = await showDialog<LivePlatform>(
      context: context,
      barrierColor: Colors.black26,
      // 坐标来自全局，禁用 Dialog 自己的 SafeArea，避免顶部安全区被重复叠加。
      useSafeArea: false,
      builder: (context) => Stack(
        children: [
          Positioned(
            left: left,
            top: (origin.dy + box.size.height + 6)
                .clamp(MediaQuery.paddingOf(context).top, size.height - 100)
                .toDouble(),
            width: width,
            child: GlassSurface(
              radius: GlassRadius.card,
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final platform in livePlatforms)
                    ListTile(
                      title: Text(platform.name),
                      selected: platform.id == _feed.platform.id,
                      trailing: platform.id == _feed.platform.id
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.pop(context, platform),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || selected == null) return;
    await _feed.switchPlatform(selected);
  }

  void _openRoom(LiveRoom room) {
    final platform = _feed.platform;
    unawaited(
      openPage<void>(
        context,
        (_) => LivePlayerPage(platform: platform, room: room),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _feed,
    builder: (context, _) => Scaffold(
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: _feed.refresh,
          child: Stack(
            children: [
              Positioned.fill(child: _body(context, _feed)),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: GlassHeader(
                  onHeight: (height) {
                    if (!mounted || (height - _headerHeight).abs() <= .5)
                      return;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && (height - _headerHeight).abs() > .5) {
                        setState(() => _headerHeight = height);
                      }
                    });
                  },
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _header(context),
                      if (_feed.category case final category?)
                        CategoryTabs<LiveCategory>(
                          options: [
                            for (final item in _feed.categories)
                              ChoiceOption(item, item.name),
                          ],
                          selected: category,
                          onSelected: (item) => unawaited(_feed.select(item)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _header(BuildContext context) => SizedBox(
    height: 64,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Row(
        children: [
          Builder(
            builder: (anchor) => TextButton(
              onPressed: () => unawaited(_pickPlatform(anchor)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _feed.platform.name,
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                  const Icon(Icons.arrow_drop_down_rounded, size: 26),
                ],
              ),
            ),
          ),
          const Spacer(),
          IconButton(
            tooltip: '刷新',
            onPressed: _feed.loadingRooms || _feed.loadingCategories
                ? null
                : () => unawaited(_feed.refresh()),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    ),
  );

  Widget _body(BuildContext context, LiveFeed feed) {
    final inset = _headerHeight + 12;
    if (feed.loadingCategories || feed.loadingRooms && feed.rooms.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: inset),
        child: const StatusView.loading(title: '正在加载直播'),
      );
    }
    if (feed.error.isNotEmpty && feed.rooms.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(top: inset),
        child: StatusView(
          title: '暂时无法加载',
          message: feed.error,
          action: '重试',
          onAction: () => unawaited(feed.refresh()),
        ),
      );
    }
    if (feed.area == null) {
      if (feed.areas.isEmpty) {
        return Padding(
          padding: EdgeInsets.only(top: inset),
          child: const StatusView(title: '暂无二级分区', message: '请选择其他一级分区'),
        );
      }
      return GridView.builder(
        key: PageStorageKey(
          'live-areas-${feed.platform.id}-${feed.category?.parentId}',
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(
          16,
          inset,
          16,
          24 + bottomBarInset(context),
        ),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 220,
          mainAxisExtent: 72,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: feed.areas.length,
        itemBuilder: (context, index) {
          final area = feed.areas[index];
          return GlassSurface(
            blur: false,
            radius: GlassRadius.card,
            child: InkWell(
              borderRadius: BorderRadius.circular(GlassRadius.card),
              onTap: () => unawaited(feed.selectArea(area)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        area.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 20),
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical &&
            notification.metrics.extentAfter < 600)
          unawaited(feed.loadMore());
        return false;
      },
      child: CustomScrollView(
        key: PageStorageKey('live-rooms-${feed.platform.id}-${feed.area}'),
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, inset, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${feed.category?.name ?? ''} / ${feed.area!.name}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: feed.backToAreas,
                    icon: const Icon(Icons.grid_view_rounded, size: 18),
                    label: const Text('返回分区'),
                  ),
                ],
              ),
            ),
          ),
          if (feed.rooms.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('这个分区暂时没有直播')),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 1.25,
              ),
              itemCount: feed.rooms.length,
              itemBuilder: (context, index) {
                final room = feed.rooms[index];
                return _RoomCard(room: room, onTap: () => _openRoom(room));
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                12,
                16,
                24 + bottomBarInset(context),
              ),
              child: Center(
                child: feed.loadingMore
                    ? const CircularProgressIndicator()
                    : feed.error.isNotEmpty
                    ? TextButton(
                        onPressed: () => unawaited(feed.retryMore()),
                        child: Text('${feed.error} · 重试'),
                      )
                    : TextButton(
                        onPressed: feed.end
                            ? null
                            : () => unawaited(feed.loadMore()),
                        child: Text(feed.end ? '已经到底了' : '加载更多'),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoomCard extends StatelessWidget {
  const _RoomCard({required this.room, required this.onTap});
  final LiveRoom room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final subtitle = [
      if (room.anchor.isNotEmpty) room.anchor,
      if (room.area.isNotEmpty) room.area,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceContainerHighest),
                  if (room.cover.isNotEmpty)
                    Image.network(
                      room.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stack) =>
                          const SizedBox.shrink(),
                    ),
                  if (room.online.isNotEmpty)
                    Positioned(
                      right: 6,
                      top: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: .55),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 3,
                          children: [
                            const Icon(
                              Icons.local_fire_department_rounded,
                              size: 12,
                              color: Colors.white,
                            ),
                            Text(
                              room.online,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            room.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}
