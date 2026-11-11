import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/live_player_policy.dart';

void main() {
  group('真实视频尺寸', () {
    test('竖屏、横屏、正方形', () {
      expect(liveVideoShape(720, 1280), LiveVideoShape.portrait);
      expect(liveVideoShape(1920, 1080), LiveVideoShape.landscape);
      expect(liveVideoShape(1080, 1080), LiveVideoShape.landscape);
    });

    test('未知、零值、负数不能进入全屏', () {
      for (final dimensions in <(int?, int?)>[
        (null, null),
        (null, 720),
        (720, null),
        (0, 720),
        (720, 0),
        (-1, 720),
        (720, -1),
      ]) {
        expect(liveVideoShape(dimensions.$1, dimensions.$2), isNull);
      }
    });
  });

  group('mpv 非致命 seekable 建议', () {
    test('仅过滤完整的特定建议行', () {
      expect(livePlaybackError('Consider passing --force-seekable=yes.'), '');
      expect(livePlaybackError("Consider passing '--force-seekable=yes'."), '');
      expect(livePlaybackError('Consider passing "--force-seekable=yes".'), '');
      expect(
        livePlaybackError(
          'Consider passing --force-seekable=yes to force seeking.',
        ),
        '',
      );
      expect(
        livePlaybackError(
          ' [demux] Consider passing --force-seekable=yes.\r\n',
        ),
        '',
      );
      expect(livePlaybackError(''), '');
      expect(
        livePlaybackError("You can force it with '--force-seekable=yes'."),
        '',
      );
      expect(
        livePlaybackError(
          "Cannot seek in this stream.\nYou can force it with '--force-seekable=yes'.",
        ),
        '',
      );
      expect(
        livePlaybackError(
          "[cplayer] You can force it with '--force-seekable=yes'.",
        ),
        '',
      );
    });

    test('混合消息保留真实错误', () {
      expect(
        livePlaybackError(
          'HTTP error 403\nConsider passing --force-seekable=yes.\nDecoder failed',
        ),
        'HTTP error 403\nDecoder failed',
      );
      expect(
        livePlaybackError(
          "Cannot seek in this stream.\nYou can force it with '--force-seekable=yes'.\nHTTP error 403",
        ),
        'HTTP error 403',
      );
    });

    test('不按 seekable 或参数关键词吞掉错误', () {
      for (final message in [
        'Failed to set --force-seekable=yes',
        'Error parsing option force-seekable',
        'HTTP error 404',
        'Failed to open decoder',
        'Consider passing --force-seekable=no.',
        'Consider passing --force-seekable=yes. Decoder failed',
      ]) {
        expect(livePlaybackError(message), message);
      }
    });
  });
}
