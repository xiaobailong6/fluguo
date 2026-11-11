import 'package:flutter/material.dart';
import 'app_notice.dart';

import '../../local_store.dart';
import '../../models.dart';
import 'focus_ring.dart';
import 'poster_menu.dart';
import '../downloads/download_picker_page.dart';
import '../shell/app_shell.dart';

Future<void> _toggle(BuildContext context, LocalStore store, Drama drama) =>
    store.toggleFavorite(drama).catchError((Object failure) {
      if (context.mounted) {
        showAppNotice(context, '$failure');
      }
    });

/// 点击海报三点按钮，在按钮附近显示液态玻璃「追剧／取消追剧」菜单。
///
/// 追剧状态由海报左上角心形表达；菜单预留四字宽度，切换状态时不跳宽。
/// 确认后只给一条单行气泡提示，不再提供撤销入口。
/// 三点菜单的结果：追剧开关，或进入下载选集。
enum _PosterMenuAction { toggleFollow, download }

Future<void> showFollowMenu(
  BuildContext context,
  LocalStore store,
  Drama drama,
  Offset anchor,
) async {
  final epoch = store.profileEpoch;
  final followed = store.isFavorite(drama.id);
  final canDownload =
      store.canDownload && store.allowsSource(drama.source);
  final action = await showPosterMenu<_PosterMenuAction>(context, anchor, [
    PosterMenuItem(
      _PosterMenuAction.toggleFollow,
      followed ? '取消追剧' : '追剧',
      followed ? Icons.bookmark_remove_rounded : Icons.bookmark_add_outlined,
    ),
    if (canDownload)
      const PosterMenuItem(
        _PosterMenuAction.download, '下载剧集', Icons.download_rounded,
      ),
  ], minWidth: 120);
  // 弹层可能跨过解锁、用户切换或权限撤销，旧菜单不得操作新的用户资料。
  if (action == null || !context.mounted || store.profileEpoch != epoch ||
      store.locked || !store.allowsSource(drama.source)) return;
  if (action == _PosterMenuAction.download) {
    if (!store.canDownload) return;
    await openPage<void>(
      context,
      (_) => DownloadPickerPage(store: store, drama: drama),
      debugName: 'download',
    );
    return;
  }
  try {
    await store.toggleFavorite(drama);
  } catch (failure) {
    if (context.mounted) showAppNotice(context, '$failure');
    return;
  }
  if (!context.mounted) return;
  final title = _shortTitle(drama.title);
  showAppNotice(context, followed ? '已取消追剧「$title」' : '已追剧「$title」');
}

/// 气泡只保留一排：剧名过长时截断并加省略号，避免气泡换行变高。
String _shortTitle(String title) {
  final text = title.trim();
  return text.runes.length <= 10
      ? text
      : '${String.fromCharCodes(text.runes.take(10))}…';
}


class FollowPill extends StatelessWidget {
  const FollowPill({
    super.key,
    required this.store,
    required this.drama,
    this.height = 40,
    this.radius,
    this.onToggled,
    this.focusNode,
  });
  final LocalStore store;
  final Drama drama;
  final double height;
  final double? radius;
  final VoidCallback? onToggled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      final corner = radius ?? height / 2;
      return FocusRing(
        radius: corner,
        child: FilledButton.tonalIcon(
          key: const ValueKey('follow-toggle'),
          focusNode: focusNode,
          onPressed: () {
            _toggle(context, store, drama);
            onToggled?.call();
          },
          style: FilledButton.styleFrom(
            minimumSize: Size(0, height),
            padding: EdgeInsets.fromLTRB(height / 4, 0, height * 0.35, 0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(corner),
            ),
            iconSize: height * 0.45,
            textStyle: TextStyle(
              fontSize: height >= 44 ? 15 : 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: Icon(
            followed ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
          ),
          label: Stack(
            alignment: Alignment.center,
            children: [
              const Visibility(
                visible: false,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: Text('已追剧'),
              ),
              Text(followed ? '已追剧' : '追剧'),
            ],
          ),
        ),
      );
    },
  );
}

class FollowIcon extends StatelessWidget {
  const FollowIcon({
    super.key,
    required this.store,
    required this.drama,
    required this.color,
    required this.activeColor,
    this.size = 24,
    this.extent = 48,
  });
  final LocalStore store;
  final Drama drama;
  final Color color;
  final Color activeColor;
  final double size;
  final double extent;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final followed = store.isFavorite(drama.id);
      return Semantics(
        label: followed ? '已追剧，轻点取消' : '追剧',
        button: true,
        excludeSemantics: true,
        child: IconButton(
          key: const ValueKey('follow-toggle'),
          onPressed: () => _toggle(context, store, drama),
          style: IconButton.styleFrom(fixedSize: Size.square(extent)),
          icon: Icon(
            followed ? Icons.bookmark_rounded : Icons.bookmark_add_outlined,
            size: size,
            color: followed ? activeColor : color,
          ),
        ),
      );
    },
  );
}
