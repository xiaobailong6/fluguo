import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:duanju_app/ui/shell/tab_page_transition.dart';
import 'package:duanju_app/ui/widgets/scroll_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'ui_performance_test.dart' as shell;
import 'live_page_test.dart' as live;

Finder motion(String key) => find.byKey(ValueKey(key));
AnimatedSlide slide(WidgetTester tester, String key) =>
    tester.widget<AnimatedSlide>(
      find
          .descendant(of: motion(key), matching: find.byType(AnimatedSlide))
          .first,
    );
double alpha(WidgetTester tester, String key) => tester
    .widget<FadeTransition>(
      find
          .descendant(of: motion(key), matching: find.byType(FadeTransition))
          .first,
    )
    .opacity
    .value;

void main() {
  test('慢滑累计触发显隐，微小回弹不抖动，越界钳制', () {
    final chrome = ScrollChromeController(hideAfter: 96);
    for (var i = 1; i <= 160; i++) {
      chrome.track(i.toDouble(), maxExtent: 500);
    }
    expect(chrome.value, isTrue);
    for (final value in [159.0, 160.0, 158.0, 160.0]) {
      chrome.track(value, maxExtent: 500);
    }
    expect(chrome.value, isTrue);
    for (var i = 159; i >= 140; i--) {
      chrome.track(i.toDouble(), maxExtent: 500);
    }
    expect(chrome.value, isFalse);
    chrome.track(-30, maxExtent: 500);
    expect(chrome.value, isFalse);
    chrome.dispose();
  });

  for (final reduced in [false, true]) {
    testWidgets('短剧真实回顶按钮与顶底栏显隐 reduced=$reduced', (tester) async {
      final store = await openStore();
      await shell.mountShell(tester, store, reduceMotion: reduced);
      final scroll = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      final header = motion('explore-chrome-motion');
      final bottom = motion('bottom-chrome-motion');
      final initialBottom = tester.element(bottom);
      scroll.jumpTo(600);
      await tester.pump();
      expect(tester.element(bottom), same(initialBottom));
      expect(slide(tester, 'bottom-chrome-motion').offset.dy, greaterThan(0));
      expect(slide(tester, 'explore-chrome-motion').offset.dy, lessThan(0));
      expect(
        slide(tester, 'bottom-chrome-motion').duration,
        reduced ? Duration.zero : AppMotion.chrome,
      );
      if (!reduced) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(alpha(tester, 'bottom-chrome-motion'), inExclusiveRange(0, 1));
        expect(alpha(tester, 'explore-chrome-motion'), inExclusiveRange(0, 1));
      }
      await tester.pumpAndSettle();
      expect(alpha(tester, 'bottom-chrome-motion'), 0);
      // 反向滚动展开，回顶仍应指向短剧页自己的控制器。
      scroll.jumpTo(550);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(alpha(tester, 'bottom-chrome-motion'), 1);
      expect(alpha(tester, 'explore-chrome-motion'), 1);
      await tester.tap(find.byKey(const ValueKey('shell-back-to-top')));
      await tester.pump();
      if (reduced) {
        expect(scroll.offset, 0);
      } else {
        await tester.pump(const Duration(milliseconds: 150));
        expect(scroll.offset, inExclusiveRange(0, 550));
        expect(tester.widget<ScrollChromeVisibility>(header).hidden, isFalse);
        expect(tester.widget<ScrollChromeVisibility>(bottom).hidden, isFalse);
      }
      await tester.pumpAndSettle();
      expect(scroll.offset, closeTo(scroll.position.minScrollExtent, .1));
      expect(tester.widget<ScrollChromeVisibility>(header).hidden, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('焦点不触发回顶，重复点击与动画中切Tab不污染当前滚动栏', (tester) async {
    final store = await openStore();
    await shell.mountShell(tester, store);
    final root = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    root.jumpTo(600);
    await tester.pumpAndSettle();
    root.jumpTo(550);
    await tester.pumpAndSettle();
    final nav = find.byKey(const ValueKey('nav-explore'));
    final focus = Focus.of(
      tester.element(
        find.descendant(of: nav, matching: find.byType(MouseRegion)).last,
      ),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(root.offset, 550);
    await tester.tap(nav);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(nav);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pumpAndSettle();
    // 隐藏页的滚动通知不可将当前空追剧页的底栏收起或显示回顶按钮。
    root.jumpTo(650);
    await tester.pumpAndSettle();
    expect(slide(tester, 'bottom-chrome-motion').offset, Offset.zero);
    expect(
      find.byKey(const ValueKey('shell-back-to-top')).hitTestable(),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('追剧回顶作用当前实际列表，Tab切换保留滚动与动画实例', (tester) async {
    final store = await openStore();
    for (var i = 0; i < 45; i++) {
      await store.toggleFavorite(drama('follow$i'));
    }
    await shell.mountShell(tester, store);
    final exploreState = tester.state(find.byType(ExplorePage));
    final exploreScroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    exploreScroll.jumpTo(500);
    await tester.pumpAndSettle();
    exploreScroll.jumpTo(450);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pump();
    final transition = find
        .ancestor(
          of: find.byType(FollowPage),
          matching: find.byType(TabPageTransition),
        )
        .first;
    final fade = find
        .descendant(of: transition, matching: find.byType(Opacity))
        .first;
    expect(tester.widget<Opacity>(fade).opacity, lessThan(1));
    await tester.pump(
      Duration(microseconds: AppMotion.navigation.inMicroseconds ~/ 3),
    );
    expect(tester.widget<Opacity>(fade).opacity, inExclusiveRange(.72, 1));
    await tester.pumpAndSettle();
    final followState = tester.state(find.byType(FollowPage));
    final followList = find
        .descendant(
          of: find.byType(FollowPage),
          matching: find.byType(Scrollable),
        )
        .first;
    final position = tester.state<ScrollableState>(followList).position;
    position.jumpTo(600);
    await tester.pumpAndSettle();
    position.jumpTo(550);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('shell-back-to-top')));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.minScrollExtent, .1));
    // 快速切回后再切出，不排队也不重建Navigator。
    await tester.tap(find.byKey(const ValueKey('nav-explore')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.state(find.byType(ExplorePage)), same(exploreState));
    expect(exploreScroll.offset, 450);
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(FollowPage)), same(followState));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('子路由滚动不覆盖根页回顶目标，同Tab再次点击回顶', (tester) async {
    final store = await openStore();
    await shell.mountShell(tester, store);
    final root = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    root.jumpTo(600);
    await tester.pumpAndSettle();
    root.jumpTo(550);
    await tester.pumpAndSettle();
    final navigator = Navigator.of(tester.element(find.byType(ExplorePage)));
    final child = ScrollController();
    navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          body: ListView(
            controller: child,
            children: const [SizedBox(height: 3000)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    child.jumpTo(800);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bottom-chrome-motion')), findsNothing);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(root.offset, 550);
    await tester.tap(find.byKey(const ValueKey('shell-back-to-top')));
    await tester.pumpAndSettle();
    expect(root.offset, 0);
    root.jumpTo(600);
    await tester.pumpAndSettle();
    root.jumpTo(550);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-explore')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(root.offset, inExclusiveRange(0, 550));
    await tester.pumpAndSettle();
    expect(root.offset, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    child.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('减少动态效果时Tab即时切换，快速切换保留原实例', (tester) async {
    final store = await openStore();
    await shell.mountShell(tester, store, reduceMotion: true);
    final original = tester.state(find.byType(ExplorePage));
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pump();
    final transition = find
        .ancestor(
          of: find.byType(FollowPage),
          matching: find.byType(TabPageTransition),
        )
        .first;
    expect(
      tester
          .widget<Opacity>(
            find
                .descendant(of: transition, matching: find.byType(Opacity))
                .first,
          )
          .opacity,
      1,
    );
    await tester.tap(find.byKey(const ValueKey('nav-explore')));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ExplorePage)), same(original));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('直播浮动顶栏随滚动连续淡出，吸顶导航不被遮住', (tester) async {
    final store = await openStore();
    await live.mount(tester, store, live.PageLive());
    await tester.tap(find.byKey(const ValueKey('live-area-86')));
    await tester.pumpAndSettle();
    final view = tester.widget<CustomScrollView>(
      find.byKey(const ValueKey('live-scroll')),
    );
    final controller = view.controller!;
    final header = find.byKey(const ValueKey('live-header-card'));
    controller.jumpTo(45);
    await tester.pump();
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: header, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, inExclusiveRange(0, 1));
    controller.jumpTo(400);
    await tester.pumpAndSettle();
    expect(find.text('返回分区').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('浮栏动画中途反向保留当前帧，隐藏立即停止点击', (tester) async {
    var hidden = false;
    var taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ScrollChromeVisibility(
                key: const ValueKey('test-chrome'),
                hidden: hidden,
                hiddenOffset: const Offset(0, 1),
                child: TextButton(
                  onPressed: () => taps++,
                  child: const Text('button'),
                ),
              );
            },
          ),
        ),
      ),
    );
    update(() => hidden = true);
    await tester.pump();
    final blocker = find
        .descendant(
          of: motion('test-chrome'),
          matching: find.byType(IgnorePointer),
        )
        .first;
    expect(tester.widget<IgnorePointer>(blocker).ignoring, isTrue);
    await tester.pump(const Duration(milliseconds: 110));
    final mid = alpha(tester, 'test-chrome');
    expect(mid, inExclusiveRange(0, 1));
    update(() => hidden = false);
    await tester.pump();
    expect(alpha(tester, 'test-chrome'), closeTo(mid, .001));
    await tester.pumpAndSettle();
    await tester.tap(find.text('button'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
}
