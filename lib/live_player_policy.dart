/// 直播只使用解码器提供的真实尺寸；未知尺寸不能推断全屏方向。
enum LiveVideoShape { portrait, landscape }

LiveVideoShape? liveVideoShape(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width < height ? LiveVideoShape.portrait : LiveVideoShape.landscape;
}

/// mpv 对不可跳转直播输出的建议不是解码/网络失败。
/// 按完整行精准过滤，混合消息里的真实错误原样保留。
String livePlaybackError(String message) {
  final diagnostic = RegExp(
    r'''^\s*(?:\[[^\]\r\n]+\]\s*)?(?:Cannot seek in this stream\.|You can force it with ['"]--force-seekable=yes['"]\.|Consider passing (?:--force-seekable=yes|'--force-seekable=yes'|"--force-seekable=yes")(?: to force seeking)?\.?)\s*$''',
    caseSensitive: false,
  );
  return message
      .split('\n')
      .where((line) => !diagnostic.hasMatch(line))
      .join('\n')
      .trim();
}
