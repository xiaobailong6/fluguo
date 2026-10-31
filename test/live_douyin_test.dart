import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/live_douyin.dart';
import 'package:duanju_app/live_douyin_http.dart';
import 'package:duanju_app/live_feed.dart';
import 'package:duanju_app/live_models.dart';
import 'package:flutter_test/flutter_test.dart';

const categories = [
  {
    'partition': {'id_str': '101', 'type': 4, 'title': '聊天'},
    'sub_partition': [],
  },
  {
    'partition': {'id_str': '103', 'type': 4, 'title': '游戏'},
    'sub_partition': [
      {
        'partition': {'id_str': '1001', 'type': 1, 'title': '含"引号}的游戏'},
      },
    ],
  },
];
String home([String kind = 'pace']) =>
    '<script>self.__${kind}_f.push(${jsonEncode([
      1,
      '2:${jsonEncode({'categoryData': categories})}',
    ])})</script>';
Map<String, dynamic> row(int id, {int status = 0}) => {
  'web_rid': '$id',
  'tag_name': '游戏',
  'room': {
    'id_str': '7000000000000000001',
    'status': status,
    'title': '直播$id',
    'owner': {'nickname': '主播$id', 'web_rid': 'other'},
    'cover': {
      'url_list': ['https://images.test/$id.jpg'],
    },
    'user_count': 12345,
  },
};
Map<String, dynamic> stream() => {
  'live_core_sdk_data': {
    'pull_data': {
      'options': {
        'qualities': [
          {'sdk_key': 'origin', 'name': '原画'},
          {'sdk_key': 'hd', 'name': '超清'},
          {'sdk_key': 'ao', 'name': '音频'},
        ],
      },
      'stream_data': jsonEncode({
        'data': {
          'origin': {
            'main': {'flv': 'https://media.test/source.flv'},
          },
          'hd': {
            'main': {
              'flv': 'https://media.test/hd.flv',
              'hls': 'https://media.test/hd.m3u8',
            },
          },
          'ao': {
            'main': {'flv': 'https://media.test/audio.flv?only_audio=1'},
          },
        },
      }),
    },
  },
};

void main() {
  test('解析两种Flight分类，零子分类仍有真实全区入口', () {
    for (final kind in ['pace', 'next']) {
      final parsed = DouyinLive.parseCategories(home(kind));
      expect(parsed.map((c) => c.name), ['热门', '聊天', '游戏']);
      expect(parsed[1].children.single.areaId, '101,4');
      expect(parsed[2].children.last.name, '含"引号}的游戏');
      expect(parsed[2].children.last.parentId, '103,4');
      expect(parsed[2].children.last.areaId, '1001,1');
    }
    expect(
      () => DouyinLive.parseCategories('<html>验证</html>'),
      throwsStateError,
    );
    expect(
      () => DouyinLive.parseCategories('{"categoryData":[]}'),
      throwsStateError,
    );
  });

  test('列表状态0、网页ID、去重、停播和两代feed结构', () {
    final list = DouyinLive.parseRooms({
      'status_code': 0,
      'data': {
        'data': [row(1), row(1), row(2, status: 4)],
      },
    });
    expect(list.single.roomId, '1');
    expect(list.single.anchor, '主播1');
    expect(list.single.online, '1.2万');
    final modern = DouyinLive.parseRooms({
      'data': [
        {'data': jsonEncode(row(1)['room'])},
      ],
    });
    expect(modern.single.roomId, '7000000000000000001');
    expect(
      () => DouyinLive.parseRooms({'status_code': 1001}),
      throwsStateError,
    );
    expect(() => DouyinLive.parseRooms({'data': {}}), throwsStateError);
  });

  test('现代画质仅同档多线路、排除音频、未支持画质返回实际档位', () {
    final selected = DouyinLive.parseStream(stream(), quality: 250);
    expect(selected.qualityId, 250);
    expect(selected.lines, hasLength(2));
    expect(selected.lines.every((l) => l.url.contains('/hd.')), isTrue);
    expect(selected.qualities.map((q) => q.id), [10000, 250]);
    expect(
      selected.selectLine(selected.lines.last.id).url,
      endsWith('hd.m3u8'),
    );
    final source = DouyinLive.parseStream(stream(), quality: 10000);
    expect(source.url, endsWith('source.flv'));
    expect(source.lines, hasLength(1));
    expect(DouyinLive.parseStream(stream(), quality: 80).qualityId, 10000);
    expect(selected.headers['Referer'], '$douyinOrigin/');
    expect(selected.headers.containsKey('Cookie'), isFalse);
  });

  test('旧画质结构按key而非顺序关联，并过滤音频链接', () {
    final parsed = DouyinLive.parseStream({
      'flv_pull_url': {
        'FULL_HD1': 'https://m.test/a.flv',
        'HD1': 'https://m.test/b.flv',
        'AO': 'https://m.test/audio.flv',
      },
      'hls_pull_url_map': {'HD1': 'https://m.test/b.m3u8'},
      'resolution_name': {'HD1': '超清', 'FULL_HD1': '蓝光'},
    }, quality: 250);
    expect(parsed.quality, '超清');
    expect(parsed.lines.map((l) => l.url), [
      'https://m.test/b.flv',
      'https://m.test/b.m3u8',
    ]);
    expect(
      () => DouyinLive.parseStream({
        'flv_pull_url': {'ao': 'https://m.test/ao'},
      }),
      throwsStateError,
    );
  });

  test('搜索嵌套rawdata与web房间身份，详情网页回退', () {
    final payload = {
      'status_code': 0,
      'data': [
        {
          'lives': {'rawdata': jsonEncode(row(1)['room'])},
        },
      ],
    };
    final rooms = DouyinLive.parseSearch(payload);
    expect(rooms.single.roomId, '7000000000000000001');
    final detail = {'status': 2, 'stream_url': stream()};
    final page =
        '<script>self.__pace_f.push(${jsonEncode([
          1,
          jsonEncode({
            'state': {
              'roomStore': {
                'roomInfo': {'room': detail},
              },
            },
          }),
        ])})</script>';
    expect(DouyinLive.roomFromPage(page)['status'], 2);
  });

  test('请求签名、分类参数和15条分页不会第一屏误判到底', () async {
    final requests = <Uri>[];
    final client = DouyinClient(
      request: (uri, headers) async {
        requests.add(uri);
        if (uri.path == '/') {
          return DouyinResponse(home(), cookies: {'ttwid': 'anon'});
        }
        expect(headers['Cookie'], 'ttwid=anon');
        expect(uri.queryParameters['a_bogus'], isNotEmpty);
        expect(uri.queryParameters['count'], '15');
        final offset = int.parse(uri.queryParameters['offset']!);
        return DouyinResponse(
          jsonEncode({
            'status_code': 0,
            'data': {
              'data': [for (var i = 0; i < 15; i++) row(offset + i + 1)],
            },
          }),
        );
      },
    );
    final platform = DouyinLive(client: client);
    final feed = LiveFeed(platform);
    addTearDown(feed.dispose);
    await feed.start();
    await feed.select(feed.categories[1]);
    await feed.selectArea(feed.areas.single);
    expect(feed.rooms, hasLength(15));
    expect(feed.end, isFalse);
    await feed.loadMore();
    expect(feed.rooms, hasLength(30));
    expect(requests.last.queryParameters['offset'], '15');
    expect(requests.last.queryParameters['partition'], '101');
    expect(requests.last.queryParameters['partition_type'], '4');
  });

  test('Cookie只取键值、匿名字段白名单、空响应显示风控而非假空列表', () async {
    expect(
      DouyinClient.responseCookies([
        'ttwid=a==; Secure=true; Path=/',
        'UIFID_TEMP=b; HttpOnly',
      ]),
      {'ttwid': 'a==', 'UIFID_TEMP': 'b'},
    );
    final client = DouyinClient(
      request: (uri, headers) async => uri.path == '/'
          ? DouyinResponse(
              home(),
              cookies: {'ttwid': 'anon', 'account_session': 'secret'},
            )
          : const DouyinResponse(''),
    );
    await client.home();
    expect(client.headers['Cookie'], 'ttwid=anon');
    await expectLater(
      client.json('/webcast/feed/', {}),
      throwsA(
        isA<StateError>().having((e) => e.message, 'message', contains('风控')),
      ),
    );
  });

  test('匿名首页合并并发，失败后可重试且过期清会话', () async {
    var now = DateTime(2026);
    var calls = 0;
    final pending = Completer<DouyinResponse>();
    final client = DouyinClient(
      clock: () => now,
      request: (uri, headers) async {
        calls++;
        return calls == 1 ? pending.future : DouyinResponse(home());
      },
    );
    final first = client.home();
    final second = client.home();
    expect(identical(first, second), isTrue);
    pending.complete(DouyinResponse(home(), cookies: {'ttwid': 'anon'}));
    await first;
    await client.home();
    expect(calls, 1);
    now = now.add(const Duration(minutes: 31));
    await client.home();
    expect(calls, 2);
    expect(client.headers.containsKey('Cookie'), isFalse);
  });

  test('解析成功后取流仍校验开播状态，不把失败写成可播', () async {
    final client = DouyinClient(
      request: (uri, headers) async {
        if (uri.path == '/') return DouyinResponse(home());
        return DouyinResponse(
          jsonEncode({
            'status_code': 0,
            'data': {
              'data': [
                {'status': 4},
              ],
            },
          }),
        );
      },
    );
    final platform = DouyinLive(client: client);
    await expectLater(
      platform.resolve(
        const LiveRoom(
          roomId: '1',
          title: '',
          anchor: '',
          cover: '',
          area: '',
          online: '',
        ),
      ),
      throwsStateError,
    );
  });
  test('匿名首页失败后允许新请求，不泄露原始网络异常URL', () async {
    var calls = 0;
    final client = DouyinClient(
      request: (uri, headers) async {
        if (++calls == 1) {
          throw StateError('https://private.test/?token=secret');
        }
        return DouyinResponse(home());
      },
    );
    await expectLater(
      client.home(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'sanitized',
          isNot(contains('secret')),
        ),
      ),
    );
    expect(await client.home(), contains('categoryData'));
    expect(calls, 2);
  });

  test('切线路重新获取当前房间，画质和Cookie不进入持久化房间', () async {
    var opens = 0;
    final client = DouyinClient(
      request: (uri, headers) async {
        if (uri.path == '/') {
          return DouyinResponse(home(), cookies: {'ttwid': 'anon'});
        }
        expect(uri.queryParameters['web_rid'], '1');
        opens++;
        return DouyinResponse(
          jsonEncode({
            'status_code': 0,
            'data': {
              'data': [
                {'status': 2, 'stream_url': stream()},
              ],
            },
          }),
        );
      },
    );
    final platform = DouyinLive(client: client);
    const room = LiveRoom(
      roomId: '1',
      title: '直播',
      anchor: '主播',
      cover: '',
      area: '',
      online: '',
    );
    final first = await platform.resolve(room, quality: 250);
    final next = await platform.resolveLine(
      room,
      quality: 250,
      line: first.lines.last.id,
    );
    expect(opens, 2);
    expect(next.url, endsWith('hd.m3u8'));
    expect(next.qualityId, 250);
    expect(jsonEncode(room.toJson()), isNot(contains('anon')));
    expect(jsonEncode(room.toJson()), isNot(contains('media.test')));
  });
}
