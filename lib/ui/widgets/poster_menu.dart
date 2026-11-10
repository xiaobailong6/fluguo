import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

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
          constraints: const BoxConstraints(maxWidth: 280),
          child: GlassSurface(
            role: GlassRole.panel,
            radius: GlassRadius.card,
            style: GlassStyleResolver.of(context, role: GlassRole.panel)
                .thinned(tintAlpha: .48),
            padding: const EdgeInsets.all(6),
            child: SingleChildScrollView(
              child: IntrinsicWidth(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, item) in items.indexed) ...[
                      if (index > 0) const Divider(height: 1),
                      InkWell(
                        borderRadius: BorderRadius.circular(
                          GlassRadius.nested(GlassRadius.card, 6),
                        ),
                        onTap: () => Navigator.of(context).pop(item.value),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(item.icon, size: 20,
                                  color: Theme.of(context).colorScheme.onSurface),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Text(item.label, maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                              ),
                              if (item.selected) ...[
                                const SizedBox(width: 8),
                                Icon(Icons.check_circle_rounded, size: 16,
                                  color: Theme.of(context).colorScheme.primary),
                              ],
                            ],
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
    final left = (anchor.dx - childSize.width)
        .clamp(12.0, (size.width - childSize.width - 12).clamp(12, double.infinity));
    final below = anchor.dy + 6;
    final top = (below + childSize.height <= size.height - 12
        ? below : anchor.dy - 42 - childSize.height)
        .clamp(12.0, (size.height - childSize.height - 12).clamp(12, double.infinity));
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(_PosterMenuPosition oldDelegate) => oldDelegate.anchor != anchor;
}
