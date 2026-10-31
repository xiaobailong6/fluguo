import 'package:duanju_app/live_bilibili.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/source_actions.dart';
import 'package:duanju_app/ui/live/live_navigation.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';
import 'package:duanju_app/ui/widgets/glass/glass_selector.dart';
import 'package:duanju_app/ui/widgets/source_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class CountingObserver extends NavigatorObserver {
  int pushes = 0;
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
    latest = route;
  }
}

void main() {
  testWidgets('直播播放路由禁用截图缓存，普通直播子页保持默认', (tester) async {
    final store = await openStore();
    final observer = CountingObserver();
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: Builder(
          builder: (context) {
            pageContext = context;
            return const Scaffold(body: Text('直播入口'));
          },
        ),
      ),
    );

    final playback = openLivePlayer(
      pageContext,
      store,
      livePlatforms.first,
      const LiveRoom(
        roomId: '1',
        title: '测试',
        anchor: '',
        cover: '',
        area: '',
        online: '',
      ),
    );
    final videoRoute = observer.latest! as MaterialPageRoute<void>;
    expect(videoRoute.allowSnapshotting, isFalse);
    // 挂载播放器前移除路由，只验证真实入口配置，不初始化原生播放器。
    Navigator.of(pageContext).removeRoute(videoRoute);
    await playback;
    await tester.pumpAndSettle();

    final normal = pushLivePage<void>(
      pageContext,
      (_) => const Scaffold(body: Text('普通直播子页')),
    );
    final normalRoute = observer.latest! as MaterialPageRoute<void>;
    expect(normalRoute.allowSnapshotting, isTrue);
    Navigator.of(pageContext).removeRoute(normalRoute);
    await normal;
    await tester.pumpAndSettle();
  });

  testWidgets('直播子页使用内层 Navigator，返回仍在直播页', (tester) async {
    final root = CountingObserver();
    final tab = CountingObserver();
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [root],
        home: Navigator(
          observers: [tab],
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const Text('直播页'),
                  TextButton(
                    onPressed: () => pushLivePage<void>(
                      context,
                      (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => Navigator.maybePop(context),
                          child: const Text('返回直播'),
                        ),
                      ),
                    ),
                    child: const Text('打开直播子页'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开直播子页'));
    await tester.pumpAndSettle();
    expect(root.pushes, 1);
    expect(tab.pushes, 2);
    await tester.tap(find.text('返回直播'));
    await tester.pumpAndSettle();
    expect(find.text('直播页'), findsOneWidget);
    expect(find.text('打开直播子页'), findsOneWidget);
  });

  testWidgets('短剧标题触发相同玻璃下拉，不再显示地球切换图标', (tester) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: SourceBar(
            source: '红果',
            onSwitchSource: (anchor) async {
              selected = await showGlassSelector<String>(
                anchor: anchor,
                options: const [
                  ChoiceOption('red', '红果'),
                  ChoiceOption('other', '其他站源'),
                ],
                selected: 'red',
              );
            },
            onOpenSearch: () {},
            onSearchSubmitted: (_) {},
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.public_rounded), findsNothing);
    await tester.tap(find.text('红果'));
    await tester.pumpAndSettle();
    expect(find.text('其他站源'), findsOneWidget);
    await tester.tap(find.text('其他站源'));
    await tester.pumpAndSettle();
    expect(selected, 'other');
    expect(tester.takeException(), isNull);
  });
  testWidgets('实际短剧切源菜单不包含管理站源', (tester) async {
    final store = await openStore();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => pickSource(context, store),
              child: const Text('切换站源'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('切换站源'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('short-source-menu')), findsOneWidget);
    expect(find.text('红果'), findsOneWidget);
    expect(find.text('管理站源'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });
}
