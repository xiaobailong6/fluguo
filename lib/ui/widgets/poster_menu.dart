import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

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

/// 短剧与下载海报共用菜单：相同材质、内边距、圆角、锚点和淡入节奏。
Future<T?> showPosterMenu<T>(
  BuildContext context,
  Offset anchor,
  List<PosterMenuItem<T>> items,
) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: true,
  barrierLabel: '关闭菜单',
  barrierColor: Colors.black.withValues(alpha: .18),
  transitionDuration: AppMotion.duration(context, AppMotion.state),
  pageBuilder: (context, _, _) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    return CustomSingleChildLayout(
      delegate: _PosterMenuPosition(overlay.globalToLocal(anchor)),
      child: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: PosterMenuMetrics.maxWidth),
          child: GlassSurface(
            role: GlassRole.panel,
            radius: GlassRadius.card,
            style: GlassStyleResolver.of(context, role: GlassRole.panel)
                .thinned(tintAlpha: .48),
            padding: const EdgeInsets.all(PosterMenuMetrics.padding),
            child: SingleChildScrollView(
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final item in items) ...[
                      InkWell(
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  },
  transitionBuilder: (context, animation, _, child) => FadeTransition(
    opacity: CurvedAnimation(parent: animation, curve: AppMotion.curve),
    child: child,
  ),
);

class _PosterMenuPosition extends SingleChildLayoutDelegate {
  const _PosterMenuPosition(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: (constraints.maxWidth - 24).clamp(0.0, double.infinity).toDouble(),
        maxHeight: (constraints.maxHeight - 24).clamp(0.0, double.infinity).toDouble(),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // 嵌套 clamp 的下界写作整数字面量时，整体会被推断成 num；Offset 只收
    // double，所以边界先各自算成 double，再显式收敛为 double。
    final maxLeft = math.max(12.0, size.width - childSize.width - 12);
    final maxTop = math.max(12.0, size.height - childSize.height - 12);
    final left = (anchor.dx - childSize.width).clamp(12.0, maxLeft).toDouble();
    final below = anchor.dy + PosterMenuMetrics.padding;
    final top = (below + childSize.height <= size.height - 12
            ? below
            : anchor.dy - PosterMenuMetrics.buttonSize -
                PosterMenuMetrics.padding * 2 - childSize.height)
        .clamp(12.0, maxTop)
        .toDouble();
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_PosterMenuPosition oldDelegate) => oldDelegate.anchor != anchor;
}
