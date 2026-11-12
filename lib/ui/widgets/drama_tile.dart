import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models.dart';
import '../app_scope.dart';
import '../app_motion.dart';
import 'cover_image.dart';
import 'focus_ring.dart';
import 'poster_menu.dart';
import 'poster_menu_lifecycle.dart';

const _coverRadius = 12.0;

/// 站源与状态共用同一行、同一套胶囊外观，避免右上角与三点按钮抢位置。
///
/// [scale] 是整块胶囊的等比缩放（字号、内边距、圆角一起缩）。我的页横排卡片
/// 只有 100 宽，站源名称必须和三点菜单按同一个比例缩，否则直播那种长名称
/// （「直播 · bilibili」）不缩、短剧那种被 FittedBox 压过，两张卡片一大一小。
Widget _chip(
  String text,
  Color background,
  Color foreground,
  FontWeight weight,
  double horizontal, {
  double scale = 1,
}) => Container(
  padding: EdgeInsets.symmetric(
    horizontal: horizontal * scale,
    vertical: 2 * scale,
  ),
  decoration: BoxDecoration(
    color: background,
    borderRadius: BorderRadius.circular(6 * scale),
  ),
  child: Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: foreground,
      fontSize: 11 * scale,
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
    this.menuScale = 1,
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

  /// 三点按钮缩放比，与站源胶囊共用，1 为原尺寸。
  final double menuScale;

  @override
  State<_PosterButton> createState() => _PosterButtonState();
}

class _PosterButtonState extends State<_PosterButton> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;
  final _menuKey = GlobalKey();
  final _menuActivity = PosterMenuActivity();

  void _openMenu([Offset? anchor]) {
    if (!mounted || widget.onMore == null || _menuActivity.value) return;
    final target = _menuKey.currentContext ?? context;
    final box = target.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final base =
        anchor ?? box.localToGlobal(Offset(box.size.width, box.size.height));
    // 菜单按 30px 按钮的右下角定位（面板顶边 = 锚点 y - 30）。按钮等比缩小后
    // 视觉高度不再是 30，锚点要按差值补回去，否则菜单会比按钮高出一截。
    final visual = PosterMenuMetrics.buttonSize * widget.menuScale;
    final shifted = visual == PosterMenuMetrics.buttonSize
        ? base
        : base + Offset(0, PosterMenuMetrics.buttonSize - visual);
    _menuActivity.invoke(() => widget.onMore!(shifted));
  }

  @override
  void dispose() {
    _menuActivity.dispose();
    super.dispose();
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
          : (details) => _openMenu(details.globalPosition),
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
            right: PosterMenuMetrics.buttonInset * widget.menuScale,
            top: PosterMenuMetrics.buttonInset * widget.menuScale,
            child: ValueListenableBuilder<bool>(
              valueListenable: _menuActivity,
              builder: (context, hidden, child) => IgnorePointer(
                ignoring: hidden,
                child: ExcludeFocus(
                  excluding: hidden,
                  // 按钮显隐直接换，不做透明度动画。
                  //
                  // 唯一确定的事实：闪烁只出现在「正在过渡的那 200ms 里」，而且
                  // 关掉玻璃模糊后照样闪，所以不是模糊层的锅。剩下能做的就是把
                  // 过渡本身去掉：菜单收起完成的同一帧按钮就回来，没有中间态，
                  // 也就没有可闪的东西。手势、焦点、`_menuKey` 定位都不变。
                  child: Visibility(
                    visible: !hidden,
                    // 保留 State / 动画 / 尺寸：按钮的手势、焦点、`_menuKey`
                    // 定位都照旧，只是不绘制、不参与命中测试。
                    maintainState: true,
                    maintainAnimation: true,
                    maintainSize: true,
                    child: child!,
                  ),
                ),
              ),
              child: PosterMenuButton(
                scale: widget.menuScale,
                tooltip: widget.menuTooltip,
                onPressed: _openMenu,
                visualKey: _menuKey,
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
              ? .965
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
    this.followed = false,
  });
  final Drama drama;
  final VoidCallback onTap;
  final String? subtitle;
  final int? rank;
  final ValueChanged<Offset>? onMore;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool followed;

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
    cover: DramaCover(drama: drama, radius: _coverRadius, rank: rank,
      followed: followed),
    label:
        '${rank == null ? '' : '第$rank名，'}'
        '${followed ? '已追剧，' : ''}'
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
    this.followed = false,
    this.sourceOnlyMark = false,
    this.menuScale = 1,
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
  final bool followed;

  /// 追剧页 / 最近观看页 / 我的页横排使用：左上角不画心形，
  /// 站源胶囊与右上角三点菜单对齐，已追剧时用粉色高亮。
  final bool sourceOnlyMark;

  /// 三点菜单与站源胶囊共用的缩放比（1 = 原尺寸）。
  ///
  /// 只有我的页横排卡片（100 宽）传 0.7：那张卡片整体比列表页小一圈，
  /// 按钮和胶囊按同比例缩小才不会显得比海报还抢眼。
  final double menuScale;

  /// 直播等非短剧记录可复用排版，但不得进入短剧封面解析链路。
  final Widget? cover;

  static double extentFor(BuildContext context, double width) {
    final scaler = MediaQuery.textScalerOf(context);
    final television = AppScope.of(context).television;
    final title = scaler.scale(television ? 15 : 14) * 1.3;
    final caption = scaler.scale(television ? 13 : 12) * 1.3;
    return (width * 1.5 + 8 + title + 2 + caption).ceilToDouble();
  }

  /// 站源胶囊。
  ///
  /// `sourceOnlyMark` 形态下统一成与三点菜单同高，让左上角站源与右上角菜单
  /// 落在同一条线上；其它页面保持原来的紧凑高度。
  Widget _tag(
    String text,
    Color background,
    Color foreground, {
    required double horizontal,
  }) {
    final chip = _chip(
      text,
      background,
      foreground,
      FontWeight.w600,
      horizontal,
      // 只有「只留站源」的形态需要等比缩：其它页面 menuScale 是 1，尺寸不变。
      scale: sourceOnlyMark ? menuScale : 1,
    );
    if (!sourceOnlyMark) return chip;
    return SizedBox(
      height: PosterMenuMetrics.buttonSize * menuScale,
      child: Align(alignment: AlignmentDirectional.centerStart, child: chip),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // 追剧页/最近观看页/我的页横排：左上角只留站源胶囊，不画心形。
    // 已追剧时用与心形相同的粉色打底，文字压深保证看得清。
    final highlightTag = followed && sourceOnlyMark;
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
            if (followed && !sourceOnlyMark)
              const Positioned(left: 6, top: 6, child: FollowHeart()),
            if (tag != null ||
                status != null ||
                badge != null && selected == null)
              Positioned(
                left: 8,
                // 只留站源的形态下与右上角三点菜单同一行；画心形时给心形让位。
                top: sourceOnlyMark
                    ? PosterMenuMetrics.buttonInset * menuScale
                    : followed
                    ? 42
                    : 8,
                right: inlineStatus && (showMenuButton || selected != null) ? 46 : 8,
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
                                _tag(
                                  tag,
                                  highlightTag
                                      ? followHeartColor
                                      : Colors.black.withValues(alpha: .65),
                                  highlightTag
                                      ? const Color(0xFF2A0A12)
                                      : Colors.white,
                                  horizontal: 6,
                                ),
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
                      Padding(
                        padding: EdgeInsets.only(right: showMenuButton || selected != null ? 38 : 0),
                        child: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: _tag(
                              tag,
                              highlightTag
                                  ? followHeartColor
                                  : Colors.black.withValues(alpha: .55),
                              highlightTag
                                  ? const Color(0xFF2A0A12)
                                  : Colors.white,
                              horizontal: 7,
                            ),
                          ),
                        ),
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
        menuScale: menuScale,
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
