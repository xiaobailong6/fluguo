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
  _bindFontInvalidation();
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

/// 定宽多行溢出判定（`didExceedMaxLines`）的记忆化。
///
/// 与 [measureTextLine] 同样的原则：仍用 `TextPainter` 现场布局一次，只是把
/// 结果记下来复用，不换估算公式。键包含文案、完整样式、行数、可用宽度、缩放器
/// 与书写方向，因此命中缓存与重测等价。
///
/// 只在需要“是否被截断”时使用；要拿具体宽高请用 [measureTextLine]（它不带
/// 宽度约束，两者结果不能互相替代）。
bool exceedsLines({
  required String text,
  required TextStyle style,
  required int maxLines,
  required double width,
  required TextScaler scaler,
  required TextDirection direction,
}) {
  _bindFontInvalidation();
  final key = (text, style, maxLines, width, scaler, direction);
  final cached = _overflow[key];
  if (cached != null) return cached;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: maxLines,
    textDirection: direction,
    textScaler: scaler,
  )..layout(maxWidth: width);
  final result = painter.didExceedMaxLines;
  painter.dispose();
  if (_overflow.length >= 256) _overflow.clear();
  return _overflow[key] = result;
}

/// 字体管理器变化（运行中加载或替换系统字体）会让已排版结果失效，这里一次性
/// 清空两张表；纯 Dart 环境没有绑定，直接跳过，退化为按输入键失效。
bool _fontBound = false;

void _bindFontInvalidation() {
  if (_fontBound) return;
  _fontBound = true;
  try {
    PaintingBinding.instance.systemFonts.addListener(_clearTextMetrics);
  } catch (_) {
    /* 没有 WidgetsBinding 的环境（纯逻辑测试）无需字体失效通知。 */
  }
}

void _clearTextMetrics() {
  _lines.clear();
  _overflow.clear();
}

final _lines =
    <(String, TextStyle?, TextScaler, TextDirection, int?), ({double width, double height})>{};

final _overflow =
    <(String, TextStyle, int, double, TextScaler, TextDirection), bool>{};
