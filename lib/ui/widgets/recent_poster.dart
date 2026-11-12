import 'package:flutter/material.dart';

import '../../live_bilibili.dart';
import '../../live_history.dart';
import '../../local_store.dart';
import '../../models.dart';
import '../../recent_history.dart';
import '../detail/detail_page.dart';
import '../live/live_room_cover.dart';
import '../live/live_navigation.dart';
import '../player/direct_playback_page.dart';
import '../shell/app_shell.dart';
import 'app_notice.dart';
import 'drama_tile.dart';
import 'follow_button.dart';
import 'poster_menu.dart';

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
    this.followed,
    this.onToggle,
    this.onMore,
    this.onOpenLive,
    this.sourceOnlyMark = false,
    this.menuScale = 1,
  });
  final LocalStore store;
  final RecentEntry entry;
  final double width;
  final FocusNode? focusNode;
  final bool? selected;
  /// 由父级算好的收藏状态；给出时组件不再自建 store 订阅。
  final bool? followed;
  final VoidCallback? onToggle;

  /// 非短剧记录的多选入口；短剧海报统一使用三点追剧菜单。
  final VoidCallback? onMore;
  final void Function(LiveHistoryEntry)? onOpenLive;

  /// 左上角只留站源胶囊：与三点菜单对齐，已追剧时用粉色高亮，不再画心形。
  final bool sourceOnlyMark;

  /// 三点菜单与站源胶囊的缩放比；我的页横排卡片用 0.7。
  final double menuScale;

  @override
  Widget build(BuildContext context) {
    // 调用方已经给出收藏状态（父级本来就在监听 store）时不再自建订阅：
    // 内层再包一层只会让同一张卡片被同一次通知重建两次。
    if (followed case final followed?) return _poster(context, followed);
    // 未提供时保留自动订阅，供独立挂载（测试或其它入口）使用。
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) =>
          _poster(context, entry.live == null && store.isFavorite(_drama().id)),
    );
  }

  Drama _drama() {
    final live = entry.live;
    final watch = entry.watch;
    return watch?.drama ??
        Drama(
          id: entry.key,
          source: '',
          title: live!.room.title,
          cover: live.room.cover,
        );
  }

  Widget _poster(BuildContext context, bool followed) {
    final live = entry.live;
    final watch = entry.watch;
    final drama = _drama();
    final total = drama.episodes;
    return ProgressPoster(
      drama: drama,
      followed: followed,
      cover: live == null ? null : LiveRoomCover(url: live.room.cover),
      width: width,
      focusNode: focusNode,
      selected: selected,
      showMenuButton: live == null,
      onMore: selected != null
          ? null
          : live == null
          ? (anchor) => showFollowMenu(
              context,
              store,
              drama,
              anchor,
              // 我的页横排的按钮缩到 0.7，面板右上角要跟着用同一个圆弧。
              anchorRadius: PosterMenuMetrics.buttonSize * menuScale / 2,
            )
          : onMore == null
          ? null
          : (_) => onMore!(),
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
      sourceOnlyMark: sourceOnlyMark,
      menuScale: menuScale,
      onTap:
          onToggle ??
          () {
            if (live == null) {
              openPage<void>(
                context,
                (_) => store.showDramaDetails
                    ? DetailPage(store: store, drama: drama)
                    : DirectPlaybackPage(store: store, drama: drama),
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
