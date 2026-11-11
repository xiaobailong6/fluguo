import 'dart:async';

import 'package:duanju_app/ui/widgets/poster_menu_lifecycle.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:duanju_app/ui/widgets/glass/glass_dialog.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:duanju_app/ui/widgets/poster_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('海报仅通过玻璃三点按钮打开菜单，坐标锚定按钮', (tester) async {
    Offset? anchor;
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 160,
              height: 320,
              child: ProgressPoster(
                drama: drama('menu'),
                width: 160,
                progress: 0,
                caption: '未观看',
                cover: const ColoredBox(color: Colors.grey),
                onTap: () => opens++,
                onMore: (point) => anchor = point,
              ),
            ),
          ),
        ),
      ),
    );
    final menu = find.byTooltip('追剧菜单');
    expect(menu, findsOneWidget);
    final glass = find.descendant(of: menu, matching: find.byType(GlassSurface));
    expect(glass, findsOneWidget);
    expect(tester.getSize(menu), const Size(44, 44));
    expect(tester.getSize(glass), const Size(30, 30));
    expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).size, 18);
    final posterRect = tester.getRect(find.byType(ProgressPoster));
    expect(tester.getTopRight(glass), posterRect.topRight + const Offset(-6, 6));
    final poster = find.byType(ProgressPoster);
    await tester.longPressAt(tester.getTopLeft(poster) + const Offset(30, 80));
    await tester.pump();
    expect(anchor, isNull);
    final opensBeforeMenu = opens;
    final menuRect = tester.getRect(glass);
    await tester.tap(menu);
    await tester.pump();
    expect(anchor, menuRect.bottomRight);
    expect(opens, opensBeforeMenu);
    await tester.tapAt(tester.getTopLeft(poster) + const Offset(30, 80));
    expect(opens, opensBeforeMenu + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('短剧海报三点恢复原大小，弹窗菜单进一步紧凑且无横条', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: Builder(builder: (context) => Center(
            child: SizedBox(
              width: 160,
              child: DramaTile(
                drama: drama('compact'),
                onTap: () {},
                onMore: (anchor) => showPosterMenu(context, anchor, const [
                  PosterMenuItem('follow', '追剧', Icons.bookmark_rounded),
                  PosterMenuItem('remove', '移除', Icons.delete_outline_rounded),
                ]),
              ),
            ),
          )),
        ),
      ),
    );
    final button = find.byTooltip('追剧菜单');
    final chrome = find.descendant(of: button, matching: find.byType(GlassSurface));
    expect(tester.getSize(button), const Size(44, 44));
    expect(tester.getSize(chrome), const Size(30, 30));
    expect(tester.widget<Icon>(find.byIcon(Icons.more_horiz_rounded)).size, 18);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(Divider), findsNothing);
    final panel = find.byWidgetPredicate((widget) =>
        widget is GlassSurface && widget.role == GlassRole.panel);
    expect(panel, findsOneWidget);
    expect(tester.getSize(panel).width, lessThanOrEqualTo(220));
    expect(tester.widget<GlassSurface>(panel).padding, const EdgeInsets.all(3));
    final row = find.widgetWithText(InkWell, '追剧');
    expect(tester.getSize(row).height, 32);
    expect(tester.widget<Text>(find.text('追剧')).style!.fontSize, 14);
    expect(tester.widget<Icon>(find.byIcon(Icons.bookmark_rounded)).size, 18);
    await tester.tap(find.text('移除'));
    await tester.pumpAndSettle();
    expect(panel, findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('菜单覆盖按钮并右对齐，淡入淡出连续且结果等待离场', (tester) async {
    var calls = 0;
    var taps = 0;
    var returned = false;
    String? result;
    await tester.pumpWidget(_posterApp((context, anchor) {
      calls++;
      unawaited(showPosterMenu(context, anchor, _items).then((value) {
        returned = true;
        result = value;
      }));
    }, onTap: () => taps++));
    final button = find.byTooltip('追剧菜单');
    final chrome = find.descendant(of: button, matching: find.byType(GlassSurface));
    final rect = tester.getRect(chrome);
    await tester.tap(button);
    await tester.pump();
    final opacity = find.ancestor(of: button, matching: find.byType(AnimatedOpacity));
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    expect(tester.widget<IgnorePointer>(find.ancestor(
      of: button, matching: find.byType(IgnorePointer)).first).ignoring, isTrue);
    expect(tester.widget<ExcludeFocus>(find.ancestor(
      of: button, matching: find.byType(ExcludeFocus)).first).excluding, isTrue);
    final panelOpacity = find.byKey(const ValueKey('poster-menu-opacity'));
    expect(tester.widget<Opacity>(panelOpacity).opacity, 0);
    final route = ModalRoute.of(tester.element(find.text('追剧')))!;
    expect(route.transitionDuration, const Duration(milliseconds: 320));
    expect(route.reverseTransitionDuration, const Duration(milliseconds: 220));
    await tester.pump(const Duration(milliseconds: 160));
    final enteringOpacity = tester.widget<Opacity>(panelOpacity).opacity;
    expect(enteringOpacity, greaterThan(.1));
    expect(enteringOpacity, lessThan(.9));
    await tester.pumpAndSettle();
    expect(tester.getTopRight(_panel).dx, closeTo(rect.right, .01));
    expect(tester.getTopRight(_panel).dy, closeTo(rect.top, .01));
    expect(tester.widget<Opacity>(panelOpacity).opacity, 1);
    await tester.tap(find.text('追剧'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    final leavingOpacity = tester.widget<Opacity>(panelOpacity).opacity;
    expect(leavingOpacity, greaterThan(.1));
    expect(leavingOpacity, lessThan(.9));
    expect(returned, isFalse);
    expect(_panel, findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 0);
    await tester.pumpAndSettle();
    expect(result, 'follow');
    expect(returned, isTrue);
    expect(_panel, findsNothing);
    expect(tester.widget<AnimatedOpacity>(opacity).opacity, 1);
    expect(calls, 1);
    expect(taps, 0);
  });

  testWidgets('外部取消和返回均恢复三点，重复调用不叠加 route', (tester) async {
    final results = <String?>[];
    await tester.pumpWidget(_posterApp((context, anchor) {
      unawaited(showPosterMenu(context, anchor, _items).then(results.add));
      unawaited(showPosterMenu(context, anchor, _items));
    }));
    final button = find.byTooltip('追剧菜单');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, <String?>[null]);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(results, <String?>[null, null]);
    expect(_panel, findsNothing);
  });

  testWidgets('菜单自动获取键盘焦点，Enter 不触发海报', (tester) async {
    var taps = 0;
    String? result;
    await tester.pumpWidget(_posterApp((context, anchor) {
      unawaited(showPosterMenu(context, anchor, _items).then((value) => result = value));
    }, onTap: () => taps++));
    await tester.tap(find.byTooltip('追剧菜单'));
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus?.context, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(result, 'follow');
    expect(taps, 0);
  });

  for (final accessible in [false, true]) {
    testWidgets('减少动画设置即时关闭 accessible=$accessible', (tester) async {
      var returned = false;
      await tester.pumpWidget(_posterApp((context, anchor) {
        unawaited(showPosterMenu(context, anchor, _items).then((_) => returned = true));
      }, media: MediaQueryData(
        disableAnimations: !accessible,
        accessibleNavigation: accessible,
      )));
      await tester.tap(find.byTooltip('追剧菜单'));
      await tester.pumpAndSettle();
      final opacity = tester.widget<AnimatedOpacity>(find.ancestor(
        of: find.byTooltip('追剧菜单'), matching: find.byType(AnimatedOpacity)));
      expect(opacity.duration, Duration.zero);
      final route = ModalRoute.of(tester.element(find.text('追剧')))!;
      expect(route.transitionDuration, Duration.zero);
      expect(route.reverseTransitionDuration, Duration.zero);
      await tester.tap(find.text('追剧'));
      await tester.pumpAndSettle();
      expect(returned, isTrue);
      expect(_panel, findsNothing);
    });
  }

  testWidgets('菜单覆盖锚点并收敛到安全区，宽度支持字体缩放及键盘', (tester) async {
    const media = MediaQueryData(
      size: Size(800, 600),
      padding: EdgeInsets.fromLTRB(24, 28, 30, 0),
      viewInsets: EdgeInsets.only(bottom: 220),
      textScaler: TextScaler.linear(2),
    );
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(data: media, child: child!),
      home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showPosterMenu(context, const Offset(45, 65), _items,
          minWidth: 140),
        child: const Text('打开'),
      ))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(_panel);
    expect(rect.top, closeTo(40, .01));
    expect(rect.left, greaterThanOrEqualTo(36));
    expect(rect.right, lessThanOrEqualTo(758));
    expect(rect.bottom, lessThanOrEqualTo(368));
    expect(rect.width, greaterThanOrEqualTo(280));
    expect(tester.takeException(), isNull);
  });

  testWidgets('最小宽度超过窄屏时仍限制在可用宽度内', (tester) async {
    tester.view.physicalSize = const Size(240, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showPosterMenu(context, const Offset(230, 100), _items,
          minWidth: 500),
        child: const Text('打开'),
      ))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(_panel);
    expect(rect.left, greaterThanOrEqualTo(12));
    expect(rect.right, lessThanOrEqualTo(228));
    expect(rect.width, lessThanOrEqualTo(216));
    expect(tester.takeException(), isNull);
  });

  testWidgets('底部锚点的菜单右侧对齐且整体移回可见区域', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => TextButton(
        onPressed: () => showPosterMenu(context, const Offset(700, 590), _items),
        child: const Text('打开'),
      ))),
    ));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(_panel);
    expect(rect.right, closeTo(700, .01));
    expect(rect.bottom, lessThanOrEqualTo(588));
    expect(rect.top, greaterThanOrEqualTo(12));
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  });

  testWidgets('等待菜单后打开确认框时旧面板已经移除', (tester) async {
    int? panelsAtContinuation;
    await tester.pumpWidget(_posterApp((context, anchor) async {
      final action = await showPosterMenu(context, anchor, _items);
      panelsAtContinuation = _panel.evaluate().length;
      if (action != null && context.mounted) {
        await showGlassDialog<void>(
          context,
          builder: (_) => const GlassDialogBody(title: '确认操作'),
        );
      }
    }));
    await tester.tap(find.byTooltip('追剧菜单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('追剧'));
    await tester.pumpAndSettle();
    expect(panelsAtContinuation, 0);
    expect(find.text('确认操作'), findsOneWidget);
    expect(_panel, findsNothing);
  });

  testWidgets('回调非菜单不留 busy；海报 dispose 后关闭菜单安全', (tester) async {
    var calls = 0;
    await tester.pumpWidget(_posterApp((_, _) => calls++));
    await tester.tap(find.byTooltip('追剧菜单'));
    await tester.tap(find.byTooltip('追剧菜单'));
    expect(calls, 2);
    late StateSetter update;
    var visible = true;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => AppScope(repository: FakeRepository(),
        formFactor: FormFactor.phone, child: child!),
      home: Scaffold(body: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return visible ? Center(child: ProgressPoster(
          drama: drama('dispose'), caption: '', progress: null,
          cover: const ColoredBox(color: Colors.grey), onTap: () {},
          onMore: (anchor) => showPosterMenu(context, anchor, _items),
        )) : const SizedBox.shrink();
      })),
    ));
    await tester.tap(find.byTooltip('追剧菜单'));
    await tester.pumpAndSettle();
    update(() => visible = false);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('show 失败和同步回调异常都不遗留 activity', (tester) async {
    final activity = PosterMenuActivity();
    await tester.pumpWidget(Builder(builder: (context) {
      return const SizedBox();
    }));
    final context = tester.element(find.byType(SizedBox));
    late Future<String?> failed;
    activity.invoke(() {
      failed = showPosterMenu(context, Offset.zero, _items);
    });
    await expectLater(failed, throwsA(isA<FlutterError>()));
    expect(activity.value, isFalse);
    expect(() => activity.invoke(() => throw StateError('callback')), throwsStateError);
    var invoked = false;
    activity.invoke(() => invoked = true);
    expect(invoked, isTrue);
    activity.dispose();
  });
}

const _items = [
  PosterMenuItem('follow', '追剧', Icons.bookmark_rounded),
  PosterMenuItem('remove', '移除', Icons.delete_outline_rounded),
];

final _panel = find.byWidgetPredicate((widget) =>
    widget is GlassSurface && widget.role == GlassRole.panel);

Widget _posterApp(
  void Function(BuildContext, Offset) onMore, {
  VoidCallback? onTap,
  MediaQueryData? media,
}) => MaterialApp(
  builder: (context, child) => AppScope(
    repository: FakeRepository(),
    formFactor: FormFactor.television,
    child: MediaQuery(data: media ?? MediaQuery.of(context), child: child!),
  ),
  home: Scaffold(body: Builder(builder: (context) => Center(
    child: SizedBox(width: 160, child: ProgressPoster(
      drama: drama('animated-menu'), width: 160, progress: null,
      caption: '未观看', cover: const ColoredBox(color: Colors.grey),
      onTap: onTap ?? () {}, onMore: (anchor) => onMore(context, anchor),
    )),
  ))),
);
