import 'dart:ui' show ImageFilter;

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

  /// 缓存的模糊滤镜；[GlassTier.none] 返回 null。
  late final ImageFilter? filter = translucent
      ? ImageFilter.blur(
          sigmaX: blurSigma,
          sigmaY: blurSigma,
          tileMode: TileMode.clamp,
        )
      : null;

  /// 输入框、按钮等内容控件压在玻璃上时的填充色：
  /// 比玻璃底再深/浅一档，保证控件自身可辨识。
  Color get controlFill => tier == GlassTier.none
      ? const Color(0x00000000)
      : (tint.a >= 0.5
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.white.withValues(alpha: 0.10));

  /// 玻璃上的分隔线：几乎不可见，只用来分组。
  Color get hairline => rimHighlight.withValues(alpha: 0.5);
}

/// 全局解析与缓存入口。
abstract final class GlassStyleResolver {
  /// 缓存上限。正常使用只会有「浅色 / 深色 × 3 档」几个组合，
  /// 留出余量给动态取色变化，超出直接清空，避免无界增长。
  static const _cacheLimit = 12;
  static final _cache = <(ColorScheme, GlassTier), GlassStyle>{};

  /// 当前上下文的玻璃参数。
  ///
  /// 保留用户开关，尊重高对比度与减少动画设置，不在滚动中反复切换档位。
  static GlassStyle of(BuildContext context) {
    final scope = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    final tier =
        !scope.glass ||
            media.highContrast ||
            AppScope.formFactorOf(context) == FormFactor.television
        ? GlassTier.none
        : media.disableAnimations || media.accessibleNavigation
        ? GlassTier.reduced
        : GlassTier.full;
    return _resolve(scheme, tier);
  }

  /// 强制指定档位，用于少数需要覆盖的场景（例如播放器面板永远不做模糊）。
  static GlassStyle tier(BuildContext context, GlassTier tier) =>
      _resolve(Theme.of(context).colorScheme, tier);

  static GlassStyle _resolve(ColorScheme scheme, GlassTier tier) {
    // 完整配色参与缓存；surface 相同但 primary 不同的主题不能复用染色。
    final key = (scheme, tier);
    if (_cache[key] case final cached?) return cached;
    if (_cache.length >= _cacheLimit) _cache.clear();
    return _cache[key] = _build(scheme, tier);
  }

  static GlassStyle _build(ColorScheme scheme, GlassTier tier) {
    if (tier == GlassTier.none) return _opaque(scheme);

    final dark = scheme.brightness == Brightness.dark;
    final reduced = tier == GlassTier.reduced;
    final sigma = reduced ? 10.0 : 18.0;

    // 染色层：以 surface 为主，掺一点 primary 让玻璃带出主题色温，
    // 但不能太多，否则压在图上的文字对比度会被吃掉。
    //
    // 透明度是「像玻璃」和「字能看清」之间的唯一旋钮，取值按最坏情况定：
    // 深色模式玻璃压在一张亮封面上时，0.62 的染色会让底层亮出 0.38，
    // 白字对比度只剩 1.9:1（几乎看不清）；提到 0.76 后回到可接受区间，
    // 同时仍保留约 1/4 的透视。浅色模式同理，0.58 在亮封面上偏灰。
    final base = scheme.surface.withValues(
      alpha: dark ? (reduced ? 0.82 : 0.76) : (reduced ? 0.76 : 0.66),
    );
    final tint = Color.alphaBlend(
      scheme.primary.withValues(alpha: dark ? 0.10 : 0.06),
      base,
    );

    return GlassStyle(
      tier: tier,
      blurSigma: sigma,
      tint: tint,
      sheen: Colors.white.withValues(alpha: dark ? 0.08 : 0.22),
      rimHighlight: Colors.white.withValues(alpha: dark ? 0.28 : 0.75),
      rimShadow: Colors.black.withValues(alpha: dark ? 0.32 : 0.10),
      borderWidth: 1,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: dark ? 0.42 : 0.14),
          blurRadius: 18,
          spreadRadius: -4,
          offset: const Offset(0, 6),
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
  static GlassStyle _opaque(ColorScheme scheme) {
    final dark = scheme.brightness == Brightness.dark;
    return GlassStyle(
      tier: GlassTier.none,
      blurSigma: 0,
      tint: scheme.surfaceContainer,
      sheen: Colors.white.withValues(alpha: dark ? 0.04 : 0.12),
      rimHighlight: scheme.outlineVariant,
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
  static void clearCache() => _cache.clear();
}
