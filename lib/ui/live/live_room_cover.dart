import 'package:flutter/material.dart';

import '../app_motion.dart';

/// 直播封面只加载展示地址，不伪装成短剧调用原生目录/权限/解密接口。
///
/// 直播列表和收藏页都走这里：解码宽度按实际显示尺寸取档，滚动时命中
/// Flutter 的内存图片缓存；加载完成用短淡入代替「啪」地出现。
class LiveRoomCover extends StatelessWidget {
  const LiveRoomCover({super.key, required this.url, this.radius = 12});
  final String url;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final placeholder = ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Icon(Icons.live_tv_rounded, color: colors.onSurfaceVariant),
      ),
    );
    final reduced = AppMotion.reduced(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (url.isEmpty ||
              const bool.fromEnvironment('DISABLE_REMOTE_IMAGES')) {
            return placeholder;
          }
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : 280.0;
          return Image.network(
            url,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            // 缩略图不需要高质量重采样：默认 medium 在大列表里纯耗 GPU。
            filterQuality: FilterQuality.low,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 1200),
            excludeFromSemantics: true,
            frameBuilder: (context, child, frame, synchronous) {
              if (synchronous || reduced) return child;
              return AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: AppMotion.duration(context, AppMotion.state),
                curve: AppMotion.curve,
                child: child,
              );
            },
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      ),
    );
  }
}
