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

/// 本页只播放直播，包括本机 FLV 中继；不能因回环地址而套用点播缓存策略。
/// 保留读缓存，只关闭为了凑缓存而暂停及强制 seek。
const liveNativeProperties = <String, String>{
  'cache-pause': 'no',
  'force-seekable': 'no',
};

/// 静音目标在命令发出时计算，连续按 M 不依赖异步音量回报。
class LiveMuteState {
  double _audible = 100;

  double toggle(double volume) {
    if (volume > 0) {
      _audible = volume.clamp(0, 100);
      return 0;
    }
    return _audible;
  }
}
