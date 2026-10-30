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
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

void main() {
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
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });
}
