import 'package:duanju_app/live_douyu.dart';
import 'package:duanju_app/live_models.dart';
import 'package:flutter_test/flutter_test.dart';

const room = LiveRoom(
  roomId: '1',
  title: '',
  anchor: '',
  cover: '',
  area: '',
  online: '',
);
void main() {
  for (final mode in ['reuse', 'expiry', 'reject', 'always-reject']) {
    test('同次取流描述符 $mode 不跨请求缓存且失败有界', () async {
      var keys = 0, plays = 0;
      final used = <String>[];
      var seconds = 100;
      final live = DouyuLive(
        now: () => DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
        request: (url, {query = const {}, headers = const {}, form}) async {
          if (url.contains('getEncryption')) {
            keys++;
            return {
              'data': {
                'enc_time': 1,
                'expire_at': seconds + 60,
                'key': 'key',
                'rand_str': 'rand',
                'enc_data': 'key$keys',
              },
            };
          }
          plays++;
          used.add(form!['enc_data']!);
          if (plays == 1 && mode == 'expiry') seconds += 58;
          if (mode == 'always-reject' && plays >= 2 ||
              mode == 'reject' && plays == 2) {
            return {'error': -1};
          }
          return {
            'error': 0,
            'data': {
              'rate': plays == 1 ? 0 : 2,
              'cdn': 'a',
              'rtmp_url': 'https://example.invalid',
              'rtmp_live': 'live.flv',
              'multirates': [
                {'rate': 0, 'name': '原画'},
                {'rate': 2, 'name': '高清'},
              ],
              'cdnsWithName': [
                {'cdn': 'a', 'name': 'A'},
              ],
            },
          };
        },
      );
      if (mode == 'always-reject') {
        await expectLater(
          live.resolveLine(room, quality: 150),
          throwsStateError,
        );
        expect(keys, 2);
        expect(plays, 3);
      } else {
        final result = await live.resolveLine(room, quality: 150);
        expect(result.qualityId, 150);
        expect(keys, mode == 'reuse' ? 1 : 2);
        expect(plays, mode == 'reject' ? 3 : 2);
        if (mode == 'reuse') expect(used, ['key1', 'key1']);
        final before = keys;
        await live.resolveLine(room, quality: 150);
        expect(keys, before + 1);
      }
    });
  }
}
