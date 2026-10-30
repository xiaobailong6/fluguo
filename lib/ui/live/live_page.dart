import 'dart:async';

import 'package:flutter/material.dart';

import '../../live_bilibili.dart';
import '../../live_feed.dart';
import '../app_scope.dart';
import '../shell/app_shell.dart';
import '../widgets/category_tabs.dart';
import '../widgets/choice_panel.dart';
import '../widgets/status_view.dart';
import 'live_player_page.dart';

/// 直播页：左上角选平台，下面按一级分区列房间。
///
/// 目前只接了哔哩哔哩，但页面只认 [LivePlatform]，再加站源不用改这里。
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage> {
  late LiveFeed _feed = _open(livePlatforms.first);

  LiveFeed _open(LivePlatform platform) {
    final feed = LiveFeed(platform);
    unawaited(feed.start());
    return feed;
  }

  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  /// 换平台：旧 feed 直接丢掉，新 feed 从分区开始重来。
  void _switchPlatform(LivePlatform platform) {
    if (platform.id == _feed.platform.id) return;
    final previous = _feed;
    setState(() => _feed = _open(platform));
    previous.dispose();
  }

  void _openRoom(LiveRoom room) => openPage<void>(
    context,
    (_) => LivePlayerPage(platform: _feed.platform, room: room),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _feed,
    builder: (context, _) {
      final feed = _feed;
      return Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _header(context, feed),
              if (feed.categories.isNotEmpty)
                CategoryTabs<LiveCategory>(
                  options: [
                    for (final category in feed.categories)
                      ChoiceOption(category, category.name),
                  ],
                  selected: feed.category ?? feed.categories.first,
                  onSelected: (category) => unawaited(feed.select(category)),
                ),
              Expanded(child: _body(context, feed)),
            ],
          ),
        ),
      );
    },
  );

  /// 顶栏：左上角是直播平台下拉，点名字就换平台。
  Widget _header(BuildContext context, LiveFeed feed) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
        child: Row(
          children: [
            PopupMenuButton<LivePlatform>(
              tooltip: '切换直播平台',
              onSelected: _switchPlatform,
              itemBuilder: (context) => [
                for (final platform in livePlatforms)
                  PopupMenuItem(
                    value: platform,
                    child: Text(
                      platform.name,
                      style: TextStyle(
                        fontWeight: platform.id == feed.platform.id
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 4,
                  children: [
                    Text(
                      feed.platform.name,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down_rounded, size: 26),
                  ],
                ),
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: '刷新',
              onPressed: feed.loadingRooms
                  ? null
                  : () => unawaited(feed.refresh()),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context, LiveFeed feed) {
    if (feed.rooms.isEmpty) {
      if (feed.loadingRooms || feed.loadingCategories) {
        return const StatusView.loading(title: '正在打开直播');
      }
      if (feed.error.isNotEmpty) {
        return StatusView(
          title: '暂时打不开直播',
          message: feed.error,
          icon: Icons.cloud_off_rounded,
          action: '重试',
          onAction: () => unawaited(feed.start()),
        );
      }
      return StatusView(
        title: '这个分区还没有直播',
        message: '换一个分区看看',
        icon: Icons.live_tv_rounded,
        action: '刷新',
        onAction: () => unawaited(feed.refresh()),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis != Axis.vertical) return false;
        if (notification.metrics.extentAfter < 600) {
          unawaited(feed.loadMore());
        }
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: .82,
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
                4,
                16,
                16 + bottomBarInset(context),
              ),
              child: Center(
                child: feed.loadingMore
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        feed.error.isNotEmpty ? feed.error : '已经到底了',
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant,
                        ),
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