import 'package:flutter/material.dart';

import '../../live_bilibili.dart';
import '../../live_history.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../recent_history.dart';
import '../detail/detail_page.dart';
import '../live/live_room_cover.dart';
import '../live/live_navigation.dart';
import '../shell/app_shell.dart';
import 'app_notice.dart';
import 'drama_tile.dart';

String recentSourceLabel(RecentEntry entry) => entry.live == null
    ? '短剧 · ${SourceSite.byId(entry.watch!.drama.source).name}'
    : '直播 · ${livePlatformById(entry.live!.platformId)?.name ?? entry.live!.platformId}';

/// 共用海报布局，直播的 Drama 仅为封面视图适配，不进入短剧存储或详情。
class RecentPoster extends StatelessWidget {
  const RecentPoster({
    super.key,
    required this.store,
    required this.entry,
    required this.width,
    this.focusNode,
    this.selected,
    this.onToggle,
    this.onOpenLive,
  });
  final LocalStore store;
  final RecentEntry entry;
  final double width;
  final FocusNode? focusNode;
  final bool? selected;
  final VoidCallback? onToggle;
  final void Function(LiveHistoryEntry)? onOpenLive;

  @override
  Widget build(BuildContext context) {
    final live = entry.live;
    final watch = entry.watch;
    final drama =
        watch?.drama ??
        Drama(
          id: entry.key,
          source: '',
          title: live!.room.title,
          cover: live.room.cover,
        );
    final total = drama.episodes;
    return ProgressPoster(
      drama: drama,
      cover: live == null ? null : LiveRoomCover(url: live.room.cover),
      width: width,
      focusNode: focusNode,
      selected: selected,
      progress: watch == null
          ? null
          : total > 0
          ? watch.episode / total
          : 0,
      caption: live != null
          ? live.room.anchor
          : total > 0 && watch!.episode >= total && watch.finished
          ? '已看完'
          : '看到第 ${watch!.episode} 集',
      tag: recentSourceLabel(entry),
      onTap:
          onToggle ??
          () {
            if (live == null) {
              openPage<void>(
                context,
                (_) => DetailPage(store: store, drama: drama),
              );
            } else if (livePlatformById(live.platformId) == null) {
              showAppNotice(context, '这个直播平台当前不可用，观看记录已保留');
            } else if (onOpenLive != null) {
              onOpenLive!(live);
            } else {
              openLivePlayer(
                context,
                store,
                livePlatformById(live.platformId)!,
                live.room,
              );
            }
          },
    );
  }
}
