import 'package:flutter/material.dart';

import '../../live_models.dart';

/// 按两行文字的实际排版撑高；60/40 只作普通字号下的最小高度。
class LivePlaybackHeader extends StatelessWidget {
  const LivePlaybackHeader({
    super.key,
    required this.room,
    required this.quality,
    required this.stats,
    required this.favorite,
    required this.onBack,
  });

  final LiveRoom room;
  final String? quality;
  final Widget stats;
  final Widget favorite;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    const shadow = [Shadow(color: Color(0x66000000), blurRadius: 2)];
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 60),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          spacing: 2,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back_rounded),
              color: Colors.white,
              tooltip: '返回',
              style: IconButton.styleFrom(fixedSize: const Size.square(48)),
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    constraints: const BoxConstraints(minHeight: 40),
                    alignment: Alignment.centerLeft,
                    child: Text(
                      room.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        shadows: shadow,
                      ),
                    ),
                  ),
                  Text(
                    [
                      if (room.anchor.isNotEmpty) room.anchor,
                      ?quality,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: .78),
                      fontSize: 12,
                      shadows: shadow,
                    ),
                  ),
                ],
              ),
            ),
            // 可选的时钟/网速只取所需宽度，大字时也要给房间信息留出空间。
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: constraints.maxWidth / 3),
              child: stats,
            ),
            SizedBox.square(dimension: 40, child: favorite),
          ],
        ),
      ),
    );
  }
}
