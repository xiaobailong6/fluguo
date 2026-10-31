import 'dart:convert';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/live_douyu.dart';
import 'package:duanju_app/live_huya.dart';
import 'package:duanju_app/live_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('标准版移除秀果，全站源版保留原直播列表', () {
    expect(livePlatforms.map((p) => p.id), [
      'bilibili',
      'douyu',
      'huya',
      'douyin',
      if (allSourcesEnabled) 'xiuguo',
    ]);
    expect(livePlatforms.map((p) => p.id).toSet().length, livePlatforms.length);
    expect(livePlatformById('xiuguo')?.name, allSourcesEnabled ? '秀果' : null);
    expect(livePlatformById('douyu')?.name, '斗鱼');
    expect(livePlatformById('douyin')?.name, '抖音');
    expect(livePlatformById('missing'), isNull);
  });

  test('斗鱼将 cate2 按 cate1Id 归入对应一级目录', () {
    final groups = DouyuLive.parseCategories({
      'code': 0,
      'data': {
        'cate1Info': [
          {'cate1Id': 1, 'cate1Name': '网游'},
          {'cate1Id': 2, 'cate1Name': '手游'},
        ],
        'cate2Info': [
          {
            'cate1Id': 1,
            'cate2Id': 10,
            'cate2Name': '英雄联盟',
            'icon': '//img.test/lol.png',
          },
          {'cate1Id': 2, 'cate2Id': 20, 'cate2Name': '王者荣耀'},
        ],
      },
    });
    expect(groups.first.hot, isTrue);
    expect(groups[1].children.single.areaId, '10');
    expect(groups[1].children.single.picture, 'https://img.test/lol.png');
    expect(groups[2].children.single.parentId, '2');
  });

  test('虎牙兼容数值、字符串和历史 Map 类型的游戏分区编号', () {
    final areas = HuyaLive.parseAreas({
      'data': [
        {'gid': 1.0, 'gameFullName': '英雄联盟'},
        {'gid': '2', 'gameFullName': '游戏2'},
        {
          'gid': {'value': '3,4'},
          'gameFullName': '游戏3',
        },
        {'gid': null},
      ],
    }, '8');
    expect(areas.map((area) => area.areaId), ['1', '2', '3']);
    expect(areas.every((area) => area.parentId == '8'), isTrue);
  });

  test('斗鱼签名有边界和失效校验，不按 rate 数值重排画质', () {
    final key = {
      'key': 'k',
      'rand_str': 'r',
      'enc_data': 'e',
      'enc_time': 2,
      'expire_at': 200,
      'is_special': 0,
    };
    final body = DouyuLive.sign(key, '123', seconds: 100, device: 'did');
    expect(body['did'], 'did');
    expect(body['rate'], '-1');
    expect(body['auth'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(
      () => DouyuLive.sign(key, '123', seconds: 201, device: 'did'),
      throwsStateError,
    );
    final rates = DouyuLive.rates({
      'multirates': [
        {'rate': 0, 'name': '原画'},
        {'rate': 8, 'name': '蓝光4M'},
        {'rate': 2, 'name': '高清'},
      ],
    });
    expect(rates.map((r) => r.rate), [0, 8, 2]);
    expect(rates.map((r) => r.quality.id), [10000, 400, 150]);
  });

  test('虎牙签名保留服务端过期时间，剔除 fm 不修改有效期', () {
    final now = DateTime.fromMillisecondsSinceEpoch(1000000);
    final expiry = 1100.toRadixString(16);
    final anti = Uri(
      queryParameters: {
        'fm': base64.encode(utf8.encode(r'prefix_$0_$1_$2_$3')),
        'wsTime': expiry,
        'ctype': 'huya_webh5',
        't': '100',
      },
    ).query;
    final signed = Uri.splitQueryString(
      HuyaLive.signAntiCode('stream', anti, viewer: 123, now: now),
    );
    expect(signed['wsTime'], expiry);
    expect(signed.containsKey('fm'), isFalse);
    expect(signed['wsSecret'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(
      () => HuyaLive.signAntiCode(
        'stream',
        anti,
        viewer: 123,
        now: DateTime.fromMillisecondsSinceEpoch(1200000),
      ),
      throwsStateError,
    );
  });

  test('网页 JSON 扫描不截断字符串中的大括号和后续 JavaScript', () {
    final json = livePageObject(
      'config = { stream: {"title":"a}b", "data":[{"id":1}]} };',
      r'stream\s*:',
    );
    expect(json['title'], 'a}b');
    expect((json['data'] as List).single['id'], 1);
    expect(
      () => livePageObject('not a stream', r'stream\s*:'),
      throwsStateError,
    );
  });
}
