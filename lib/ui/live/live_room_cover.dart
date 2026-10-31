import 'package:flutter/material.dart';

/// 直播封面只加载展示地址，不伪装成短剧调用原生目录/权限/解密接口。
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
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .ceil()
                .clamp(1, 1200),
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => placeholder,
          );
        },
      ),
    );
  }
}
