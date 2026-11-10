import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/app_notice.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<BuildContext> mountNotice(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
  bool reduced = false,
  bool highContrast = false,
}) async {
  late BuildContext target;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.orange,
          brightness: brightness,
        ),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: padding,
          textScaler: TextScaler.linear(textScale),
          accessibleNavigation: reduced,
          highContrast: highContrast,
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) {
          target = context;
          return Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: TextButton(onPressed: () {}, child: const Text('页面按钮')),
            ),
          );
        },
      ),
    ),
  );
  await tester.pumpAndSettle();
  return target;
}

void main() {
  testWidgets('气泡随内容变宽，短句不占满桌面，长文本限制最大宽度', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final context = await mountNotice(tester);
    final bubble = find.byKey(const ValueKey('app-notice'));
    showAppNotice(context, '完成');
    await tester.pumpAndSettle();
    final short = tester.getSize(bubble).width;
    expect(short, lessThan(220));
    expect(tester.getCenter(bubble).dx, closeTo(500, .5));
    showAppNotice(context, '播放偏好已保存，下次进入时会自动恢复');
    await tester.pumpAndSettle();
    expect(tester.getSize(bubble).width, greaterThan(short));
    showAppNotice(context, List.filled(50, '长内容').join());
    await tester.pumpAndSettle();
    expect(tester.getSize(bubble).width, lessThanOrEqualTo(560));
    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  test('通知在黑白及中间背景上保证至少4.5对比度', () {
    for (var gray = 0; gray <= 255; gray++) {
      final colors = AppNotice.readableColors(
        Color.fromARGB(240, gray, gray, gray),
        Colors.white.withValues(alpha: .3),
      );
      expect(colors.foreground.a, 1);
      for (final backing in [
        Colors.black,
        Colors.white,
        Colors.red,
        Colors.green,
        Colors.blue,
        const Color(0xFF777777),
      ]) {
        final background = Color.alphaBlend(colors.background, backing);
        expect(
          AppNotice.contrast(colors.foreground, background),
          greaterThanOrEqualTo(4.5),
          reason: 'gray=$gray backing=$backing',
        );
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('顶部玻璃通知在${brightness.name}主题可读且不阻挡页面', (tester) async {
      final context = await mountNotice(
        tester,
        brightness: brightness,
        padding: const EdgeInsets.only(top: 44),
      );
      showAppNotice(context, '设置已保存');
      await tester.pumpAndSettle();
      final bubble = find.byKey(const ValueKey('app-notice'));
      expect(bubble, findsOneWidget);
      expect(tester.getRect(bubble).top, greaterThanOrEqualTo(44));
      expect(tester.getRect(bubble).bottom, lessThan(200));
      expect(find.byType(SnackBar), findsNothing);
      final surface = tester.widget<GlassSurface>(bubble);
      final style = surface.style!;
      expect(surface.radius, GlassRadius.pill);
      expect(style.tint.a, greaterThanOrEqualTo(.98));
      expect(style.sheen.a, 0);
      expect(style.rimShadow.a, 0);
      expect(style.borderWidth, greaterThanOrEqualTo(1));
      expect(style.shadow, isNotEmpty);
      final pageBackground = Theme.of(context).colorScheme.surface;
      expect(
        AppNotice.contrast(
          Color.alphaBlend(style.tint, pageBackground),
          pageBackground,
        ),
        greaterThanOrEqualTo(3),
      );
      final text = tester.widget<Text>(find.text('设置已保存'));
      for (final backing in [Colors.black, Colors.white]) {
        expect(
          AppNotice.contrast(
            text.style!.color!,
            Color.alphaBlend(style.tint, backing),
          ),
          greaterThanOrEqualTo(4.5),
        );
      }
      await tester.tap(find.text('页面按钮'));
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('关闭通知'));
      await tester.pumpAndSettle();
      expect(bubble, findsNothing);
    });
  }

  testWidgets('高对比度使用不透明胶囊且不创建背景模糊', (tester) async {
    final context = await mountNotice(tester, highContrast: true);
    showAppNotice(context, '清晰提示');
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('app-notice'));
    final surface = tester.widget<GlassSurface>(bubble);
    expect(surface.style!.tier, GlassTier.none);
    expect(surface.style!.tint.a, 1);
    expect(surface.radius, GlassRadius.pill);
    expect(
      find.descendant(of: bubble, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();
  });

  testWidgets('连续通知替换旧消息，自动关闭不留下计时器', (tester) async {
    final context = await mountNotice(tester);
    showAppNotice(context, '旧消息', duration: const Duration(seconds: 1));
    showAppNotice(context, '新消息', duration: const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.text('旧消息'), findsNothing);
    expect(find.text('新消息'), findsOneWidget);
    expect(find.byKey(const ValueKey('app-notice')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('新消息'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(AppMotion.exit);
    await tester.pump(const Duration(milliseconds: 17));
    expect(find.byKey(const ValueKey('app-notice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('退出途中停止点击，最新消息复用入口并重置计时', (tester) async {
    final context = await mountNotice(tester);
    showAppNotice(context, '将关闭', duration: const Duration(seconds: 1));
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('app-notice'));
    final element = tester.element(bubble);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 80));
    expect(bubble, findsOneWidget);
    final ignore = find.ancestor(
      of: bubble,
      matching: find.byType(IgnorePointer),
    );
    expect(
      ignore.evaluate().any((e) => (e.widget as IgnorePointer).ignoring),
      isTrue,
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: bubble, matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, inExclusiveRange(0, 1));
    showAppNotice(context, '最新', duration: const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(tester.element(bubble), same(element));
    expect(find.text('将关闭'), findsNothing);
    expect(find.text('最新'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(bubble, findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(AppMotion.exit);
    await tester.pump(const Duration(milliseconds: 17));
    expect(bubble, findsNothing);
  });

  testWidgets('辅助导航立即显示和移除，Overlay销毁会取消计时', (tester) async {
    final context = await mountNotice(tester, reduced: true);
    final notice = AppNotice.of(context);
    notice.show('无动画', duration: const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('无动画'), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('无动画'), findsNothing);
    notice.show('销毁前');
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    notice.show('销毁后');
    expect(tester.takeException(), isNull);
  });

  testWidgets('窄屏大字体长消息保持单行省略且关闭按钮可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final context = await mountNotice(tester, textScale: 2.5);
    showAppNotice(context, List.filled(25, '这是需要完整展示的错误说明。').join());
    await tester.pumpAndSettle();
    final bubble = find.byKey(const ValueKey('app-notice'));
    expect(tester.getSize(bubble).width, lessThanOrEqualTo(288));
    expect(tester.getSize(bubble).height, lessThan(260));
    final text = tester.widget<Text>(
      find.descendant(of: bubble, matching: find.byType(Text)).first,
    );
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    await tester.tap(find.byTooltip('关闭通知'));
    await tester.pumpAndSettle();
    expect(bubble, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面退出后异步任务仍可使用捕获的根通知句柄', (tester) async {
    final context = await mountNotice(tester);
    late AppNotice notice;
    final navigator = Navigator.of(context);
    final route = MaterialPageRoute<void>(
      builder: (context) {
        notice = AppNotice.of(context);
        return const Scaffold(body: Text('任务页面'));
      },
    );
    final closed = navigator.push(route);
    await tester.pumpAndSettle();
    navigator.pop();
    await tester.pumpAndSettle();
    await closed;
    notice.show('任务已完成');
    await tester.pumpAndSettle();
    expect(find.text('任务已完成'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    notice.show('不应访问已销毁的Overlay');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
