import 'package:flutter/painting.dart';

import 'playback_preferences.dart';

class DanmakuStyle {
  const DanmakuStyle({
    this.scale = 1,
    this.color = const Color(0xFFFFFFFF),
    this.opacity = 1,
    this.bold = true,
    this.stroke = 0,
    this.shadow = 3,
    this.coverage = DanmakuCoverage.half,
    this.emoji = false,
  });

  factory DanmakuStyle.of(
    PlaybackPreferences preferences, {
    String source = '',
  }) => DanmakuStyle(
    scale: preferences.danmakuScale,
    color: Color(preferences.danmakuColor),
    opacity: preferences.danmakuOpacity,
    bold: preferences.danmakuBold,
    stroke: preferences.danmakuStroke,
    shadow: preferences.danmakuShadow,
    coverage: preferences.danmakuCoverage,
    emoji: preferences.danmakuEmoji && source == 'hongguo',
  );

  final double scale;
  final Color color;
  final double opacity;
  final bool bold;
  final double stroke;
  final double shadow;
  final DanmakuCoverage coverage;
  final bool emoji;

  bool get hasStroke => stroke > 0;
  bool get hasShadow => shadow > 0;

  @override
  bool operator ==(Object other) =>
      other is DanmakuStyle &&
      other.scale == scale &&
      other.color == color &&
      other.opacity == opacity &&
      other.bold == bold &&
      other.stroke == stroke &&
      other.shadow == shadow &&
      other.coverage == coverage &&
      other.emoji == emoji;

  @override
  int get hashCode =>
      Object.hash(scale, color, opacity, bold, stroke, shadow, coverage, emoji);
}
