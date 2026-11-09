import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_motion.dart';
import '../app_scope.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

/// 应用内瞬时反馈统一走顶部气泡；确认、输入和进度对话框不属于通知。
///
/// [actionLabel] 与 [onAction] 一起给出一个可撤销的操作（例如长按海报
/// 快速追剧后的「撤销」），样式仍走同一块液态玻璃，不用 Material SnackBar。
void showAppNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
  String? actionLabel,
  VoidCallback? onAction,
}) {
  if (!context.mounted) return;
  AppNotice.of(
    context,
  ).show(message, duration: duration, actionLabel: actionLabel, onAction: onAction);
}

/// 可在 await 前捕获，完成后只检查根 Overlay，不再访问已退出页面的 context。
class AppNotice {
  AppNotice._(
    this._overlay,
    this._theme,
    this._style,
    this._foreground,
    this._reduced,
  );

  final OverlayState? _overlay;
  final ThemeData _theme;
  final GlassStyle _style;
  final Color _foreground;
  final bool _reduced;
  static final _active = Expando<_NoticeHandle>();

  static AppNotice of(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    final tier =
        scope?.glass == false || scope?.television == true || media.highContrast
        ? GlassTier.none
        : media.disableAnimations || media.accessibleNavigation
        ? GlassTier.reduced
        : GlassTier.full;
    final base = GlassStyleResolver.tier(context, tier);
    final opaque = Color.alphaBlend(base.tint, theme.colorScheme.surface);
    final colors = readableColors(
      opaque.withValues(alpha: tier == GlassTier.none ? 1 : .94),
      theme.colorScheme.onSurface,
    );
    return AppNotice._(
      Overlay.maybeOf(context, rootOverlay: true),
      theme,
      GlassStyle(
        tier: tier,
        blurSigma: base.blurSigma,
        tint: colors.background,
        // 通知内容区不叠白色高光，保证计算的最小对比度不被额外混色破坏。
        sheen: Colors.transparent,
        rimHighlight: base.rimHighlight,
        rimShadow: base.rimShadow,
        shadow: base.shadow,
        borderWidth: base.borderWidth,
      ),
      colors.foreground,
      AppMotion.reduced(context),
    );
  }

  /// 检查纯黑和纯白底下的最小对比度，覆盖任意图片/视频背景。
  @visibleForTesting
  static ({Color background, Color foreground}) readableColors(
    Color tint,
    Color preferred,
  ) {
    double worst(Color foreground, Color background) => math.min(
      contrast(foreground, Color.alphaBlend(background, Colors.black)),
      contrast(foreground, Color.alphaBlend(background, Colors.white)),
    );
    preferred = preferred.withValues(alpha: 1);
    var background = tint;
    Color choose() {
      if (worst(preferred, background) >= 4.5) return preferred;
      return worst(Colors.black, background) >= worst(Colors.white, background)
          ? Colors.black
          : Colors.white;
    }

    var foreground = choose();
    if (worst(foreground, background) < 4.5) {
      // 极端自定义中灰主题必要时取消透视，优先保证文字可读，而非强行透明。
      background = background.withValues(alpha: 1);
      foreground = choose();
    }
    return (background: background, foreground: foreground);
  }

  @visibleForTesting
  static double contrast(Color foreground, Color background) {
    final first = foreground.computeLuminance();
    final second = background.computeLuminance();
    return (math.max(first, second) + .05) / (math.min(first, second) + .05);
  }

  void show(
    String message, {
    Duration duration = const Duration(seconds: 4),
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final overlay = _overlay;
    if (overlay == null || !overlay.mounted || message.trim().isEmpty) return;
    // 复用同一个入口和 State，替换文字而不是让两个 liveRegion 同时发声。
    final existing = _active[overlay];
    if (existing != null) {
      existing.update(this, message, duration, actionLabel, onAction);
      return;
    }
    late final _NoticeHandle handle;
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Theme(
          data: handle.notice._theme,
          child: _NoticeBubble(
            key: handle.key,
            message: handle.message,
            style: handle.notice._style,
            foreground: handle.notice._foreground,
            reduced: handle.notice._reduced,
            actionLabel: handle.actionLabel,
            onAction: handle.onAction,
            onClose: handle.dismiss,
            onDispose: handle.disposed,
          ),
        ),
      ),
    );
    handle = _NoticeHandle(entry, this, message, () {
      if (identical(_active[overlay], handle)) _active[overlay] = null;
    }, actionLabel: actionLabel, onAction: onAction);
    _active[overlay] = handle;
    overlay.insert(entry);
    handle.resetTimer(duration);
  }
}

class _NoticeHandle {
  _NoticeHandle(
    this.entry,
    this.notice,
    this.message,
    this.onRemove, {
    this.actionLabel,
    this.onAction,
  });
  AppNotice notice;
  String message;
  String? actionLabel;
  VoidCallback? onAction;
  final key = GlobalKey<_NoticeBubbleState>();
  final OverlayEntry entry;
  final VoidCallback onRemove;
  Timer? timer;
  bool _removed = false;

  void resetTimer(Duration duration) {
    timer?.cancel();
    timer = Timer(duration, dismiss);
  }

  void update(
    AppNotice value,
    String text,
    Duration duration,
    String? label,
    VoidCallback? action,
  ) {
    notice = value;
    message = text;
    actionLabel = label;
    onAction = action;
    key.currentState?.reveal();
    entry.markNeedsBuild();
    resetTimer(duration);
  }

  void dismiss() {
    if (_removed) return;
    timer?.cancel();
    final state = key.currentState;
    if (state == null) {
      remove();
    } else {
      state.dismiss(remove);
    }
  }

  void remove() {
    if (_removed) return;
    _removed = true;
    timer?.cancel();
    entry.remove();
    entry.dispose();
    onRemove();
  }

  void disposed() {
    timer?.cancel();
    if (!_removed) {
      _removed = true;
      // Overlay 整体退出时入口仍关联旧 Overlay，先解除关联才能释放入口。
      entry.remove();
      entry.dispose();
    }
    onRemove();
  }
}

class _NoticeBubble extends StatefulWidget {
  const _NoticeBubble({
    super.key,
    required this.reduced,
    required this.message,
    required this.style,
    required this.foreground,
    required this.onClose,
    required this.onDispose,
    this.actionLabel,
    this.onAction,
  });
  final String message;
  final GlassStyle style;
  final Color foreground;
  final VoidCallback onClose;
  final VoidCallback onDispose;
  final bool reduced;

  /// 可撤销操作的文案；为空时气泡只显示一行消息。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  State<_NoticeBubble> createState() => _NoticeBubbleState();
}

class _NoticeBubbleState extends State<_NoticeBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _exiting = false;
  VoidCallback? _onExit;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
            vsync: this,
            duration: widget.reduced ? Duration.zero : AppMotion.enter,
            reverseDuration: widget.reduced ? Duration.zero : AppMotion.exit,
          )
          ..addStatusListener((status) {
            if (status == AnimationStatus.dismissed && _exiting) {
              _onExit?.call();
            }
          })
          ..forward();
  }

  void reveal() {
    _onExit = null;
    setState(() => _exiting = false);
    _controller.forward();
  }

  void dismiss(VoidCallback onExit) {
    if (_exiting) return;
    setState(() => _exiting = true);
    _onExit = onExit;
    if (widget.reduced || _controller.value == 0) {
      onExit();
    } else {
      _controller.reverse();
    }
  }

  @override
  void didUpdateWidget(covariant _NoticeBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.reduced ? Duration.zero : AppMotion.enter;
    _controller.reverseDuration = widget.reduced
        ? Duration.zero
        : AppMotion.exit;
    if (widget.reduced && !_exiting) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: widget.foreground, height: 1.45);
    // 文字只测量一次；避免 IntrinsicWidth 对可滚动消息做额外布局。
    final painter = TextPainter(
      text: TextSpan(text: widget.message, style: textStyle),
      textDirection: Directionality.of(context),
      textScaler: media.textScaler,
    )..layout();
    final textWidth = painter.width;
    painter.dispose();
    final available = math.max(
      0.0,
      media.size.width -
          math.max(16, media.padding.left) -
          math.max(16, media.padding.right),
    );
    // 预留内容边距、提示图标、间距和关闭按钮触控区域；带撤销时再加一格。
    final bubbleWidth = math.min(
      math.min(560.0, available),
      (textWidth + 100 + (widget.actionLabel == null ? 0 : 76))
          .ceilToDouble(),
    );
    return SafeArea(
      bottom: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: AnimatedSize(
          duration: widget.reduced ? Duration.zero : AppMotion.state,
          curve: AppMotion.curve,
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: bubbleWidth,
            child: Semantics(
              container: true,
              liveRegion: true,
              child: IgnorePointer(
                ignoring: _exiting,
                child: AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) {
                    final value = AppMotion.curve.transform(_controller.value);
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(
                          0,
                          widget.reduced ? 0 : -4 * (1 - value),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: GlassSurface(
                    key: const ValueKey('app-notice'),
                    style: widget.style,
                    radius: GlassRadius.card,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            color: widget.foreground,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight: math.max(
                                  48,
                                  math.min(260, media.size.height * .3),
                                ),
                              ),
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Text(widget.message, style: textStyle),
                              ),
                            ),
                          ),
                          if ((widget.actionLabel, widget.onAction)
                              case (final label?, final action?))
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: TextButton(
                                onPressed: action,
                                style: TextButton.styleFrom(
                                  foregroundColor: widget.foreground,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  minimumSize: const Size(0, 36),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  textStyle: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                child: Text(label),
                              ),
                            ),
                          IconButton(
                            tooltip: '关闭通知',
                            onPressed: widget.onClose,
                            icon: Icon(
                              Icons.close_rounded,
                              color: widget.foreground,
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
