import 'package:duanju_app/playback_preload_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late PlaybackPreloadPolicy policy;
  setUp(() => policy = PlaybackPreloadPolicy());
  ({bool prefetch, bool preopen, Duration remaining}) evaluate({
    int position = 10,
    int total = 120,
    int buffer = 120,
    double rate = 1,
    bool playing = true,
    bool buffering = false,
    bool local = false,
    int intro = 0,
    int outro = 0,
  }) => policy.evaluate(
    position: Duration(seconds: position),
    duration: Duration(seconds: total),
    buffered: Duration(seconds: buffer),
    rate: rate,
    playing: playing,
    buffering: buffering,
    local: local,
    skipIntroSeconds: intro,
    skipOutroSeconds: outro,
  );

  test('完整缓冲无需等播放后段，备用播放器等临近切集', () {
    expect(evaluate().prefetch, isTrue);
    expect(evaluate().preopen, isFalse);
    expect(evaluate(position: 95).preopen, isTrue);
  });
  test('有限缓存90秒窗口和15/5秒滞回，不反复争抢带宽', () {
    expect(evaluate(position: 10, buffer: 40).prefetch, isFalse);
    expect(evaluate(position: 40, buffer: 54).prefetch, isFalse);
    expect(evaluate(position: 40, buffer: 55).prefetch, isTrue);
    expect(evaluate(position: 40, buffer: 47).prefetch, isTrue);
    expect(evaluate(position: 40, buffer: 44).prefetch, isFalse);
    expect(evaluate(position: 40, buffer: 50).prefetch, isFalse);
  });
  test('倍速和有效片尾按实际观看时间计算', () {
    final decision = evaluate(position: 40, buffer: 120, rate: 2, outro: 30);
    expect(decision.remaining, const Duration(seconds: 25));
    expect(decision.preopen, isTrue);
    expect(
      evaluate(position: 40, intro: 80, outro: 50).remaining,
      const Duration(seconds: 80),
    );
  });
  test('极短视频完整缓冲仍能预开，未知时长和刚起播不预取', () {
    expect(evaluate(position: 3, total: 20, buffer: 20).preopen, isTrue);
    expect(evaluate(position: 1).prefetch, isFalse);
    expect(evaluate(total: 0).prefetch, isFalse);
    expect(evaluate(position: 120).prefetch, isFalse);
  });
  test('暂停和卡顿停止后台工作，本地媒体视为已缓冲', () {
    expect(evaluate(playing: false).prefetch, isFalse);
    expect(evaluate(buffering: true).preopen, isFalse);
    expect(evaluate(buffer: 0, local: true).prefetch, isTrue);
    policy.reset();
    expect(evaluate(position: 40, buffer: 47).prefetch, isFalse);
  });
}
