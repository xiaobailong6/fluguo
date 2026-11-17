import 'package:duanju_app/danmaku_emoji.dart';
import 'package:duanju_app/danmaku_style.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/ui/player/danmaku_emoji_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _style = TextStyle(fontSize: 16, color: Color(0xCCFFFFFF));

void main() {
  test('只识别白名单里的完整方括号名称', () {
    expect(danmakuEmojiAsset('赞'), 'assets/danmaku_emoji/1f44d.png');
    expect(danmakuEmojiAsset('不存在'), isNull);
    // 词典是有限集合：别名共享图片，资源本身有 49 张。
    expect(danmakuEmojiCodepoints.values.toSet(), hasLength(49));
    for (final code in danmakuEmojiCodepoints.values) {
      expect('assets/danmaku_emoji/$code.png', endsWith('.png'));
    }
  });

  test('已知表情转图片片段并保留原文，未知内容原样保留', () {
    final known = parseDanmakuSegments('[爽]');
    expect(known, hasLength(1));
    expect(known.single.asset, 'assets/danmaku_emoji/1f60c.png');
    // 原文必须保留，资源缺失时才能降级回 [爽]。
    expect(known.single.text, '[爽]');

    final mixed = parseDanmakuSegments('前排[赞]后排');
    expect(mixed.map((segment) => segment.text), ['前排', '[赞]', '后排']);
    expect(mixed.map((segment) => segment.asset), [
      null,
      'assets/danmaku_emoji/1f44d.png',
      null,
    ]);

    final unknown = parseDanmakuSegments('[不存在]和[ ]');
    expect(unknown.single.asset, isNull);
    expect(unknown.single.text, '[不存在]和[ ]');
    expect(parseDanmakuSegments('没有方括号').single.asset, isNull);
    // 空文本没有可绘制片段，保持空列表而不是伪造一个空片段。
    expect(parseDanmakuSegments(''), isEmpty);
  });

  test('连续表情各自成片段且别名不丢失', () {
    final segments = parseDanmakuSegments('[666][666]');
    expect(segments, hasLength(2));
    expect(segments.map((segment) => segment.asset), [
      'assets/danmaku_emoji/1f44c.png',
      'assets/danmaku_emoji/1f44c.png',
    ]);
    expect(segments.map((segment) => segment.text), ['[666]', '[666]']);
  });

  test('表情占位宽度不小于原文字，且不改变行高', () {
    final painter = TextPainter(
      text: const TextSpan(text: '[赞]', style: _style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
    )..layout();
    final textWidth = painter.width;
    final textHeight = painter.height;
    painter.dispose();

    final layout = DanmakuEmojiLayout(
      parseDanmakuSegments('[赞]'),
      style: _style,
      outline: null,
      scaler: TextScaler.noScaling,
    );
    addTearDown(layout.dispose);
    expect(layout.width, greaterThanOrEqualTo(textWidth));
    expect(layout.height, textHeight);
    expect(layout.extent, 16);
  });

  test('图片沿用弹幕不透明度', () {
    final layout = DanmakuEmojiLayout(
      parseDanmakuSegments('[赞]'),
      style: const TextStyle(fontSize: 16, color: Color(0x80FFFFFF)),
      outline: null,
      scaler: TextScaler.noScaling,
    );
    addTearDown(layout.dispose);
    expect(layout.opacity, closeTo(0x80 / 0xFF, .001));
  });

  test('表情开关只在红果生效，且新选项默认关闭', () {
    const off = PlaybackPreferences();
    expect(off.danmakuEmoji, isFalse);
    expect(off.danmakuMerge, DanmakuMerge.off);
    final enabled = off.copyWith(danmakuEmoji: true);
    expect(DanmakuStyle.of(enabled, source: 'hongguo').emoji, isTrue);
    expect(DanmakuStyle.of(enabled, source: 'bilibili').emoji, isFalse);
    expect(DanmakuStyle.of(off, source: 'hongguo').emoji, isFalse);
  });
}
