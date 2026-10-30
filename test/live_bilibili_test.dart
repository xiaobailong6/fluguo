import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/live_feed.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一份和线上 `getRoomPlayInfo` 同形状的响应（实测 2026-10，匿名 qn=150）。
const _playInfo = {
  'code': 0,
  'data': {
    'playurl_info': {
      'playurl': {
        'g_qn_desc': [
          {'qn': 150, 'desc': '高清'},
          {'qn': 250, 'desc': '超清'},
        ],
        'stream': [
          {
            'protocol_name': 'http_stream',
            'format': [
              {
                'format_name': 'flv',
                'codec': [
                  {
                    'codec_name': 'avc',
                    'current_qn': 150,
                    'accept_qn': [150, 80],
                    'base_url': '/live-bvc/1/live_1.flv?',
                    'url_info': [
                      {
                        'host': 'https://cn-sccd-ct-02-06.bilivideo.com',
                        'extra': 'expires=1&len=0',
                      },
                    ],
                  },
                ],
              },
            ],
          },
          {
            'protocol_name': 'http_hls',
            'format': [
              {
                'format_name': 'ts',
                'codec': [
                  {
                    'codec_name': 'avc',
                    'current_qn': 150,
                    'base_url': '/live-bvc/1/index.m3u8?',
                    'url_info': [
                      {
                        'host': 'https://d1--cn-gotcha104.bilivideo.com',
                        'extra': 'expires=1',
                      },
                    ],
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  },
};

void main() {
  test('直播搜索只解析 live_room，清理高亮并补全封面协议', () {
    final rooms = BilibiliLive.parseSearchRooms({
      'code': 0,
      'data': {
        'result': {
          'live_user': [
            {'uname': '不应该混入的主播'},
          ],
          'live_room': [
            {
              'roomid': 123,
              'title': '<em class="keyword">英雄</em>&amp;联盟',
              'uname': '主播',
              'cover': '//i0.hdslb.com/cover.jpg',
              'online': 15000,
            },
            {'roomid': 0},
          ],
        },
      },
    });
    expect(rooms, hasLength(1));
    expect(rooms.single.title, '英雄&联盟');
    expect(rooms.single.cover, 'https://i0.hdslb.com/cover.jpg');
    expect(
      BilibiliLive.parseSearchRooms({
        'code': 0,
        'data': {'result': {}},
      }),
      isEmpty,
    );
    expect(
      () => BilibiliLive.parseSearchRooms({'code': -352}),
      throwsStateError,
    );
  });

  test('二级分区图片与卡片使用同一分类数据', () {
    final parent = BilibiliLive.parseCategories({
      'code': 0,
      'data': [
        {
          'id': 2,
          'name': '网游',
          'list': [
            {'id': 86, 'name': '英雄联盟', 'pic': '//i0.hdslb.com/area.png'},
          ],
        },
      ],
    }).single;
    expect(parent.children.single.picture, 'https://i0.hdslb.com/area.png');
  });

  test('分区解析只保留带 id 的一级分区', () {
    final categories = BilibiliLive.parseCategories({
      'code': 0,
      'data': [
        {
          'id': 2,
          'name': '网游',
          'list': [
            {'id': 86, 'parent_id': 2, 'name': '英雄联盟'},
          ],
        },
        {'id': 3, 'name': '手游', 'list': []},
        {'name': '没有 id 的分区'},
      ],
    });
    expect(categories.map((category) => category.parentId).toList(), [
      '2',
      '3',
    ]);
    expect(categories.first.name, '网游');
    expect(categories.first.hot, isFalse);
    expect(categories.first.children.single.areaId, '86');
    expect(categories.first.children.single.parentId, '2');
    expect(categories.first.children.single.name, '英雄联盟');
    expect(categories.first.children.single, isNot(categories.first));
    expect(categories[1].children, isEmpty);
    expect(const LiveCategory.hot().hot, isTrue);
    expect(const LiveCategory.hot().name, '热门');
  });

  test('房间解析吃下 getRoomList 的真实字段', () {
    final rooms = BilibiliLive.parseRooms({
      'code': 0,
      'data': [
        {
          'roomid': 545068,
          'title': '英雄联盟 · 上分',
          'uname': '主播',
          'online': 484119,
          'cover': 'https://i0.hdslb.com/bfs/live/cover.jpg',
          'user_cover': 'https://i0.hdslb.com/bfs/live/cover.jpg',
          'area_name': '英雄联盟',
        },
        {'roomid': 0, 'title': '没有房间号'},
      ],
    });
    expect(rooms, hasLength(1));
    expect(rooms.single.roomId, '545068');
    expect(rooms.single.anchor, '主播');
    expect(rooms.single.area, '英雄联盟');
    expect(rooms.single.online, '48.4万');
  });

  test('接口报错时抛出可读错误', () {
    expect(
      () => BilibiliLive.parseRooms({'code': -352, 'message': '-352'}),
      throwsA(isA<StateError>()),
    );
    expect(liveErrorText(StateError('哔哩哔哩房间列表返回 -352')), '哔哩哔哩房间列表返回 -352');
    expect(liveErrorText(Exception('网络不可用')), '网络不可用');
  });

  test('线路同清晰度优先 FLV，并带清晰度文案', () {
    final stream = BilibiliLive.parsePlayStream(_playInfo);
    expect(
      stream.url,
      'https://cn-sccd-ct-02-06.bilivideo.com/live-bvc/1/live_1.flv?expires=1&len=0',
    );
    expect(stream.quality, '高清');
    expect(stream.qualityId, 150);
  });

  test('可选清晰度来自 accept_qn，标签来自服务端描述，实际画质使用 current_qn', () {
    final qualities = BilibiliLive.parseQualities(_playInfo);
    expect(qualities.map((quality) => quality.id), [150, 80]);
    expect(qualities.first.label, '高清');
    expect(qualities.map((quality) => quality.id), isNot(contains(250)));
    expect(BilibiliLive.parseQualities({'code': 0, 'data': {}}), isEmpty);
  });

  test('清晰度更高的线路优先', () {
    final payload = {
      'code': 0,
      'data': {
        'playurl_info': {
          'playurl': {
            'g_qn_desc': [
              {'qn': 250, 'desc': '超清'},
            ],
            'stream': [
              {
                'protocol_name': 'http_hls',
                'format': [
                  {
                    'format_name': 'ts',
                    'codec': [
                      {
                        'codec_name': 'avc',
                        'current_qn': 250,
                        'base_url': '/live-bvc/2/index.m3u8?',
                        'url_info': [
                          {'host': 'https://hls.example.com', 'extra': ''},
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        },
      },
    };
    final stream = BilibiliLive.parsePlayStream(payload);
    expect(stream.url, 'https://hls.example.com/live-bvc/2/index.m3u8?');
    expect(stream.quality, '超清');
  });

  test('没有可用线路时给出提示', () {
    expect(
      () => BilibiliLive.parsePlayStream({
        'code': 0,
        'data': {
          'playurl_info': {
            'playurl': {'stream': <Object>[]},
          },
        },
      }),
      throwsA(isA<StateError>()),
    );
  });

  test('人气值格式化', () {
    expect(BilibiliLive.formatOnline(0), '');
    expect(BilibiliLive.formatOnline(null), '');
    expect(BilibiliLive.formatOnline(999), '999');
    expect(BilibiliLive.formatOnline(15000), '1.5万');
    expect(BilibiliLive.formatOnline(88081569), '8808万');
  });
}
