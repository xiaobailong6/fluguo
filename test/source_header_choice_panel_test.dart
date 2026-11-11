import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/live/live_page.dart';
import 'package:duanju_app/ui/widgets/bar_button.dart';
import 'package:duanju_app/ui/widgets/choice_panel.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:duanju_app/ui/widgets/source_bar.dart';
import 'package:duanju_app/ui/widgets/source_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'live_page_test.dart' show PageLive;
import 'support/fakes.dart';

Future<void> mount(
  WidgetTester tester,
  Widget child, {
  FormFactor form = FormFactor.phone,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          disableAnimations: true,
        ),
        child: AppScope(
          // 本组只测顶栏，空推荐列表隔离桌面海报横幅自身的最小宽度。
          repository: FakeRepository()..recommended = [],
          formFactor: form,
          child: child!,
        ),
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final form in [FormFactor.phone, FormFactor.window]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('短剧和直播共用标题布局 $form 字号$scale', (tester) async {
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = await openStore();
        await mount(
          tester,
          ExplorePage(store: store),
          form: form,
          scale: scale,
        );
        final header = find.byType(SourceHeader);
        expect(header, findsOneWidget);
        final dramaSize = tester.getSize(header);
        final dramaArrow = tester.widget<Icon>(
          find.descendant(
            of: header,
            matching: find.byIcon(Icons.arrow_drop_down_rounded),
          ),
        );
        final dramaText = tester.widget<Text>(
          find.descendant(of: header, matching: find.byType(Text)).first,
        );
        final dramaButton = tester.widget<TextButton>(
          find.descendant(of: header, matching: find.byType(TextButton)),
        );
        expect(tester.takeException(), isNull);

        await mount(
          tester,
          LivePage(store: store, platform: PageLive()),
          form: form,
          scale: scale,
        );
        expect(tester.getSize(header), dramaSize);
        final liveText = tester.widget<Text>(find.text('哔哩哔哩'));
        expect(liveText.style, dramaText.style);
        expect(
          tester.widget<Icon>(find.byIcon(Icons.arrow_drop_down_rounded)).size,
          dramaArrow.size,
        );
        final liveButton = tester.widget<TextButton>(
          find.descendant(of: header, matching: find.byType(TextButton)),
        );
        expect(liveButton.style!.padding, dramaButton.style!.padding);
        expect(
          find.descendant(of: header, matching: find.byType(BarButton)),
          findsNWidgets(3),
        );
        // 标题仍以真实按钮作为弹层锚点，搜索仍打开原来的直播搜索框。
        await tester.tap(find.byTooltip('切换平台'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('live-platform-menu')),
          findsOneWidget,
        );
        await tester.tapAt(const Offset(380, 700));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('搜索直播'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('live-search-field')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('窄桌面搜索退回按钮，宽窗口仍可提交输入框', (tester) async {
    var searches = 0;
    var switches = 0;
    String? submitted;
    Widget bar() => Scaffold(
      body: SourceBar(
        source: '很长的站源标题',
        onSwitchSource: (_) => switches++,
        onOpenSearch: () => searches++,
        onSearchSubmitted: (value) => submitted = value,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(320, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await mount(tester, bar(), form: FormFactor.window, scale: 2);
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.byTooltip('在 很长的站源标题 中搜索'));
    await tester.tap(find.byTooltip('切换站源'));
    expect(searches, 1);
    expect(switches, 1);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(const Size(1100, 844));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '测试');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, '测试');
    expect(tester.takeException(), isNull);
  });

  for (final title in ['全部分类', '全部二级分区']) {
    for (final brightness in Brightness.values) {
      for (final form in [FormFactor.phone, FormFactor.window]) {
        testWidgets('$title $brightness $form 留白边框及大字体', (tester) async {
          await tester.binding.setSurfaceSize(const Size(360, 844));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          int? result;
          await mount(
            tester,
            Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: Builder(
                  builder: (anchor) => TextButton(
                    onPressed: () async {
                      result = await showChoicePanel<int>(
                        context: anchor,
                        title: title,
                        options: const [
                          ChoiceOption(1, '已选分类'),
                          ChoiceOption(2, '未选分类'),
                        ],
                        selected: 1,
                        grid: ChoiceGrid.categories,
                      );
                    },
                    child: const Text('展开'),
                  ),
                ),
              ),
            ),
            form: form,
            scale: 2,
            brightness: brightness,
          );
          await tester.tap(find.text('展开'));
          await tester.pumpAndSettle();
          final heading = find.text(title);
          final surface = find
              .ancestor(of: heading, matching: find.byType(GlassSurface))
              .first;
          final top = tester.getTopLeft(surface).dy;
          // 标题区收紧到一行的留白，不再留出旧版的两行高度。
          expect(tester.getTopLeft(heading).dy - top, greaterThanOrEqualTo(4));
          expect(tester.getTopLeft(heading).dy - top, lessThan(16));
          expect(
            tester.widget<Text>(heading).style!.fontSize,
            form == FormFactor.phone ? 17 : 16,
          );
          final count = find.text('2 个');
          expect(count, findsOneWidget);
          expect(
            (tester.getCenter(count).dy - tester.getCenter(heading).dy).abs(),
            lessThan(2),
          );
          final route = ModalRoute.of(tester.element(heading))!;
          expect(route.transitionDuration, Duration.zero);
          if (form == FormFactor.phone) {
            expect(
              tester.getTopLeft(find.byTooltip('关闭')).dy - top,
              greaterThanOrEqualTo(4),
            );
          }
          Material cell(String label) => tester.widget<Material>(
            find
                .ancestor(of: find.text(label), matching: find.byType(Material))
                .first,
          );
          final border = (cell('未选分类').shape! as RoundedRectangleBorder).side;
          final colors = Theme.of(tester.element(heading)).colorScheme;
          expect(border.color, colors.outline);
          expect(border.width, 1.5);
          expect(
            (cell('已选分类').shape! as RoundedRectangleBorder).side,
            BorderSide.none,
          );
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('未选分类'));
          await tester.pumpAndSettle();
          expect(result, 2);
          expect(heading, findsNothing);
          if (form == FormFactor.phone) {
            await tester.tap(find.text('展开'));
            await tester.pumpAndSettle();
            await tester.tap(find.byTooltip('关闭'));
            await tester.pumpAndSettle();
            expect(heading, findsNothing);
            expect(result, isNull);
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
