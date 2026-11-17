import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../danmaku_emoji.dart';

class _Run {
  _Run(this.segment, this.fill, this.outline, this.width);
  final DanmakuSegment segment;
  final TextPainter fill;
  final TextPainter? outline;
  final double width;
}

/// 测宽和绘制共享同一组 TextPainter / TextScaler。
/// 每个已知表情预留 max(图片边长, 原始 [名称] 宽度)，加载成功/失败都不改宽，
/// 因而异步图片不能突破排期碰撞保护，也不改变原有 1.5 倍行高或轨道数。
class DanmakuEmojiLayout {
  DanmakuEmojiLayout(
    List<DanmakuSegment> segments, {
    required TextStyle style,
    required TextStyle? outline,
    required TextScaler scaler,
  }) : extent = scaler.scale(style.fontSize!),
       opacity = style.color?.a ?? 1 {
    TextPainter painter(String text, TextStyle style) => TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    for (final segment in segments) {
      final fill = painter(segment.text, style);
      final stroke = outline == null ? null : painter(segment.text, outline);
      final width = segment.asset == null
          ? fill.width
          : math.max(extent, fill.width);
      _runs.add(_Run(segment, fill, stroke, width));
      this.width += width;
      height = math.max(height, fill.height);
    }
  }

  final _runs = <_Run>[];
  final double extent;
  final double opacity;
  double width = 0;
  double height = 0;

  void load(DanmakuEmojiCache cache) {
    for (final run in _runs) {
      final asset = run.segment.asset;
      if (asset != null) unawaited(cache.load(asset));
    }
  }

  void paint(Canvas canvas, DanmakuEmojiCache cache) {
    var x = 0.0;
    for (final run in _runs) {
      final asset = run.segment.asset;
      final image = asset == null ? null : cache.image(asset);
      if (image == null) {
        final offset = Offset(x, 0);
        run.outline?.paint(canvas, offset);
        run.fill.paint(canvas, offset);
      } else {
        paintImage(
          canvas: canvas,
          rect: Rect.fromLTWH(
            x + (run.width - extent) / 2,
            math.max(0, (height - extent) / 2),
            extent,
            extent,
          ),
          image: image,
          fit: BoxFit.contain,
          opacity: opacity,
          filterQuality: FilterQuality.low,
        );
      }
      x += run.width;
    }
  }

  void dispose() {
    for (final run in _runs) {
      run.fill.dispose();
      run.outline?.dispose();
    }
  }
}

class DanmakuEmojiText extends StatefulWidget {
  const DanmakuEmojiText({super.key, required this.layout, this.cache});
  final DanmakuEmojiLayout layout;
  final DanmakuEmojiCache? cache;

  @override
  State<DanmakuEmojiText> createState() => _DanmakuEmojiTextState();
}

class _DanmakuEmojiTextState extends State<DanmakuEmojiText> {
  @override
  void initState() {
    super.initState();
    widget.layout.load(widget.cache ?? DanmakuEmojiCache.shared);
  }

  @override
  void didUpdateWidget(DanmakuEmojiText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.layout != widget.layout || oldWidget.cache != widget.cache) {
      widget.layout.load(widget.cache ?? DanmakuEmojiCache.shared);
    }
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size(widget.layout.width, widget.layout.height),
    painter: _EmojiPainter(
      widget.layout,
      widget.cache ?? DanmakuEmojiCache.shared,
    ),
  );
}

class _EmojiPainter extends CustomPainter {
  _EmojiPainter(this.layout, this.cache) : super(repaint: cache);
  final DanmakuEmojiLayout layout;
  final DanmakuEmojiCache cache;

  @override
  void paint(Canvas canvas, Size size) => layout.paint(canvas, cache);

  @override
  bool shouldRepaint(_EmojiPainter oldDelegate) =>
      oldDelegate.layout != layout || oldDelegate.cache != cache;
}
