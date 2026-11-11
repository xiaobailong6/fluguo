import 'dart:ui' show ColorFilter, ImageFilter;

import 'package:flutter/material.dart';

import '../app_scope.dart';

/// 液态玻璃的渲染档位。
///
/// - [full]：完整模糊 + 高光描边，手机 / 平板 / 桌面使用。
/// - [reduced]：降低模糊半径，用于省电模式或性能受限设备。
/// - [none]：完全不透明，电视端与用户关闭玻璃效果时使用。
///
/// 降级是硬性要求：`BackdropFilter` 每帧都要 `saveLayer`，
/// 电视盒子与低端 Android 上满屏模糊必然掉帧。
enum GlassTier { full, reduced, none }

/// 用途决定材质厚度，而非每个页面自行拼一套透明度和阴影。
enum GlassRole { surface, chrome, panel, playback }

/// 常驻组件的玻璃「厚度预设」。
///
/// 同一类浮层只能取同一个预设，避免各页面各写一个 `thinned(tintAlpha: …)`
/// 数字：改观感时只动这里，也不会出现两个本该一致的菜单厚薄不同。
enum GlassPreset {
  /// 浮在封面/视频上的小圆钮（三点按钮等）：几乎只是一层薄雾。
  control(GlassRole.chrome, .14),

  /// 锚定在按钮旁的小菜单：要能读清文字，又保留背后透视。
  menu(GlassRole.panel, .48),

  /// 覆盖在列表上的任务/详情面板：面积大、文案长，染色要足以压住背后的
  /// 海报与列表文字，否则长句会跟着背景一起「跳」。
  panel(GlassRole.panel, .30),

  /// 屏幕中央的对话框：背后可能是列表或播放画面，需要比菜单更实的染色
  /// 才能保证标题、正文和输入框的可读性。
  dialog(GlassRole.panel, .62),

  /// 播放页内的浮层：背后是逐帧变化的视频，沿用零模糊的深色配方。
  playback(GlassRole.playback, .80);

  const GlassPreset(this.role, this.tintAlpha);

  final GlassRole role;
  final double tintAlpha;
}

/// 圆角阶。所有玻璃件的圆角都从这里取，避免散落的字面量再次失控。
abstract final class GlassRadius {
  /// 胶囊（底部 tab、单选按钮）。
  static const double pill = 999;

  /// 顶栏 / 底栏这类横向条。
  static const double bar = 26;

  /// 卡片、分组容器。
  static const double card = 20;

  /// 底部弹出面板。
  static const double sheet = 28;

  /// 对话框。
  static const double dialog = 28;

  /// 同心圆角：内层元素比外层收 [inset] 时，圆角必须同步内收，
  /// 否则两层弧线不平行，视觉上会“发胖”。
  static double nested(double outer, double inset) =>
      outer - inset <= 2 ? 2 : outer - inset;
}

/// 一套已解析好的玻璃视觉参数。
///
/// 由 [GlassStyle.of] 按「当前亮度 + 配色 + 形态」生成并缓存，
/// 组件只读不改，保证同一帧内所有玻璃件的滤镜实例一致
/// （`ImageFilter` 每次新建会额外触发 filter 缓存失效）。
@immutable
class GlassStyle {
  GlassStyle({
    required this.tier,
    required this.blurSigma,
    required this.tint,
    required this.sheen,
    required this.rimHighlight,
    required this.rimShadow,
    required this.shadow,
    required this.borderWidth,
  });

  final GlassTier tier;

  /// 背景模糊半径。0 表示不做模糊。
  final double blurSigma;

  /// 半透明染色层，叠在模糊后的背景之上。
  final Color tint;

  /// 顶部内高光，模拟玻璃厚度折射出的亮边。
  final Color sheen;

  /// 描边左上角的高光色。
  final Color rimHighlight;

  /// 描边右下角的暗部色。
  final Color rimShadow;

  final List<BoxShadow> shadow;
  final double borderWidth;

  /// 是否需要模糊。为 false 时调用方跳过 `BackdropFilter` 与 `ClipRRect`，
  /// 直接画不透明底，省掉整个图层。
  bool get translucent => tier != GlassTier.none;

  /// 背景滤镜：先提饱和，再做高斯模糊。
  ///
  /// 只模糊不提饱和的玻璃会「发灰」：高斯模糊把背景的高频细节抹平，
  /// 平均值本身就是一块低饱和的灰，压在深色内容上像磨砂塑料。
  /// 真实玻璃折射时会轻微增强色度，这里用一条饱和矩阵补回来。
  /// 顺序必须是「先饱和、后模糊」，反了的话模糊又把色度抹平。
  ///
  /// 两段滤镜合成为一个 [ImageFilter]，`BackdropFilter` 仍然只开一层，
  /// 不会因为多一段而多一次离屏合成。
  late final ImageFilter? filter = translucent && blurSigma > 0
      ? ImageFilter.compose(
          inner: _backdropSaturation,
          outer: ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
            tileMode: TileMode.clamp,
          ),
        )
      : null;

  /// 背景提饱和矩阵（约 1.18 倍，只动色度不动亮度）。
  ///
  /// 系数按 Rec.601 亮度权重预先算好写死：每个玻璃件都复用它，
  /// 运行期没有必要再做一次矩阵运算。
  static final ColorFilter _backdropSaturation = ColorFilter.matrix(
    const <double>[
      1.14166, -0.12870, -0.01296, 0, 0, //
      -0.03834, 1.05130, -0.01296, 0, 0, //
      -0.03834, -0.12870, 1.16704, 0, 0, //
      0, 0, 0, 1, 0, //
    ],
  );

  /// 环绕内壁的一圈微光，左上最亮、右下熄灭。
  ///
  /// 描边只描出一条轮廓，真正让玻璃「有厚度」的是这圈贴在边内侧的光。
  /// 它由描边高光派生，因此播放器面板（零模糊的半透明白）和关闭玻璃后的
  /// 不透明档都自动拿到合适的强度，不必各自再配一份。
  ///
  /// [sheen] 被调用方清零时这里也一起熄掉：通知浮层刻意不叠任何白色高光，
  /// 好让算出来的最小对比度不被额外混色破坏，这层微光正好压在它算过的
  /// 底色的边缘上，必须跟着关。
  ///
  /// 和 [filter] 一样缓存成 `late final`：绘制时每帧取用，现算会多产生一个临时
  /// [Color]，而玻璃件在滚动列表里有一大批。
  late final Color innerGlow = sheen.a > 0
      ? rimHighlight.withValues(alpha: rimHighlight.a * .34)
      : const Color(0x00000000);

  /// 顶部内高光带的绝对高度上限。
  ///
  /// 高光带按容器高度的 36% 铺，在卡片上没问题，一到高容器上就穿帮：
  /// 高光在 36% 处戛然而止，横向拉出一条看得见的接缝，高的侧栏和竖屏面板
  /// 都会踩到。所以比例之外再加一层像素封顶。
  static const double _maxSheenBand = 44;

  /// 底缘折射带的绝对上限。
  ///
  /// 同上：按 22% 算出的高度在高容器上会把整个下三分之一涂成一块脏灰，
  /// 把半透明玻璃的透视感一起吃掉。
  static const double _maxEdgeBand = 34;

  /// 顶光实际需要覆盖的高度。
  double sheenBand(double height) {
    final band = height * .36;
    return band > _maxSheenBand ? _maxSheenBand : band;
  }

  /// 底缘折射带实际需要覆盖的高度。
  double edgeBand(double height) {
    final band = height * .22;
    return band > _maxEdgeBand ? _maxEdgeBand : band;
  }

  /// 输入框、按钮等内容控件压在玻璃上时的填充色：
  /// 比玻璃底再深/浅一档，保证控件自身可辨识。
  Color get controlFill => tier == GlassTier.none
      ? const Color(0x00000000)
      : (tint.a >= 0.5
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.10));

  /// 玻璃上的分隔线：几乎不可见，只用来分组。
  Color get hairline => rimHighlight.withValues(alpha: 0.5);

  /// 派生一档「更透」的玻璃：模糊加厚、染色减薄，透视感更强。
  ///
  /// 用于压在整页内容上的大弹层（分类/分区选择等）：背景靠更重的模糊
  /// 保住可读性，染色变薄后能真正透出后面的内容和色彩。
  /// [GlassTier.none] 时原样返回，不透明档没有「更透」可言。
  ///
  /// 结果按派生参数缓存：列表里的卡片/胶囊每次重建都会调用它，每次返回新
  /// 实例就等于每帧新建一个 `ImageFilter`，滤镜缓存随之中断（见类注释）。
  /// 缓存键包含基类实例，配色或档位一变自然失配。
  GlassStyle thinned({required double tintAlpha, double? blurSigma}) {
    if (tier == GlassTier.none) return this;
    final sigma = blurSigma ?? this.blurSigma;
    final key = (this, tintAlpha, sigma);
    final cached = _derived[key];
    if (cached != null) return cached;
    // 满员时只淘汰最旧的一条：整表清空会让在用玻璃件全部换到新实例，
    // 等于同一帧里重建多个 `ImageFilter`，GPU 那边的滤镜缓存跟着作废。
    if (_derived.length >= _derivedLimit) _derived.remove(_derived.keys.first);
    return _derived[key] = GlassStyle(
      tier: tier,
      blurSigma: sigma,
      tint: tint.withValues(alpha: tintAlpha),
      sheen: sheen,
      rimHighlight: rimHighlight,
      rimShadow: rimShadow,
      shadow: shadow,
      borderWidth: borderWidth,
    );
  }

  /// 派生档缓存：键为（基类实例, 染色透明度, 模糊半径）。
  static final _derived = <(GlassStyle, double, double), GlassStyle>{};
  static const _derivedLimit = 32;
}

/// 全局解析与缓存入口。
abstract final class GlassStyleResolver {
  /// 缓存包含亮度、档位和用途，留出动态取色变化的有界余量。
  static const _cacheLimit = 32;
  static final _cache =
      <((Brightness, Color, Color, Color, Color), GlassTier, GlassRole), GlassStyle>{};

  /// 当前上下文的玻璃参数。
  ///
  /// 保留用户开关，尊重高对比度与减少动画设置，不在滚动中反复切换档位。
  static GlassStyle of(
    BuildContext context, {
    GlassRole role = GlassRole.surface,
  }) {
    final scope = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    // 只订阅真正决定档位的三个开关：整份 MediaQuery 会把键盘开合、文本缩放
    // 这类无关变化也算成依赖，让每个玻璃件（各自带一层 saveLayer）跟着重建。
    final tier =
        !scope.glass ||
            MediaQuery.highContrastOf(context) ||
            AppScope.formFactorOf(context) == FormFactor.television
        ? GlassTier.none
        : MediaQuery.disableAnimationsOf(context) ||
              MediaQuery.accessibleNavigationOf(context)
        ? GlassTier.reduced
        : GlassTier.full;
    return _resolve(scheme, tier, role);
  }

  /// 按 [GlassPreset] 取材质：内部同时决定用途与染色厚度。
  ///
  /// [GlassStyle.thinned] 在 [GlassTier.none] 时原样返回，所以电视端或用户
  /// 关闭玻璃后自动退回该用途的实心配方，不需要调用方再判断档位。
  static GlassStyle preset(BuildContext context, GlassPreset preset) =>
      of(context, role: preset.role).thinned(tintAlpha: preset.tintAlpha);

  /// 强制指定档位，用于少数需要覆盖的场景（例如播放器面板永远不做模糊）。
  static GlassStyle tier(
    BuildContext context,
    GlassTier tier, {
    GlassRole role = GlassRole.surface,
  }) => _resolve(Theme.of(context).colorScheme, tier, role);

  static GlassStyle _resolve(
    ColorScheme scheme,
    GlassTier tier,
    GlassRole role,
  ) {
    // 用途和配色均参与缓存，弹层/顶栏不互用滤镜或染色。
    final key = (_schemeKey(scheme), tier, role);
    if (_cache[key] case final cached?) return cached;
    if (_cache.length >= _cacheLimit) _cache.remove(_cache.keys.first);
    return _cache[key] = _build(scheme, tier, role);
  }

  /// 只取 [ColorScheme] 里真正参与颜色计算的五个字段当缓存键。
  ///
  /// 直接拿整份 [ColorScheme] 做键，每次解析都要对它做 40 多个字段的深哈希与
  /// 深比较；玻璃件在每个页面里都有几份，这笔开销纯属白花。
  /// [Color] 之间是整数比较，代价可以忽略。
  static (Brightness, Color, Color, Color, Color) _schemeKey(
    ColorScheme scheme,
  ) => (
    scheme.brightness,
    scheme.surface,
    scheme.primary,
    scheme.surfaceContainer,
    scheme.outlineVariant,
  );

  static GlassStyle _build(ColorScheme scheme, GlassTier tier, GlassRole role) {
    if (tier == GlassTier.none) return _opaque(scheme, role);

    final dark = scheme.brightness == Brightness.dark;
    final reduced = tier == GlassTier.reduced;
    if (role == GlassRole.playback) {
      return GlassStyle(
        tier: tier,
        blurSigma: 0,
        tint: const Color(0xC2000000),
        sheen: Colors.white.withValues(alpha: .025),
        rimHighlight: const Color(0x66FFFFFF),
        rimShadow: Colors.transparent,
        shadow: const [],
        borderWidth: 1,
      );
    }
    final panel = role == GlassRole.panel;
    final chrome = role == GlassRole.chrome;
    final sigma = reduced ? 10.0 : 18.0;

    // 染色层：以 surface 为主，掺一点 primary 让玻璃带出主题色温，
    // 但不能太多，否则压在图上的文字对比度会被吃掉。
    //
    // 透明度是「像玻璃」和「字能看清」之间的唯一旋钮，取值按最坏情况定：
    // 深色模式玻璃压在一张亮封面上时，0.62 的染色会让底层亮出 0.38，
    // 白字对比度只剩 1.9:1（几乎看不清）；提到 0.76 后回到可接受区间，
    // 同时仍保留约 1/4 的透视。浅色模式同理，0.58 在亮封面上偏灰。
    final base = scheme.surface.withValues(
      alpha: panel
          ? (dark ? .86 : .82)
          : dark
          ? (reduced ? 0.82 : 0.76)
          : (reduced ? 0.76 : 0.66),
    );
    final tint = Color.alphaBlend(
      scheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
      base,
    );

    return GlassStyle(
      tier: tier,
      blurSigma: sigma,
      tint: tint,
      sheen: Colors.white.withValues(
        alpha: chrome ? (dark ? .04 : .10) : (dark ? .06 : .16),
      ),
      rimHighlight: Colors.white.withValues(
        alpha: chrome ? (dark ? .32 : .66) : (dark ? .28 : .70),
      ),
      rimShadow: Colors.black.withValues(alpha: dark ? .22 : .08),
      borderWidth: 1,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(
            alpha: chrome ? (dark ? .25 : .09) : (dark ? .34 : .12),
          ),
          blurRadius: chrome ? 14 : 20,
          spreadRadius: chrome ? -5 : -4,
          offset: Offset(0, chrome ? 4 : 8),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.20 : 0.06),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ],
    );
  }

  /// 不透明档：仍然保留阴影与描边，让关闭玻璃后层级不至于糊成一片，
  /// 只是不再有透视。电视端依赖它保证焦点环对比度。
  static GlassStyle _opaque(ColorScheme scheme, GlassRole role) {
    final dark = scheme.brightness == Brightness.dark;
    return GlassStyle(
      tier: GlassTier.none,
      blurSigma: 0,
      tint: role == GlassRole.playback ? Colors.black : scheme.surfaceContainer,
      sheen: Colors.white.withValues(alpha: dark ? 0.04 : 0.12),
      rimHighlight: role == GlassRole.playback
          ? Colors.white38
          : scheme.outlineVariant,
      rimShadow: Colors.transparent,
      borderWidth: 1,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.32 : 0.10),
          blurRadius: 16,
          spreadRadius: -6,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  @visibleForTesting
  static void clearCache() {
    _cache.clear();
    GlassStyle._derived.clear();
  }
}
