import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';

import 'glass_feedback.dart';

/// 液态玻璃的底层容器。
///
/// 这是整个应用里**唯一**执行背景模糊的实现点。收成一个的原因：
/// `BackdropFilter` 每次都会触发 `saveLayer`，一旦散落到几十个页面里，
/// 降级、限流、层级顺序都会失控，性能问题也无法定位。
///
/// 视觉上由五层叠加而成（由下至上）：
/// 1. 背景模糊 + 半透明染色 → 玻璃本体
/// 2. 顶部内高光 → 玻璃厚度折射出的亮边
/// 3. 底缘折射带 → 下沿被压暗一档，「有厚度」的下沿
/// 4. 环绕内壁的微光 → 左上最亮、右下熄灭，给出光的方向
/// 5. 左上亮 / 右下暗的 1px 渐变描边 → 「像玻璃」而非「像灰底卡片」的关键
///
/// 第 2~5 层由 [_GlassRimPainter] 一次画完，都是纯矢量绘制、不新增离屏层；
/// 外层柔和阴影则由 [Container] 的 `BoxDecoration` 单独绘制。
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
    this.role = GlassRole.surface,
    this.interactive = false,
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
  final GlassRole role;
  final bool interactive;

  /// 是否真的对背景做模糊。
  ///
  /// 列表里的卡片必须关掉：它们背后只是页面底色，糊不出任何东西，
  /// 反而会因为背后的内容变化（相邻卡片、滚动位置）显得染色在变色，
  /// 还要为此多付一次 saveLayer。只有浮在内容上的栏、面板、弹窗才开。
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final glass = style ?? GlassStyleResolver.of(context, role: role);
    final shape = borderRadius ?? BorderRadius.circular(radius);
    // 静态卡片没有背景采样，合成稳定的不透明底色，避免滚动时透出邻卡。
    final tint = blur || role == GlassRole.playback
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

    final surface = Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: shape,
        boxShadow: showShadow ? glass.shadow : null,
      ),
      // 不透明档不裁剪也不模糊，省掉 ClipRRect + BackdropFilter 两层开销。
      child: !glass.translucent || !blur || glass.filter == null
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
    return interactive
        ? GlassFeedback(radius: radius, child: surface)
        : surface;
  }
}

/// 画顶部内高光、底缘折射带、环绕内壁的微光与渐变描边。
///
/// 用 [CustomPaint] 而不是嵌套两层 `Container` + `BoxDecoration`：
/// Flutter 没有内置的「渐变描边」，`Border.all` 只能取单色，
/// 而 `ShaderMask` 会额外引入一次离屏合成。
///
/// 四层全是纯矢量绘制，不新增任何 `saveLayer`：玻璃件的图层预算只留给
/// [BackdropFilter] 那一层，多叠一层离屏合成就会吃掉滚动的帧率。
class _GlassRimPainter extends CustomPainter {
  _GlassRimPainter({required this.shape, required this.style});

  final BorderRadius shape;
  final GlassStyle style;

  /// 一块玻璃用到的四条渐变，按「样式 + 尺寸」缓存。
  ///
  /// 缓存原本挂在 painter 实例上，但绘制时每帧都可能换一个新 painter，
  /// 实例级缓存几乎总是落空：`createShader` 连同它内部的临时
  /// `LinearGradient` 会被重造一遍。改挂到全局表上，键里带上 [GlassStyle]
  /// 身份（样式都取自全局缓存的实例，比较退化成指针比较）与尺寸，
  /// 重建之后照样命中。
  ///
  /// 表有界：玻璃件的尺寸种类本来就有限，超限只丢最旧的一条，
  /// 不清空是为了避免在用的玻璃件同时换到新 Shader。
  static final _gradients = <(GlassStyle, Size), _GlassGradients>{};
  static const _gradientLimit = 48;

  static _GlassGradients _gradientsFor(GlassStyle style, Size size) {
    final key = (style, size);
    if (_gradients[key] case final cached?) return cached;
    if (_gradients.length >= _gradientLimit) {
      _gradients.remove(_gradients.keys.first);
    }
    return _gradients[key] = _GlassGradients(style, size);
  }

  // 填充和描边各复用一个静态 [Paint]：`paint()` 里每帧新建 Paint 纯属浪费，
  // 而 `Canvas` 的绘制调用会立刻把参数记进 display list、不留引用，
  // 所以复用同一个实例不会串色。
  static final _fillPaint = Paint();
  static final _strokePaint = Paint()..style = PaintingStyle.stroke;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final gradients = _gradientsFor(style, size);
    final rrect = shape.toRRect(rect);

    // 顶部内高光：模拟玻璃上缘的厚度，越往下越淡。
    if (style.sheen.a > 0) {
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, gradients.sheenBand),
        _fillPaint..shader = gradients.sheen,
      );
      canvas.restore();
    }

    // 底缘折射带：只压最后一段，给玻璃一个「有厚度」的下沿。
    // 缺这条时玻璃四边一样亮，看起来就是一张贴纸。
    if (style.rimShadow.a > 0) {
      canvas.save();
      canvas.clipRRect(rrect);
      canvas.drawRect(
        Rect.fromLTWH(
          0,
          size.height - gradients.edgeBand,
          size.width,
          gradients.edgeBand,
        ),
        _fillPaint..shader = gradients.edge,
      );
      canvas.restore();
    }

    final width = style.borderWidth;
    if (width <= 0) return;

    // 内壁微光：贴着边内侧再描一圈，左上亮、右下灭。
    // 这一圈才是「液态玻璃」和「半透明灰卡片」的分界：四条边不再同样亮，
    // 玻璃因此读得出厚度，也读得出光是从左上来的。
    if (style.innerGlow.a > 0) {
      canvas.drawRRect(
        shape.toRRect(rect.deflate(width * 1.5)),
        _strokePaint
          ..strokeWidth = width * 2
          ..shader = gradients.glow,
      );
    }

    // 渐变描边：左上亮、右下暗。这 1px 决定了「像玻璃」还是「像灰底卡片」。
    canvas.drawRRect(
      shape.toRRect(rect.deflate(width / 2)),
      _strokePaint
        ..strokeWidth = width
        ..shader = gradients.rim,
    );
  }

  /// 参数来自缓存实例，同一帧内恒等，因此这里可以只比实例。
  @override
  bool shouldRepaint(_GlassRimPainter oldDelegate) =>
      oldDelegate.shape != shape || !identical(oldDelegate.style, style);
}

/// 一块玻璃用到的四条渐变。
///
/// 合成一个对象一起缓存：顶光、底缘折射、内壁微光和描边永远成组使用，
/// 拆开缓存只会把「键 + 淘汰」的逻辑重复四遍。
class _GlassGradients {
  _GlassGradients(GlassStyle style, Size size)
    : sheenBand = style.sheenBand(size.height),
      edgeBand = style.edgeBand(size.height),
      sheen = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [style.sheen, style.sheen.withValues(alpha: 0)],
      ).createShader(
        Rect.fromLTWH(0, 0, size.width, style.sheenBand(size.height)),
      ),
      edge = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          style.rimShadow.withValues(alpha: 0),
          style.rimShadow.withValues(alpha: style.rimShadow.a * .55),
        ],
      ).createShader(
        Rect.fromLTWH(
          0,
          size.height - style.edgeBand(size.height),
          size.width,
          style.edgeBand(size.height),
        ),
      ),
      glow = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [style.innerGlow, style.innerGlow.withValues(alpha: 0)],
      ).createShader(Offset.zero & size),
      rim = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          style.rimHighlight,
          style.rimHighlight.withValues(alpha: style.rimHighlight.a * 0.24),
          style.rimShadow,
        ],
        stops: const [0, 0.5, 1],
      ).createShader(Offset.zero & size);

  /// 顶光需要覆盖的高度，[GlassStyle] 已按比例做过像素封顶。
  final double sheenBand;

  /// 底缘折射带需要覆盖的高度。
  final double edgeBand;

  final Shader sheen;
  final Shader edge;
  final Shader glow;
  final Shader rim;
}
