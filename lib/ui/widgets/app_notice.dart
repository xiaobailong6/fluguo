import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../theme/glass_style.dart';
import 'glass/glass_surface.dart';

/// 应用内瞬时反馈统一走顶部气泡；确认、输入和进度对话框不属于通知。
void showAppNotice(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 4),
}) {
  if (!context.mounted) return;
  AppNotice.of(context).show(message, duration: duration);
}

/// 可在 await 前捕获，完成后只检查根 Overlay，不再访问已退出页面的 context。
class AppNotice {
  AppNotice._(this._overlay, this._theme, this._style, this._foreground);

  final OverlayState? _overlay;
  final ThemeData _theme;
  final GlassStyle _style;
  final Color _foreground;
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

  void show(String message, {Duration duration = const Duration(seconds: 4)}) {
    final overlay = _overlay;
    if (overlay == null || !overlay.mounted || message.trim().isEmpty) return;
    // 同一根导航只保留最新提示，避免连续失败把顶部堆满。
    _active[overlay]?.dismiss();
    late final _NoticeHandle handle;
    final entry = OverlayEntry(
      builder: (context) => Positioned(
        left: 0,
        right: 0,
        top: 0,
        child: Theme(
          data: _theme,
          child: _NoticeBubble(
            message: message,
            style: _style,
            foreground: _foreground,
            onClose: () => handle.dismiss(),
            onDispose: () => handle.disposed(),
          ),
        ),
      ),
    );
    handle = _NoticeHandle(entry, () {
      if (identical(_active[overlay], handle)) _active[overlay] = null;
    });
    _active[overlay] = handle;
    overlay.insert(entry);
    handle.timer = Timer(duration, handle.dismiss);
  }
}

class _NoticeHandle {
  _NoticeHandle(this.entry, this.onRemove);
  final OverlayEntry entry;
  final VoidCallback onRemove;
  Timer? timer;
  bool _removed = false;

  void dismiss() {
    if (_removed) return;
    _removed = true;
    timer?.cancel();
    entry.remove();
    entry.dispose();
    onRemove();
  }

  void disposed() {
    timer?.cancel();
    onRemove();
  }
}

class _NoticeBubble extends StatefulWidget {
  const _NoticeBubble({
    required this.message,
    required this.style,
    required this.foreground,
    required this.onClose,
    required this.onDispose,
  });
  final String message;
  final GlassStyle style;
  final Color foreground;
  final VoidCallback onClose;
  final VoidCallback onDispose;

  @override
  State<_NoticeBubble> createState() => _NoticeBubbleState();
}

class _NoticeBubbleState extends State<_NoticeBubble> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return SafeArea(
      bottom: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Semantics(
            container: true,
            liveRegion: true,
            child: TweenAnimationBuilder<double>(
              duration: media.disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              tween: Tween(begin: 0, end: 1),
              builder: (context, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, -8 * (1 - value)),
                  child: child,
                ),
              ),
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
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              widget.message,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: widget.foreground,
                                    height: 1.45,
                                  ),
                            ),
                          ),
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
    );
  }
}
