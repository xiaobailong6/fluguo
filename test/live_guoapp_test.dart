import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:duanju_app/live_models.dart';

import 'package:duanju_app/live_guoapp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('映客恢复后保留旧收藏 ID，同名跨平台主播不冲突', () {
    final body = jsonEncode({'zhubo': [
      {'title': '主播', 'address': 'https://example.com/live/a.flv'},
    ]});
    final old = GuoappLive.parseChannels(
      body, const LiveCategory(name: '映客', parentId: 'yingke'),
    ).single.room;
    final other = GuoappLive.parseChannels(
      body, const LiveCategory(name: '其他', parentId: 'other'),
    ).single.room;
    expect(old.roomId, md5.convert(utf8.encode('主播')).toString());
    expect(other.roomId, isNot(old.roomId));
  });

  test('从实际索引发现分类，排除空列表及伪视频，刷新播放签名', () async {
    final calls = <String>[];
    var signature = 'first';
    final platform = GuoappLive(request: (uri, timeout) async {
      calls.add(uri.path);
      expect(timeout > Duration.zero, isTrue);
      if (uri.path.endsWith('/json.txt')) {
        return jsonEncode({'pingtai': [
          {'title': '卡哇伊', 'address': 'jsonkawayi.txt'},
          {'title': '空', 'address': 'jsonempty.txt', 'Number': '999'},
          {'title': '电视', 'address': 'jsontv.txt'},
          {'title': '越界', 'address': '../jsonbad.txt'},
          {'title': '视频', 'address': 'https://example.com/a.mp4'},
        ]});
      }
      if (uri.path.endsWith('/jsonempty.txt')) return '{"zhubo":[]}';
      if (uri.path.endsWith('/jsontv.txt')) {
        return '{"zhubo":[{"title":"电视","address":"https://example.com/block.mp4"}]}';
      }
      return jsonEncode({'zhubo': [
        {'title': '主播', 'address': 'https://example.com/live/a.flv?sign=$signature', 'img': '//example.com/a.jpg'},
      ]});
    });
    final categories = await platform.categories();
    expect(categories.map((e) => e.name), ['卡哇伊']);
    final rooms = await platform.rooms(categories.single.children.single);
    expect(rooms.single.area, '卡哇伊');
    expect(rooms.single.cover, 'https://example.com/a.jpg');
    expect(await platform.rooms(categories.single.children.single, page: 2), isEmpty);
    expect((await platform.search('主播')).single.roomId, rooms.single.roomId);
    signature = 'renewed';
    expect((await platform.resolve(rooms.single)).url, endsWith('sign=renewed'));
    expect(calls.where((e) => e.endsWith('/json.txt')).length, 1);
    expect(calls.any((e) => e.contains('yingke') || e.endsWith('.mp4') || e.endsWith('.jpg')), isFalse);
  });

  test('主镜像失败后从备用镜像读取索引', () async {
    final hosts = <String>[];
    final platform = GuoappLive(request: (uri, _) async {
      hosts.add(uri.host);
      if (uri.host == 'api.hclyz.com') throw StateError('offline');
      if (uri.path.endsWith('/json.txt')) {
        return '{"pingtai":[{"title":"测试","address":"jsondemo.txt"}]}';
      }
      return '{"zhubo":[{"title":"主播","address":"http://example.com/live/a.flv"}]}';
    });
    expect((await platform.categories()).single.name, '测试');
    expect(hosts, containsAll(['api.hclyz.com', 'api.vipmisss.com']));
  });

  test('分类缓存建立后主镜像离线，播放刷新使用备用镜像', () async {
    var offline = false;
    final hosts = <String>[];
    final platform = GuoappLive(request: (uri, _) async {
      hosts.add(uri.host);
      if (offline && uri.host == 'api.hclyz.com') throw StateError('offline');
      if (uri.path.endsWith('/json.txt')) {
        return '{"pingtai":[{"title":"测试","address":"jsondemo.txt"}]}';
      }
      return jsonEncode({'zhubo': [
        {'title': '主播', 'address': 'https://example.com/live/a.flv?host=${uri.host}'},
      ]});
    });
    final category = (await platform.categories()).single.children.single;
    final room = (await platform.rooms(category)).single;
    offline = true;
    hosts.clear();
    expect((await platform.resolve(room)).url, contains('api.vipmisss.com'));
    expect(hosts, ['api.hclyz.com', 'api.vipmisss.com']);
  });

  test('无有效分类时失败，不生成硬编码映客分类', () async {
    final platform = GuoappLive(request: (_, _) async => '{"pingtai":[]}');
    await expectLater(platform.categories(), throwsStateError);
  });
}
