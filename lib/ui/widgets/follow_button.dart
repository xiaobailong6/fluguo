import 'package:flutter/material.dart';
import 'app_notice.dart';

import '../../local_store.dart';
import '../../models.dart';
import 'focus_ring.dart';
import '../app_motion.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

Future<void> _toggle(BuildContext context, LocalStore store, Drama drama) =>
    store.toggleFavorite(drama).catchError((Object failure) {
      if (context.mounted) {
        showAppNotice(context, '$failure');
      }
    });

/// 长按海报：弹出一块液态玻璃操作菜单，里面只有「追剧」或「取消追剧」。
///
/// 已经追过的剧，菜单右侧会多出一个小对勾；确认后只给一条单行气泡提示，
/// 不再提供撤销入口。
Future<void> showFollowMenu(
  BuildContext context,
  LocalStore store,
  Drama drama,
  Offset anchor,
) async {
  final followed = store.isFavorite(drama.id);
  final confirm = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.black.withValues(alpha: .32),
    transitionDuration: AppMotion.duration(context, AppMotion.state),
    pageBuilder: (_, _, _) => _AnchoredFollowMenu(
      anchor: anchor,
      child: _FollowMenu(followed: followed),
    ),
    transitionBuilder: (context, animation, _, child) {
      final curved = CurvedAnimation(parent: animation, curve: AppMotion.curve);
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween(begin: .96, end: 1.0).animate(curved),
          child: child,
        ),
      );
    },
  );
  if (confirm != true || !context.mounted) return;
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

class _AnchoredFollowMenu extends StatelessWidget {
  const _AnchoredFollowMenu({required this.anchor, required this.child});
  final Offset anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(anchor);
    return CustomSingleChildLayout(
      delegate: _FollowMenuPosition(point),
      child: child,
    );
  }
}

class _FollowMenuPosition extends SingleChildLayoutDelegate {
  const _FollowMenuPosition(this.anchor);
  final Offset anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: constraints.maxWidth - 24,
        maxHeight: constraints.maxHeight - 24,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final left = (anchor.dx - childSize.width / 2)
        .clamp(12.0, size.width - childSize.width - 12);
    final top = (anchor.dy - childSize.height / 2)
        .clamp(12.0, size.height - childSize.height - 12);
    return Offset(left, top);
  }

  @override
  bool shouldRelayout(covariant _FollowMenuPosition oldDelegate) =>
      oldDelegate.anchor != anchor;
}


class _FollowMenu extends StatelessWidget {
  const _FollowMenu({required this.followed});
  final bool followed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: GlassSurface(
            role: GlassRole.panel,
            radius: GlassRadius.card,
            padding: const EdgeInsets.all(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(
                GlassRadius.nested(GlassRadius.card, 6),
              ),
              onTap: () => Navigator.of(context).pop(true),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Row(
                  children: [
                    Icon(
                      followed
                          ? Icons.bookmark_remove_rounded
                          : Icons.bookmark_add_outlined,
                      size: 20,
                      color: colors.onSurface,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        followed ? '取消追剧' : '追剧',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (followed) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.check_circle_rounded,
                        size: 16,
                        color: colors.primary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
    );
  }
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
