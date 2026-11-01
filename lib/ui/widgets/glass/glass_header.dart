import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';
import 'glass_surface.dart';

/// 悬浮玻璃顶栏。
///
/// 用法是一条固定套路：页面用 `Stack` 叠两层，滚动内容铺满、顶栏贴顶，
/// 再把量出来的高度作为滚动视图顶部的占位塞进去。
///
/// 为什么必须量高度而不能写死：顶栏里除了标题/搜索行，还会塞一条分类条，
/// 分类条在不同形态下高度不同；写死一旦对不上，内容要么被永久压住一截，
/// 要么顶部留出一条空白。
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    super.key,
    required this.child,
    required this.onHeight,
    this.showShadow = true,
  });

  final Widget child;
  final bool showShadow;

  /// 顶栏实际占位高度（含外边距），布局完成后回调。
  final ValueChanged<double> onHeight;

  @override
  Widget build(BuildContext context) => SizeReporter(
    onSize: (size) => onHeight(size.height),
    child: Padding(
      // 左右留出边距让胶囊浮起来；顶部留 8 让它不贴着状态栏发闷。
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: GlassSurface(
        role: GlassRole.chrome,
        radius: GlassRadius.bar,
        showShadow: showShadow,
        child: child,
      ),
    ),
  );
}

/// 上报子组件尺寸。
///
/// 用 `SizeChangedLayoutNotifier` 而不是自己写 RenderObject：它的通知本来
/// 就推迟到帧末派发，天然避开「布局阶段 setState」的坑，也不用额外依赖
/// `package:flutter/rendering.dart`。
class SizeReporter extends StatelessWidget {
  const SizeReporter({super.key, required this.onSize, required this.child});

  final ValueChanged<Size> onSize;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizeChangedLayoutNotifier(
    child: NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) onSize(box.size);
        return true;
      },
      child: child,
    ),
  );
}
