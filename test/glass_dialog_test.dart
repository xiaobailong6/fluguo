import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/glass/glass_dialog.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Widget _host(Widget child) => MaterialApp(
  builder: (context, page) => AppScope(
    repository: FakeRepository(),
    formFactor: FormFactor.phone,
    child: page!,
  ),
  home: Scaffold(body: child),
);

final _panel = find.byWidgetPredicate(
  (widget) => widget is GlassSurface && widget.role == GlassRole.panel,
);

void main() {
  testWidgets('玻璃对话框渲染标题、正文与按钮并返回所选值', (tester) async {
    String? result;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () async {
                result = await showGlassDialog<String>(
                  context,
                  builder: (context) => GlassDialogBody(
                    title: '确认操作',
                    message: '这一段是说明文字。',
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, 'cancel'),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, 'ok'),
                        child: const Text('确定'),
                      ),
                    ],
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.text('确认操作'), findsOneWidget);
    expect(find.text('这一段是说明文字。'), findsOneWidget);
    expect(_panel, findsOneWidget);
    // 对话框必须用 dialog 预设的较实染色，保证正文可读。
    expect(
      tester.widget<GlassSurface>(_panel).style!.tint.a,
      greaterThan(GlassPreset.menu.tintAlpha),
    );

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(result, 'ok');
    expect(_panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('无按钮的进度对话框不渲染操作区留白', (tester) async {
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showGlassDialog<void>(
                context,
                dismissible: false,
                builder: (context) => const GlassDialogBody(
                  title: '正在迁移',
                  content: Text('请保持应用运行'),
                ),
              ),
              child: const Text('开始'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('正在迁移'), findsOneWidget);
    expect(_panel, findsOneWidget);
    expect(
      find.descendant(of: _panel, matching: find.byType(Wrap)),
      findsNothing,
    );

    // dismissible=false：点遮罩与返回键都不应关闭。
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_panel, findsOneWidget);

    // 仍可由调用方主动收起。
    Navigator.of(tester.element(find.text('正在迁移')), rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(_panel, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长正文在对话框内部滚动，标题与按钮保持可见', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showGlassDialog<void>(
                context,
                builder: (context) => GlassDialogBody(
                  title: '剧情简介',
                  scrollController: controller,
                  content: Text(List.filled(80, '很长的简介文字。').join()),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('关闭'),
                    ),
                  ],
                ),
              ),
              child: const Text('查看'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('查看'));
    await tester.pumpAndSettle();
    expect(find.text('剧情简介'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(controller.hasClients, isTrue);
    final dialogBottom = tester.getBottomLeft(_panel).dy;
    expect(
      tester.getBottomLeft(find.text('关闭')).dy,
      lessThanOrEqualTo(dialogBottom),
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
