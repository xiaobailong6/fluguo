import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';
import 'poster_menu_lifecycle.dart';

/// 海报菜单共用尺寸：视觉紧凑，交互区域仍保留触控与遥控焦点空间。
abstract final class PosterMenuMetrics {
  static const buttonSize = 30.0;
  static const buttonIconSize = 18.0;
  static const buttonInset = 6.0;
  static const touchTarget = 44.0;
  static const rowHeight = 32.0;
  static const maxWidth = 220.0;
  static const padding = 3.0;
  static const rowPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
  static const fontSize = 14.0;
  static const iconSize = 18.0;
  static const gap = 6.0;
}

class PosterMenuItem<T> {
  const PosterMenuItem(this.value, this.label, this.icon, {this.selected = false});
  final T value;
  final String label;
  final IconData icon;
  final bool selected;
}

/// 海报/直播卡片共用的右上角三点按钮。
///
/// 外观固定为 30px 玻璃圆钮、18px 图标、6px 贴边，点击区域仍是 44px；
/// [visualKey] 挂在实际 30px 按钮上，调用方用它计算菜单锚点，避免用 44px
/// 触控区定位导致菜单整体偏移。
class PosterMenuButton extends StatelessWidget {
  const PosterMenuButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.visualKey,
    this.color,
    this.scale = 1,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Key? visualKey;
  final Color? color;

  /// 视觉缩放比：只缩按钮本体和图标；`touchTarget` 保持 44 不缩，避免点不中。
  final double scale;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: PosterMenuMetrics.touchTarget,
    height: PosterMenuMetrics.touchTarget,
    child: IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      alignment: Alignment.topRight,
      iconSize: PosterMenuMetrics.buttonSize * scale,
      color: color ??
          Theme.of(context).colorScheme.onSurface.withValues(alpha: .88),
      icon: SizedBox(
        key: visualKey,
        width: PosterMenuMetrics.buttonSize * scale,
        height: PosterMenuMetrics.buttonSize * scale,
        child: GlassSurface(
          role: GlassRole.chrome,
          radius: GlassRadius.pill,
          interactive: true,
          style: GlassStyleResolver.preset(context, GlassPreset.control),
          child: Center(
            child: Icon(
              Icons.more_horiz_rounded,
              size: PosterMenuMetrics.buttonIconSize * scale,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 返回值在反向动画和 overlay 移除完成后才交给调用方。
///
/// [anchorRadius] 是锚点处三点按钮的圆角半径：面板右上角会用它，让两块圆弧
/// 完全重合。按钮缩小时（我的页横排的 `menuScale`）调用方要一并传进来，
/// 否则面板右上角会比胶囊更方，回场瞬间会看到两条不一致的边。
Future<T?> showPosterMenu<T>(
  BuildContext context,
  Offset anchor,
  List<PosterMenuItem<T>> items, {
  double minWidth = 0,
  double anchorRadius = PosterMenuMetrics.buttonSize / 2,
}) async {
  final activity = PosterMenuActivity.current;
  if (activity != null && !activity.begin()) return null;
  try {
    final navigator = Navigator.of(context, rootNavigator: true);
    final themes = InheritedTheme.capture(from: context, to: navigator.context);
    final route = _PosterMenuRoute<T>(
      barrierDismissible: true,
      barrierLabel: '关闭菜单',
      // 遮罩改由页面自己绘制（见下面的 Stack），这里不能再让路由遮罩
      // 重复暗一层；`barrierDismissible` 与无障碍标签仍然生效。
      barrierColor: null,
      transitionDuration: AppMotion.duration(context, AppMotion.enter),
      exitDuration: AppMotion.duration(context, AppMotion.exit),
      // 动画只作用于面板，否则整个布局变换会移动全屏锚点。
      transitionBuilder: (_, _, _, child) => child,
      pageBuilder: (context, animation, _) {
        final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
        final media = MediaQuery.of(context);
        final safe = EdgeInsets.fromLTRB(
          math.max(media.padding.left, media.viewInsets.left) + 12,
          math.max(media.padding.top, media.viewInsets.top) + 12,
          math.max(media.padding.right, media.viewInsets.right) + 12,
          math.max(media.padding.bottom, media.viewInsets.bottom) + 12,
        );
        final scaledMinWidth = MediaQuery.textScalerOf(context)
            .scale(minWidth.clamp(0.0, double.infinity).toDouble());
        final curved = CurvedAnimation(
          parent: animation,
          curve: AppMotion.navigationCurve,
          reverseCurve: AppMotion.exitCurve,
        );
        return themes.wrap(AnimatedBuilder(
          animation: curved,
          builder: (context, panel) {
            final progress = curved.value;
            final closing = animation.status == AnimationStatus.reverse;
            return IgnorePointer(
              ignoring: closing,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 遮罩和面板共用同一条进度：交给路由遮罩时，它的淡出和面板的
                  // 缓动不同步，退场时背景先变亮、玻璃面板还半透明地留在上面，
                  // 看起来就是「闪一下又出现」。
                  if (progress > 0)
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: .18 * progress),
                      ),
                    ),
                  CustomSingleChildLayout(
                    delegate: _PosterMenuPosition(
                      overlay.globalToLocal(anchor),
                      safe,
                    ),
                    child: ExcludeFocus(
                      excluding: closing,
                      child: Opacity(
                        key: const ValueKey('poster-menu-opacity'),
                        opacity: progress,
                        child: Transform.scale(
                          key: const ValueKey('poster-menu-scale'),
                          alignment: Alignment.topRight,
                          scale: AppMotion.reduced(context)
                              ? 1
                              : .96 + .04 * progress,
                          // 面板本身是同一个实例，每帧重建的只是外面这几层，
                          // 菜单行的子树不会被反复重建。
                          child: panel,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
          child: Material(
            color: Colors.transparent,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: scaledMinWidth,
                maxWidth: math.max(PosterMenuMetrics.maxWidth, scaledMinWidth),
              ),
              child: GlassSurface(
                role: GlassRole.panel,
                // 右上角与锚点处的三点按钮用同一个圆弧半径：按钮回场时两者叠在
                // 同一位置，圆角重合才不会出现「按钮右上角被啃掉一角」的两条边。
                // 其余三角仍是卡片圆角。
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(GlassRadius.card),
                  topRight: Radius.circular(anchorRadius),
                  bottomLeft: const Radius.circular(GlassRadius.card),
                  bottomRight: const Radius.circular(GlassRadius.card),
                ),
                style: GlassStyleResolver.preset(context, GlassPreset.menu),
                padding: const EdgeInsets.all(PosterMenuMetrics.padding),
                child: SingleChildScrollView(
                  child: IntrinsicWidth(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, item) in items.indexed)
                          InkWell(
                            autofocus: index == 0,
                            borderRadius: BorderRadius.circular(
                              GlassRadius.nested(
                                GlassRadius.card, PosterMenuMetrics.padding),
                            ),
                            onTap: () => Navigator.of(context).pop(item.value),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minHeight: PosterMenuMetrics.rowHeight),
                              child: Padding(
                                padding: PosterMenuMetrics.rowPadding,
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(item.icon, size: PosterMenuMetrics.iconSize,
                                      color: Theme.of(context).colorScheme.onSurface),
                                    const SizedBox(width: PosterMenuMetrics.gap),
                                    Flexible(
                                      child: Text(item.label, maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: PosterMenuMetrics.fontSize,
                                          fontWeight: FontWeight.w600)),
                                    ),
                                    if (item.selected) ...[
                                      const SizedBox(width: PosterMenuMetrics.gap),
                                      Icon(Icons.check_circle_rounded, size: 16,
                                        color: Theme.of(context).colorScheme.primary),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ));
      },
    );
    // 弹回一开始就把按钮放回来，让它的回场和面板的淡出交叉进行。
    // 返回值仍然等 `route.completed`：调用方可能紧接着弹下载选集/删除确认，
    // 旧菜单必须先彻底离开 overlay。
    final result = await navigator.push<T>(route);
    activity?.release();
    await route.completed;
    return result;
  } finally {
    activity?.end();
  }
}

/// 独立指定退场时长，同时保留 RawDialogRoute 的遮罩与路由生命周期。
class _PosterMenuRoute<T> extends RawDialogRoute<T> {
  _PosterMenuRoute({
    required super.pageBuilder,
    required super.transitionDuration,
    required this.exitDuration,
    super.barrierDismissible,
    super.barrierLabel,
    super.barrierColor,
    super.transitionBuilder,
  });

  final Duration exitDuration;

  @override
  Duration get reverseTransitionDuration => exitDuration;
}

class _PosterMenuPosition extends SingleChildLayoutDelegate {
  const _PosterMenuPosition(this.anchor, this.safe);
  final Offset anchor;
  final EdgeInsets safe;

  Rect _bounds(Size size) => Rect.fromLTRB(
    safe.left.clamp(0.0, size.width).toDouble(),
    safe.top.clamp(0.0, size.height).toDouble(),
    math.max(safe.left, size.width - safe.right).clamp(0.0, size.width).toDouble(),
    math.max(safe.top, size.height - safe.bottom).clamp(0.0, size.height).toDouble(),
  );

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final bounds = _bounds(constraints.biggest);
    // 菜单在按钮上层展开，使用整个安全区高度，长菜单在内部滚动。
    return BoxConstraints(
      maxWidth: bounds.width,
      maxHeight: bounds.height,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final bounds = _bounds(size);
    final left = (anchor.dx - childSize.width)
        .clamp(bounds.left, math.max(bounds.left, bounds.right - childSize.width))
        .toDouble();
    // anchor 是 30px 视觉按钮的右下角；菜单右上角与按钮右上角对齐。
    final top = (anchor.dy - PosterMenuMetrics.buttonSize)
        .clamp(bounds.top, math.max(bounds.top, bounds.bottom - childSize.height))
        .toDouble();
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_PosterMenuPosition oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.safe != safe;
}
