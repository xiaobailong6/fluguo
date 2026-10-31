import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/live/live_page.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class PageLive extends LivePlatform {
  @override
  String get id => 'bilibili';
  @override
  String get name => '哔哩哔哩';
  final queries = <String>[];
  String areaPicture = '';
  @override
  Future<List<LiveCategory>> categories() async => [
    LiveCategory(
      name: '网游',
      parentId: '2',
      children: [
        LiveCategory(
          name: '英雄联盟',
          parentId: '2',
          areaId: '86',
          picture: areaPicture,
        ),
      ],
    ),
  ];
  @override
  Future<List<LiveRoom>> rooms(LiveCategory category, {int page = 1}) async =>
      page > 1
      ? []
      : List.generate(
          30,
          (i) => LiveRoom(
            roomId: '$i',
            title: '直播$i',
            anchor: '主播',
            cover: '',
            area: category.name,
            online: '',
          ),
        );
  @override
  Future<List<LiveRoom>> search(String keyword, {int page = 1}) async {
    queries.add(keyword);
    return [];
  }

  @override
  Future<LiveStream> resolve(LiveRoom room, {int quality = 10000}) async =>
      throw UnsupportedError('测试不打开原生播放器');
}

Future<void> mount(
  WidgetTester tester,
  LocalStore store,
  PageLive platform, {
  bool glass = true,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          glass: glass,
          child: child!,
        ),
      ),
      home: LivePage(store: store, platform: platform),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('显式注入平台优先，仍按保存 ID 恢复该平台一级分类', (tester) async {
    final store = await openStore();
    await store.rememberLiveBrowse(
      'douyu',
      '999',
      profileEpoch: store.profileEpoch,
    );
    await store.rememberLiveBrowse(
      'bilibili',
      '2',
      profileEpoch: store.profileEpoch,
    );
    await store.rememberLiveBrowse(
      'douyu',
      null,
      profileEpoch: store.profileEpoch,
    );
    final platform = PageLive();
    await mount(tester, store, platform);
    expect(find.text('哔哩哔哩'), findsOneWidget);
    expect(find.text('网游'), findsOneWidget);
    expect(find.text('英雄联盟'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('直播两块顶栏关闭阴影且收藏入口能列出已收藏主播', (tester) async {
    final store = await openStore();
    await store.toggleLiveFavorite(
      'douyu',
      const LiveRoom(
        roomId: '123',
        title: '游戏直播',
        anchor: '已收藏主播',
        cover: '',
        area: '游戏',
        online: '',
      ),
    );
    await mount(tester, store, PageLive());
    final header = find.byKey(const ValueKey('live-header-card'));
    final material = find.descendant(
      of: header,
      matching: find.byType(GlassSurface),
    );
    expect(tester.widget<GlassSurface>(material).showShadow, isFalse);
    await tester.tap(find.byTooltip('直播收藏'));
    await tester.pumpAndSettle();
    expect(find.textContaining('已收藏主播'), findsOneWidget);
    expect(find.text('斗鱼'), findsOneWidget);
    await tester.tap(find.text('管理'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('favorite-douyu:123')));
    await tester.pump();
    await tester.tap(find.text('取消收藏（1）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消收藏'));
    await tester.pumpAndSettle();
    expect(find.text('还没有收藏主播'), findsOneWidget);
    expect(store.liveFavorites, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('平台菜单紧凑且文字和对勾同尺寸', (tester) async {
    final store = await openStore();
    await mount(tester, store, PageLive());
    await tester.tap(find.text('哔哩哔哩'));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('live-platform-menu'));
    expect(tester.getSize(menu).width, 188);
    final title = tester.widget<Text>(
      find.descendant(of: menu, matching: find.text('哔哩哔哩')),
    );
    final check = tester.widget<Icon>(
      find.descendant(of: menu, matching: find.byIcon(Icons.check_rounded)),
    );
    expect(title.style!.fontSize, check.size);
    expect(tester.takeException(), isNull);
  });

  testWidgets('图标分类卡片和搜索入口，搜索空结果保留关键词', (tester) async {
    final store = await openStore();
    final platform = PageLive();
    await mount(tester, store, platform, glass: false);
    expect(find.byKey(const ValueKey('live-area-86')), findsOneWidget);
    expect(find.text('网游 · 二级分区'), findsOneWidget);
    expect(find.byKey(const ValueKey('live-all-areas')), findsOneWidget);
    expect(find.byIcon(Icons.live_tv_rounded), findsOneWidget);
    await tester.tap(find.byTooltip('搜索直播'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('live-search-field'));
    await tester.enterText(field, '英雄');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(platform.queries, ['英雄']);
    expect(find.text('搜索 / 英雄'), findsOneWidget);
    expect(find.text('没有找到相关直播'), findsOneWidget);
    await tester.tap(find.text('返回分区'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('live-area-86')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('上滑大卡片消失且分区吸顶，下滑展开不重叠', (tester) async {
    final store = await openStore();
    await mount(tester, store, PageLive());
    await tester.tap(find.byKey(const ValueKey('live-area-86')));
    await tester.pumpAndSettle();
    final scroll = find.byKey(const ValueKey('live-scroll'));
    final header = find.byKey(const ValueKey('live-header-card'));
    final navigation = find
        .ancestor(of: find.text('返回分区'), matching: find.byType(GlassSurface))
        .first;
    final controller = tester.widget<CustomScrollView>(scroll).controller!;
    controller.jumpTo(500);
    await tester.pumpAndSettle();
    expect(tester.getRect(header).bottom, lessThanOrEqualTo(1));
    expect(tester.getRect(navigation).top, closeTo(4, 1));
    final gesture = await tester.startGesture(const Offset(180, 350));
    for (var i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 18));
      await tester.pump(const Duration(milliseconds: 16));
      final big = tester.getRect(header);
      final small = tester.getRect(navigation);
      expect(small.top, greaterThanOrEqualTo(big.bottom - 1));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getRect(header).bottom, greaterThan(100));
    expect(tester.takeException(), isNull);
  });
  testWidgets('二级分区右侧四点按钮展开完整分类并可选择', (tester) async {
    final store = await openStore();
    await mount(tester, store, PageLive());
    final button = find.byKey(const ValueKey('live-all-areas'));
    expect(button, findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('全部二级分区'), findsOneWidget);
    await tester.tap(find.text('英雄联盟').last);
    await tester.pumpAndSettle();
    expect(find.text('全部二级分区'), findsNothing);
    expect(find.text('返回分区'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('禁用远程图片时分区封面不创建网络图片', (tester) async {
    final store = await openStore();
    final platform = PageLive()..areaPicture = 'https://example.test/area.jpg';
    await mount(tester, store, platform);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.live_tv_rounded), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final scale in [1.0, 1.5]) {
    testWidgets('四点图标匹配相邻字号并水平对齐：$scale', (tester) async {
      final store = await openStore();
      await mount(tester, store, PageLive(), textScale: scale);

      void expectAligned(String label) {
        final text = find.text(label);
        final button = find.byKey(const ValueKey('live-all-areas'));
        final icon = find.descendant(
          of: button,
          matching: find.byIcon(Icons.grid_view_rounded),
        );
        final widget = tester.widget<Text>(text);
        final context = tester.element(text);
        final fontSize =
            (widget.style ?? DefaultTextStyle.of(context).style).fontSize!;
        expect(tester.getSize(icon).height, closeTo(fontSize * scale, .01));
        expect(
          tester.getCenter(icon).dy,
          closeTo(tester.getCenter(text).dy, .5),
        );
        expect(tester.getSize(button).height, greaterThanOrEqualTo(40));
      }

      expectAligned('网游 · 二级分区');
      await tester.tap(find.byKey(const ValueKey('live-area-86')));
      await tester.pumpAndSettle();
      expectAligned('网游 / 英雄联盟');
      final back = find.ancestor(
        of: find.text('返回分区'),
        matching: find.byType(TextButton),
      );
      expect(
        find.descendant(
          of: back,
          matching: find.byIcon(Icons.arrow_back_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.grid_view_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
