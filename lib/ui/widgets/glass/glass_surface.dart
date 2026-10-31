import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';

/// 液态玻璃的底层容器。
///
/// 这是整个应用里**唯一**执行背景模糊的实现点。收成一个的原因：
/// `BackdropFilter` 每次都会触发 `saveLayer`，一旦散落到几十个页面里，
/// 降级、限流、层级顺序都会失控，性能问题也无法定位。
///
/// 视觉上由四层叠加而成（由下至上）：
/// 1. 背景模糊 + 半透明染色 → 玻璃本体
/// 2. 顶部内高光 → 玻璃厚度折射出的亮边
/// 3. 左上亮 / 右下暗的 1px 渐变描边 → 「有厚度」的关键
/// 4. 外层柔和阴影 → 与下层的分离感
///
/// 当档位为 [GlassTier.none]（电视形态或用户关闭玻璃）时，
/// 自动退化为不透明容器，不再创建任何图层。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = GlassRadius.card,
    this.borderRadius,
    this.padding,
    this.margin,
    this.style,
    this.showShadow = true,
    this.blur = true,
  });

  final Widget child;

  /// 四角一致的圆角。需要逐角控制时改用 [borderRadius]。
  final double radius;

  /// 逐角圆角，优先于 [radius]。
  ///
  /// 主要用于底部弹出面板：只有上面两角需要圆，贴着屏幕底边的两角
  /// 若也圆起来，会从缝隙里透出背后的内容。
  final BorderRadius? borderRadius;

  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;

  /// 覆盖默认解析出的玻璃参数，用于局部微调（例如需要更薄的染色）。
  final GlassStyle? style;

  final bool showShadow;

  /// 是否真的对背景做模糊。
  ///
  /// 列表里的卡片必须关掉：它们背后只是页面底色，糊不出任何东西，
  /// 反而会因为背后的内容变化（相邻卡片、滚动位置）显得染色在变色，
  /// 还要为此多付一次 saveLayer。只有浮在内容上的栏、面板、弹窗才开。
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final glass = style ?? GlassStyleResolver.of(context);
    final shape = borderRadius ?? BorderRadius.circular(radius);
    // 静态卡片没有背景采样，合成稳定的不透明底色，避免滚动时透出邻卡。
    final tint = blur
        ? glass.tint
        : Color.alphaBlend(glass.tint, Theme.of(context).colorScheme.surface);
    final body = Padding(padding: padding ?? EdgeInsets.zero, child: child);

    // 背景交给 Material 绘制，避免装饰层盖住 InkWell / ListTile 的墨水反馈。
    final content = Material(
      color: tint,
      borderRadius: shape,
      child: CustomPaint(
        painter: _GlassRimPainter(shape: shape, style: glass),
        child: body,
      ),
    );

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: showShadow ? glass.shadow : null,
      ),
      // 不透明档不裁剪也不模糊，省掉 ClipRRect + BackdropFilter 两层开销。
      child: !glass.translucent || !blur
          ? content
          : ClipRRect(
              borderRadius: shape,
              child: BackdropFilter(
                filter: glass.filter!,
                // 顶/底栏的淡出使用离屏层，src 避免背景在该层内再次混色变暗。
                blendMode: BlendMode.src,
                child: RepaintBoundary(child: content),
              ),
            ),
    );
  }
}

/// 画顶部内高光与渐变描边。
///
/// 用 [CustomPaint] 而不是嵌套两层 `Container` + `BoxDecoration`：
/// Flutter 没有内置的「渐变描边」，`Border.all` 只能取单色，
/// 而 `ShaderMask` 会额外引入一次离屏合成。
class _GlassRimPainter extends CustomPainter {
  const _GlassRimPainter({required this.shape, required this.style});

  final BorderRadius shape;
  final GlassStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;

    // 顶部内高光：模拟玻璃上缘的厚度，越往下越淡。
    if (style.sheen.a > 0) {
      canvas.save();
      canvas.clipRRect(shape.toRRect(rect));
      final sheenRect = Rect.fromLTWH(0, 0, size.width, size.height * 0.62);
      canvas.drawRect(
        sheenRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [style.sheen, style.sheen.withValues(alpha: 0)],
          ).createShader(sheenRect),
      );
      canvas.restore();
    }

    // 渐变描边：左上亮、右下暗。这 1px 决定了「像玻璃」还是「像灰底卡片」。
    final width = style.borderWidth;
    if (width > 0) {
      canvas.drawRRect(
        shape.toRRect(rect.deflate(width / 2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              style.rimHighlight,
              style.rimHighlight.withValues(alpha: style.rimHighlight.a * 0.24),
              style.rimShadow,
            ],
            stops: const [0, 0.5, 1],
          ).createShader(rect),
      );
    }
  }

  /// 参数来自缓存实例，同一帧内恒等，因此这里可以只比实例。
  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.shape != shape || !identical(oldDelegate.style, style);
}
