import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/live_douyin.dart';
import 'package:duanju_app/live_douyin_http.dart';
import 'package:duanju_app/live_douyin_pictures.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/live/live_category_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> picture(String id) => {
  'status_code': 0,
  'data': {
    'data': [
      {
        'room': {
          'cover': {
            'url_list': ['https://images.test/$id.jpg'],
          },
        },
      },
    ],
  },
};
LiveCategory area(int id) =>
    LiveCategory(name: '分区$id', parentId: '103,4', areaId: '$id,1');

class _PicturePlatform extends LivePlatform {
  int calls = 0;
  @override
  String get id => 'test';
  @override
  String get name => '测试';
  @override
  Future<List<LiveCategory>> categories() async => [];
  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async =>
      [];
  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 0}) async =>
      throw UnimplementedError();
  @override
  Future<String> categoryPicture(LiveCategory category) async {
    calls++;
    return '';
  }
}

void main() {
  test('平台目录已有图片时优先使用，不请求补图', () async {
    var calls = 0;
    final client = DouyinClient(
      request: (_, _) async {
        calls++;
        throw StateError('不应请求');
      },
    );
    final parsed = DouyinLive.parseCategories(
      jsonEncode({
        'categoryData': [
          {
            'partition': {
              'id_str': '103',
              'type': 4,
              'title': '游戏',
              'cover': {},
              'icon': {
                'url_list': ['https://images.test/game.png'],
              },
            },
            'sub_partition': [
              {
                'partition': {'id_str': '1', 'type': 1, 'title': '游戏一'},
                'icon_url': 'https://images.test/one.png',
              },
            ],
          },
        ],
      }),
    );
    expect(
      await DouyinCategoryPictures(client).load(parsed[1].children.first),
      'https://images.test/game.png',
    );
    expect(parsed[1].children.last.picture, 'https://images.test/one.png');
    expect(calls, 0);
  });

  test('代表封面来自对应分区，合并并发且最多两路补图', () async {
    var active = 0;
    var peak = 0;
    var calls = 0;
    final held = <Completer<void>>[];
    final client = DouyinClient(
      request: (uri, headers) async {
        if (uri.path == '/') return const DouyinResponse('home');
        calls++;
        active++;
        if (active > peak) peak = active;
        final completer = Completer<void>();
        held.add(completer);
        await completer.future;
        active--;
        expect(uri.queryParameters['count'], '1');
        expect(uri.queryParameters['partition_type'], '1');
        return DouyinResponse(
          jsonEncode(picture(uri.queryParameters['partition']!)),
        );
      },
    );
    final cache = DouyinCategoryPictures(client);
    final first = cache.load(area(1));
    final duplicate = cache.load(area(1));
    expect(identical(first, duplicate), isTrue);
    final requests = [first, cache.load(area(2)), cache.load(area(3))];
    await pumpEventQueue();
    expect(held, hasLength(2));
    held[0].complete();
    await pumpEventQueue();
    expect(held, hasLength(3));
    for (final completer in held.where((c) => !c.isCompleted)) {
      completer.complete();
    }
    expect(await Future.wait(requests), [
      'https://images.test/1.jpg',
      'https://images.test/2.jpg',
      'https://images.test/3.jpg',
    ]);
    expect(await cache.load(area(1)), 'https://images.test/1.jpg');
    expect(calls, 3);
    expect(peak, 2);
  });

  test('成功十分钟缓存，失败一分钟缓存，不阻断分区', () async {
    var now = DateTime(2026);
    var calls = 0;
    var fail = true;
    final client = DouyinClient(
      request: (uri, headers) async {
        if (uri.path == '/') return const DouyinResponse('home');
        calls++;
        if (fail) throw StateError('暂不可用');
        return DouyinResponse(jsonEncode(picture('1')));
      },
    );
    final cache = DouyinCategoryPictures(client, clock: () => now);
    expect(await cache.load(area(1)), '');
    expect(await cache.load(area(1)), '');
    expect(calls, 1);
    fail = false;
    now = now.add(const Duration(minutes: 2));
    expect(await cache.load(area(1)), 'https://images.test/1.jpg');
    now = now.add(const Duration(minutes: 5));
    await cache.load(area(1));
    expect(calls, 2);
    now = now.add(const Duration(minutes: 6));
    await cache.load(area(1));
    expect(calls, 3);
  });

  test('现代feed封面和不合法地址不会当媒体使用', () {
    final room = {
      'cover': {
        'url_list': ['javascript:bad', 'https://images.test/a.jpg'],
      },
    };
    expect(
      DouyinCategoryPictures.parsePicture({
        'data': [
          {'data': jsonEncode(room)},
        ],
      }),
      'https://images.test/a.jpg',
    );
    expect(
      DouyinCategoryPictures.parsePicture({'status_code': 2483, 'data': []}),
      '',
    );
  });

  testWidgets('禁用远程图片不补图，可见卡片重建不重复请求', (tester) async {
    final platform = _PicturePlatform();
    Widget mount(bool enabled) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 180,
          height: 146,
          child: LiveCategoryImage(
            platform: platform,
            category: area(1),
            imagesEnabled: enabled,
            fallback: const Icon(Icons.live_tv_rounded),
          ),
        ),
      ),
    );
    await tester.pumpWidget(mount(false));
    await tester.pumpAndSettle();
    expect(platform.calls, 0);
    await tester.pumpWidget(mount(true));
    await tester.pumpAndSettle();
    expect(platform.calls, 1);
    await tester.pumpWidget(mount(true));
    await tester.pumpAndSettle();
    expect(platform.calls, 1);
    expect(find.byIcon(Icons.live_tv_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
