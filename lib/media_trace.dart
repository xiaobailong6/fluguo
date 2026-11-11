import 'diary_service.dart';

/// 只写结构化的过程信息，不写 FFmpeg 命令、密钥或文件地址。
class MediaTrace {
  MediaTrace(this.kind) : id = ++_sequence;

  static int _sequence = 0;
  final String kind;
  final int id;
  final Stopwatch _elapsed = Stopwatch();
  final Map<String, int> _buckets = {};
  final Map<String, int> _lastAt = {};

  void start(String message) {
    _elapsed.start();
    event('开始', message);
  }

  void event(String stage, String message) {
    DiaryService.trace(() => '[媒体][$kind#$id] '
        '${(_elapsed.elapsedMilliseconds / 1000).toStringAsFixed(1)}s '
        '${sanitize(stage)} ${sanitize(message)}');
  }

  void progress(String stage, double value) {
    if (!DiaryService.traceEnabled || !value.isFinite) return;
    final percent = (value.clamp(0.0, 1.0) * 100).floor();
    final bucket = percent ~/ 10;
    if (bucket < (_buckets[stage] ?? -1)) return;
    final now = _elapsed.elapsedMilliseconds;
    // 快速任务每 10% 一次，慢任务同档最多每 15 秒一条，避免统计回调刷屏。
    if (_buckets[stage] == bucket && now - (_lastAt[stage] ?? 0) < 15000) return;
    _buckets[stage] = bucket;
    _lastAt[stage] = now;
    event(stage, '$percent%');
  }

  void end(String result) {
    event('结束', result);
    _elapsed.stop();
  }

  static String sanitize(String value) {
    var text = value.replaceAll(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]'), '');
    text = text.replaceAll(RegExp(r'https?://[^\s]+', caseSensitive: false), '[地址]');
    // 路径允许空格，按整行或引号边界脱敏，避免泄露后半段。
    text = text.replaceAll(RegExp(r'''[A-Za-z]:[\\/][^，；、：\n"']+'''), '[路径]');
    text = text.replaceAll(RegExp(r'''\\\\[^，；、：\n"']+'''), '[路径]');
    text = text.replaceAll(RegExp(r'''(?<![A-Za-z0-9])/[^，；、：\n"']+'''), '[路径]');
    text = text.replaceAll(RegExp(
        r'''\b(?:decryption_key|aeskey|key|token|secret|authorization|cookie|password|credential|bearer)\b[^\n]*''',
        caseSensitive: false), '[凭据]');
    text = text.replaceAll(RegExp(r'\b[A-Fa-f0-9]{32,}\b'), '[标识]');
    // 错误可能带多行 FFmpeg 输出，仅保留有限尾部；不转储完整命令。
    text = text.split('\n').where((line) =>
        !RegExp(r'ffmpeg\s|(?:^|\s)-i\s|--', caseSensitive: false).hasMatch(line))
        .take(12).join('\n');
    return text.length > 1800 ? '${text.substring(0, 1800)}…' : text;
  }
}
