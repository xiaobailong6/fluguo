import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

import '../../live_models.dart';
import '../app_motion.dart';
import '../widgets/poster_menu.dart';
import '../widgets/text_metrics.dart';
import 'live_room_cover.dart';

/// 直播和收藏共用卡片；封面按显示尺寸解码，避免长列表保留原尺寸图片。
class LiveRoomCard extends StatelessWidget {
  const LiveRoomCard({
    super.key,
    required this.room,
    required this.onTap,
    this.platformName,
    this.selected,
    this.onLongPress,
    this.onMore,
  });
  final LiveRoom room;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? platformName;
  final bool? selected;

  /// 右上角三点菜单；返回的 Future 在菜单退场后完成，便于再串联下一层弹窗。
  final Future<void> Function(Offset anchor)? onMore;

  /// 两个入口共享封面比例与文字高度，系统大字体不会挤掉封面。
  static SliverGridDelegate gridDelegate(BuildContext context) {
    final theme = Theme.of(context);
    double lineHeight(TextStyle? style) => measureTextLine(
      text: '直播',
      style: style,
      scaler: MediaQuery.textScalerOf(context),
      direction: Directionality.of(context),
    ).height;

    return _LiveRoomGridDelegate(
      8 +
          lineHeight(theme.textTheme.titleSmall) +
          lineHeight(theme.textTheme.bodySmall),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final subtitle = [
      if (room.anchor.isNotEmpty) room.anchor,
      if (room.area.isNotEmpty) room.area,
    ].join(' · ');
    final badges = <Widget>[
      if (platformName != null) _badge(platformName!),
      // 在线人数从右上角移到左上角，右上角让给三点菜单或多选框。
      if (room.online.isNotEmpty) _badge(room.online),
    ];
    return Semantics(
      selected: selected,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    // 右侧保留 56px 给三点按钮/多选框，长角标不会压过去。
                    final corner = selected != null || onMore != null;
                    final badgeWidth = math.max(
                      0.0,
                      constraints.maxWidth - (corner ? 56 : 12),
                    );
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        LiveRoomCover(url: room.cover, radius: 0),
                        if (badges.isNotEmpty)
                          Positioned(
                            left: 6,
                            top: 6,
                            child: SizedBox(
                              width: badgeWidth,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 4,
                                children: badges,
                              ),
                            ),
                          ),
                        if (selected != null)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Icon(
                              selected!
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked_rounded,
                              color: selected! ? colors.primary : Colors.white,
                              shadows: const [Shadow(blurRadius: 3)],
                            ),
                          )
                        else if (onMore case final onMore?)
                          Positioned(
                            right: PosterMenuMetrics.buttonInset,
                            top: PosterMenuMetrics.buttonInset,
                            child: _LivePosterMenu(
                              tooltip: '直播菜单',
                              onMore: onMore,
                            ),
                          ),
                        if (selected == true)
                          IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: colors.primary,
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
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
      ),
    );
  }

  Widget _badge(String text) => Container(
    constraints: const BoxConstraints(maxWidth: 140),
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0xAA000000),
      borderRadius: BorderRadius.circular(7),
    ),
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: Colors.white, fontSize: 11),
    ),
  );
}

/// 与海报一致：点击后三点淡出，菜单关闭后恢复，期间不会重复打开。
class _LivePosterMenu extends StatefulWidget {
  const _LivePosterMenu({required this.tooltip, required this.onMore});
  final String tooltip;
  final Future<void> Function(Offset anchor) onMore;

  @override
  State<_LivePosterMenu> createState() => _LivePosterMenuState();
}

class _LivePosterMenuState extends State<_LivePosterMenu> {
  final _visual = GlobalKey();
  bool _hidden = false;

  Future<void> _open() async {
    if (_hidden) return;
    final box = _visual.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    setState(() => _hidden = true);
    try {
      await widget.onMore(
        box.localToGlobal(Offset(box.size.width, box.size.height)),
      );
    } finally {
      if (mounted) setState(() => _hidden = false);
    }
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    ignoring: _hidden,
    child: ExcludeFocus(
      excluding: _hidden,
      child: AnimatedOpacity(
        opacity: _hidden ? 0 : 1,
        duration: AppMotion.duration(context, AppMotion.state),
        curve: AppMotion.curve,
        child: PosterMenuButton(
          tooltip: widget.tooltip,
          onPressed: _open,
          visualKey: _visual,
        ),
      ),
    ),
  );
}

/// 根据网格的真实可用宽度计算高度，不依赖全屏宽度，兼容桌面侧栏。
class _LiveRoomGridDelegate extends SliverGridDelegateWithMaxCrossAxisExtent {
  const _LiveRoomGridDelegate(this.textHeight)
    : super(maxCrossAxisExtent: 280, mainAxisSpacing: 12, crossAxisSpacing: 12);

  final double textHeight;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) {
    final columns = math.max(
      1,
      (constraints.crossAxisExtent / (maxCrossAxisExtent + crossAxisSpacing))
          .ceil(),
    );
    final width = math.max(
      0.0,
      (constraints.crossAxisExtent - crossAxisSpacing * (columns - 1)) /
          columns,
    );
    return SliverGridDelegateWithMaxCrossAxisExtent(
      maxCrossAxisExtent: maxCrossAxisExtent,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
      mainAxisExtent: width * 9 / 16 + textHeight,
    ).getLayout(constraints);
  }

  @override
  bool shouldRelayout(covariant _LiveRoomGridDelegate oldDelegate) =>
      textHeight != oldDelegate.textHeight;
}
