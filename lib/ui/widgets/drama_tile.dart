import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../app_scope.dart';
import '../app_motion.dart';
import 'cover_image.dart';
import 'focus_ring.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

const _coverRadius = 12.0;

/// 站源与状态共用同一行、同一套胶囊外观，避免右上角与三点按钮抢位置。
Widget _chip(
  String text,
  Color background,
  Color foreground,
  FontWeight weight,
  double horizontal,
) => Container(
  padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 2),
  decoration: BoxDecoration(
    color: background,
    borderRadius: BorderRadius.circular(6),
  ),
  child: Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: foreground,
      fontSize: 11,
      fontWeight: weight,
      height: 1.3,
    ),
  ),
);

class _PosterButton extends StatefulWidget {
  const _PosterButton({
    required this.cover,
    required this.caption,
    required this.label,
    required this.onTap,
    this.onMore,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.checked,
    this.showMenuButton = true,
    this.menuTooltip = '追剧菜单',
    this.status,
    this.statusError = false,
  });
  final Widget cover;
  final List<Widget> caption;
  final String label;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMore;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool? checked;
  final bool showMenuButton;
  final String menuTooltip;
  final String? status;
  final bool statusError;

  @override
  State<_PosterButton> createState() => _PosterButtonState();
}

class _PosterButtonState extends State<_PosterButton> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;
  final _menuKey = GlobalKey();

  void _openMenu() {
    final target = _menuKey.currentContext ?? context;
    final box = target.findRenderObject()! as RenderBox;
    widget.onMore?.call(
      box.localToGlobal(Offset(box.size.width, box.size.height)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = focusVisible(_focused);
    final layer = _pressed ? 0.12 : (_hovered ? 0.08 : 0.0);
    final button = GestureDetector(
      onLongPressStart: widget.onLongPress != null
          ? (_) => widget.onLongPress!()
          : widget.showMenuButton || widget.onMore == null
          ? null
          : (details) => widget.onMore!(details.globalPosition),
      child: InkWell(
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        onTap: widget.onTap,
        onSecondaryTap: widget.showMenuButton || widget.onMore == null
            ? null
            : _openMenu,
        // 滚动时指针会在卡片间进出，同一状态用不着重建整个卡片子树。
        onFocusChange: (focused) {
          if (_focused == focused) return;
          setState(() => _focused = focused);
        },
        onHover: (hovered) {
          if (_hovered == hovered) return;
          setState(() => _hovered = hovered);
        },
        onHighlightChanged: (pressed) {
          if (_pressed == pressed) return;
          setState(() => _pressed = pressed);
        },
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        splashFactory: NoSplash.splashFactory,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: FocusOutline(
                visible: visible,
                radius: _coverRadius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    widget.cover,
                    IgnorePointer(
                      child: AnimatedContainer(
                        duration: AppMotion.duration(context, AppMotion.press),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(_coverRadius),
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: layer),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            ...widget.caption,
          ],
        ),
      ),
    );
    final menu = widget.showMenuButton && widget.onMore != null
        ? Positioned(
            right: 6,
            top: 6,
            child: SizedBox(
              key: _menuKey,
              width: 30,
              height: 30,
              child: GlassSurface(
                role: GlassRole.chrome,
                radius: GlassRadius.pill,
                interactive: true,
                style: GlassStyleResolver.of(
                  context,
                  role: GlassRole.chrome,
                ).thinned(tintAlpha: .14),
                child: IconButton(
                  tooltip: widget.menuTooltip,
                  onPressed: _openMenu,
                  padding: EdgeInsets.zero,
                  iconSize: 18,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: .88),
                  icon: const Icon(Icons.more_horiz_rounded),
                ),
              ),
            ),
          )
        : null;
    final tappable = menu == null ? button : Stack(children: [button, menu]);
    final shortcuts = <ShortcutActivator, VoidCallback>{};
    if (widget.onMore != null) {
      shortcuts[const SingleActivator(LogicalKeyboardKey.contextMenu)] =
          _openMenu;
    }
    return Semantics(
      label: widget.label,
      checked: widget.checked,
      child: CallbackShortcuts(
        bindings: shortcuts,
        child: AnimatedScale(
          scale: AppMotion.reduced(context)
              ? 1
              : _pressed
              ? .98
              : visible && AppScope.of(context).television
              ? 1.06
              : 1,
          duration: AppMotion.duration(
            context,
            _pressed ? AppMotion.press : AppMotion.state,
          ),
          child: tappable,
        ),
      ),
    );
  }
}

Widget _line(BuildContext context, String text, TextStyle style, int lines) =>
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SizedBox(
        height:
            MediaQuery.textScalerOf(context).scale(style.fontSize!) *
            style.height! *
            lines,
        child: Text(
          text,
          maxLines: lines,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      ),
    );

class DramaTile extends StatelessWidget {
  const DramaTile({
    super.key,
    required this.drama,
    required this.onTap,
    this.subtitle,
    this.rank,
    this.onMore,
    this.focusNode,
    this.autofocus = false,
  });
  final Drama drama;
  final VoidCallback onTap;
  final String? subtitle;
  final int? rank;
  final ValueChanged<Offset>? onMore;
  final FocusNode? focusNode;
  final bool autofocus;

  static TextStyle titleStyle(BuildContext context) => TextStyle(
    fontSize: AppScope.of(context).television ? 15 : 14,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );

  static TextStyle subtitleStyle(BuildContext context) => TextStyle(
    fontSize: AppScope.of(context).television ? 13 : 12,
    height: 1.3,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
  );

  static double extentFor(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final title = scaler.scale(titleStyle(context).fontSize!) * 1.3 * 2;
    final subtitle = scaler.scale(subtitleStyle(context).fontSize!) * 1.3;
    return (width * 1.5 + 9 + title + 4 + subtitle).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) => _PosterButton(
    cover: DramaCover(drama: drama, radius: _coverRadius, rank: rank),
    label:
        '${rank == null ? '' : '第$rank名，'}'
        '${drama.title}，${drama.episodes}集${drama.vip ? '，VIP' : ''}',
    onTap: onTap,
    onMore: onMore,
    focusNode: focusNode,
    autofocus: autofocus,
    caption: [
      const SizedBox(height: 9),
      _line(context, drama.title, titleStyle(context), 2),
      const SizedBox(height: 4),
      _line(context, subtitle ?? drama.category, subtitleStyle(context), 1),
    ],
  );
}

class ProgressPoster extends StatelessWidget {
  const ProgressPoster({
    super.key,
    required this.drama,
    required this.progress,
    required this.caption,
    required this.onTap,
    this.tag,
    this.onMore,
    this.focusNode,
    this.width = 100,
    this.selected,
    this.badge,
    this.cover,
    this.showMenuButton = true,
    this.onLongPress,
    this.menuTooltip = '追剧菜单',
    this.status,
    this.statusError = false,
    this.inlineStatus = false,
    this.progressLabel,
  });
  final Drama drama;
  final double? progress;
  final String caption;
  final String? tag;
  final String? badge;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onMore;
  final VoidCallback? onLongPress;
  final String menuTooltip;
  final String? status;
  final bool statusError;
  final bool inlineStatus;
  final String? progressLabel;
  final FocusNode? focusNode;
  final double width;
  final bool? selected;
  final bool showMenuButton;

  /// 直播等非短剧记录可复用排版，但不得进入短剧封面解析链路。
  final Widget? cover;

  static double extentFor(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final television = AppScope.of(context).television;
    final title = scaler.scale(television ? 15 : 14) * 1.3;
    final caption = scaler.scale(television ? 13 : 12) * 1.3;
    return (width * 1.5 + 8 + title + 2 + caption).ceilToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final television = AppScope.of(context).television;
    final marker = status ?? (selected == null ? badge : null);
    return SizedBox(
      width: width,
      child: _PosterButton(
        cover: Stack(
          fit: StackFit.expand,
          children: [
            cover ??
                DramaCover(drama: drama, radius: _coverRadius, details: false),
            if (tag != null ||
                status != null ||
                badge != null && selected == null)
              Positioned(
                left: 8,
                top: 8,
                right: showMenuButton || selected != null ? 46 : 8,
                child: inlineStatus
                    ? Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: [
                              if (tag case final tag?)
                                _chip(tag, Colors.black.withValues(alpha: .65),
                                    Colors.white, FontWeight.w600, 6),
                              if (marker != null)
                                _chip(marker, statusError ? colors.error : colors.primary,
                                    statusError ? colors.onError : colors.onPrimary,
                                    FontWeight.w700, 6),
                            ],
                          ),
                        ),
                      )
                    : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (tag case final tag?)
                      _chip(
                        tag,
                        Colors.black.withValues(alpha: 0.55),
                        Colors.white,
                        FontWeight.w600,
                        7,
                      ),
                    if (status case final status?)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _chip(
                          status,
                          statusError ? colors.error : colors.primary,
                          statusError ? colors.onError : colors.onPrimary,
                          FontWeight.w700,
                          8,
                        ),
                      ),
                    // 状态已在显示「合并中」，就不再重复挂「已合并」徽标。
                    if (badge case final badge?
                        when selected == null && status == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _chip(
                          badge,
                          colors.primary,
                          colors.onPrimary,
                          FontWeight.w700,
                          8,
                        ),
                      ),
                  ],
                ),
              ),
            if (television)
              const IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.all(
                      Radius.circular(_coverRadius),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: [.55, 1],
                      colors: [Colors.transparent, Color(0xB3000000)],
                    ),
                  ),
                ),
              ),
            if (progressLabel case final label?)
              Positioned(
                left: 6,
                right: 6,
                bottom: 8,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: .82),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      spacing: 6,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(label, maxLines: 1,
                            style: const TextStyle(color: Colors.white,
                              fontSize: 20, height: 1.1, fontWeight: FontWeight.w800)),
                        ),
                        LinearProgressIndicator(
                          value: progress?.clamp(0.0, 1.0),
                          minHeight: 5,
                          color: Colors.lightBlueAccent,
                          backgroundColor: Colors.white24,
                          borderRadius: BorderRadius.circular(3),
                          stopIndicatorColor: Colors.transparent,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (progressLabel == null && progress != null)
              Positioned(
                left: television ? 8 : _coverRadius,
                right: television ? 8 : _coverRadius,
                bottom: television ? 8 : 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(television ? 2 : 1.5),
                  child: LinearProgressIndicator(
                    value: progress!.clamp(0.0, 1.0),
                    minHeight: television ? 4 : 3,
                    color: colors.primaryFixedDim,
                    backgroundColor: Colors.white.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.zero,
                    stopIndicatorColor: Colors.transparent,
                  ),
                ),
              ),
            if (selected case final selected?) ...[
              if (selected)
                IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_coverRadius),
                      border: Border.all(color: colors.primary, width: 3),
                    ),
                  ),
                ),
              Positioned(
                right: 8,
                top: 8,
                child: Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: selected
                        ? colors.primary
                        : Colors.black.withValues(alpha: 0.35),
                    border: selected
                        ? null
                        : Border.all(color: Colors.white, width: 2),
                  ),
                  child: selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 18,
                          color: colors.onPrimary,
                        )
                      : null,
                ),
              ),
            ],
          ],
        ),
        label:
            '${drama.title}，${tag == null ? '' : '$tag，'}'
            '${status == null ? '' : '$status，'}'
            '${badge == null ? '' : '$badge，'}$caption',
        checked: selected,
        onTap: onTap,
        onMore: onMore,
        onLongPress: onLongPress,
        menuTooltip: menuTooltip,
        showMenuButton: showMenuButton,
        focusNode: focusNode,
        caption: [
          const SizedBox(height: 8),
          _line(
            context,
            drama.title,
            TextStyle(
              fontSize: television ? 15 : 14,
              fontWeight: FontWeight.w600,
              height: 1.3,
            ),
            1,
          ),
          const SizedBox(height: 2),
          _line(
            context,
            caption,
            TextStyle(
              fontSize: television ? 13 : 12,
              height: 1.3,
              color: colors.onSurfaceVariant,
            ),
            1,
          ),
        ],
      ),
    );
  }
}
