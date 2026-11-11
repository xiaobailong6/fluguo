import 'package:duanju_app/diary_service.dart';
import 'package:duanju_app/media_trace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() async {
    DiaryService.traceEnabled = false;
    DiaryService.nativeLogPath = null;
    await DiaryService.clear();
  });
  tearDown(() { DiaryService.traceEnabled = false; });

  test('关闭时不生成或写入调试日志', () {
    var generated = false;
    DiaryService.trace(() { generated = true; return '不应记录'; });
    final trace = MediaTrace('合并');
    trace.start('开始');
    trace.event('转换失败', '错误');
    trace.progress('转换', .5);
    trace.end('结束');
    expect(generated, isFalse);
    expect(DiaryService.entries, isEmpty);
  });

  test('开启后记录阶段耗时，关闭后立即停止', () {
    final trace = MediaTrace('合并');
    DiaryService.traceEnabled = true;
    trace.start('12集');
    trace.event('格式检查', '异常1集');
    trace.event('单集已替换', '第3集');
    expect(DiaryService.entries, hasLength(3));
    expect(DiaryService.fullText, contains('[媒体][合并#${trace.id}]'));
    expect(DiaryService.fullText, matches(RegExp(r'\d+\.\ds')));
    DiaryService.traceEnabled = false;
    trace.progress('拼接', .6);
    trace.event('拼接完成', '成功');
    expect(DiaryService.entries, hasLength(3));
  });

  test('进度采样，同一档统计回调不刷屏', () {
    DiaryService.traceEnabled = true;
    final trace = MediaTrace('合并');
    trace.start('3集');
    for (var i = 0; i < 100; i++) { trace.progress('拼接进度', .5); }
    trace.progress('拼接进度', .6);
    trace.progress('拼接进度', double.nan);
    expect(DiaryService.entries, hasLength(3));
  });

  test('脱敏路径地址和凭据，但保留时间基与帧率', () {
    final safe = MediaTrace.sanitize(
      'time_base=1/90000 fps=30000/1001\n'
      'input=/private/videos/raw.mp4\n'
      r'output=C:\Users\tester\out.mp4'
      '\nhttps://cdn.test/media.mp4?token=secret\n'
      'decryption_key=0123456789abcdef0123456789abcdef\n'
      'Authorization: Bearer TOPSECRET\n'
      'ffmpeg -i /private/raw.mp4 -decryption_key hidden');
    expect(safe, contains('1/90000'));
    expect(safe, contains('30000/1001'));
    for (final secret in ['private', 'tester', 'cdn.test', 'TOPSECRET',
      '0123456789abcdef0123456789abcdef', 'ffmpeg -i']) {
      expect(safe, isNot(contains(secret)));
    }
  });

  test('含空格和UNC路径不会遗留后半段', () {
    final safe = MediaTrace.sanitize(
      r'input=C:\Users\Alice Smith\private\video.mp4'
      '\n'
      r'output=\\server\share\folder name\out.mp4'
      '\ninput=/private/folder name/video.mp4\nfps=30000/1001');
    for (final part in ['Alice', 'Smith', 'private', 'server', 'share', 'folder name', 'video.mp4', 'out.mp4']) {
      expect(safe, isNot(contains(part)));
    }
    expect(safe, contains('30000/1001'));
  });
}
