import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';

import '../../live_models.dart';

/// 直播和收藏共用卡片；封面按显示尺寸解码，避免长列表保留原尺寸图片。
class LiveRoomCard extends StatelessWidget {
  const LiveRoomCard({
    super.key,
    required this.room,
    required this.onTap,
    this.platformName,
    this.selected,
    this.onLongPress,
  });
  final LiveRoom room;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final String? platformName;
  final bool? selected;

  /// 两个入口共享封面比例与文字高度，系统大字体不会挤掉封面。
  static SliverGridDelegate gridDelegate(BuildContext context) {
    final theme = Theme.of(context);
    double lineHeight(TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: '直播', style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final height = painter.height;
      painter.dispose();
      return height;
    }

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
                  builder: (context, constraints) => Stack(
                    fit: StackFit.expand,
                    children: [
                      ColoredBox(color: colors.surfaceContainerHighest),
                      Center(
                        child: Icon(
                          Icons.live_tv_rounded,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      if (room.cover.isNotEmpty &&
                          !const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'))
                        Image.network(
                          room.cover,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth:
                              (constraints.maxWidth *
                                      MediaQuery.devicePixelRatioOf(context))
                                  .ceil()
                                  .clamp(1, 1200),
                          excludeFromSemantics: true,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      if (platformName != null)
                        Positioned(
                          left: 6,
                          top: 6,
                          child: _badge(platformName!),
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
                      else if (room.online.isNotEmpty)
                        Positioned(
                          right: 6,
                          top: 6,
                          child: _badge(room.online),
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
                  ),
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
