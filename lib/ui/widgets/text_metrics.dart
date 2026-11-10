import 'package:flutter/material.dart';

/// 单行文本测量的记忆化。
///
/// 测量本身（字体整形 + 布局）比构造比较键贵得多，而这些测量点都落在 build 与
/// 列表项里反复执行，输入不变时结果恒定。键包含**所有**影响结果的输入（文案、
/// 完整样式、缩放器、方向、行数），所以命中缓存与现场重测逐像素等价；
/// 只缓存结果，不换公式，不会引入亚像素差异。
({double width, double height}) measureTextLine({
  required String text,
  required TextStyle? style,
  required TextScaler scaler,
  required TextDirection direction,
  int? maxLines = 1,
}) {
  final key = (text, style, scaler, direction, maxLines);
  final cached = _lines[key];
  if (cached != null) return cached;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: direction,
    textScaler: scaler,
    maxLines: maxLines,
  )..layout();
  final result = (width: painter.width, height: painter.height);
  painter.dispose();
  // 有界缓存：键里带样式与文案，量级由可见项决定，超出就整体丢弃而不是无限增长。
  if (_lines.length >= 512) _lines.clear();
  return _lines[key] = result;
}

final _lines =
    <(String, TextStyle?, TextScaler, TextDirection, int?), ({double width, double height})>{};
