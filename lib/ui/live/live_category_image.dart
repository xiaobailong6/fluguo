import 'package:flutter/material.dart';

import '../../live_models.dart';

/// 每张可见卡片只订阅一次封面 Future，状态更新不会反复请求平台。
class LiveCategoryImage extends StatefulWidget {
  const LiveCategoryImage({
    super.key,
    required this.platform,
    required this.category,
    required this.fallback,
    this.imagesEnabled = !const bool.fromEnvironment('DISABLE_REMOTE_IMAGES'),
  });
  final LivePlatform platform;
  final LiveCategory category;
  final Widget fallback;
  final bool imagesEnabled;

  @override
  State<LiveCategoryImage> createState() => _LiveCategoryImageState();
}

class _LiveCategoryImageState extends State<LiveCategoryImage> {
  Future<String>? _picture;

  void _load() {
    _picture = !widget.imagesEnabled
        ? null
        : Future<String>.sync(
            () => widget.platform.categoryPicture(widget.category),
          ).catchError((Object _) => '');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LiveCategoryImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.platform, widget.platform) ||
        oldWidget.category != widget.category ||
        oldWidget.category.picture != widget.category.picture ||
        oldWidget.imagesEnabled != widget.imagesEnabled) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: _picture,
    builder: (context, snapshot) {
      final url = snapshot.connectionState == ConnectionState.done
          ? snapshot.data ?? ''
          : '';
      if (url.isEmpty) return widget.fallback;
      return LayoutBuilder(
        builder: (context, constraints) => Image.network(
          url,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          cacheWidth:
              ((constraints.maxWidth.isFinite ? constraints.maxWidth : 180) *
                      MediaQuery.devicePixelRatioOf(context))
                  .ceil()
                  .clamp(1, 1200),
          errorBuilder: (_, _, _) => widget.fallback,
        ),
      );
    },
  );
}
