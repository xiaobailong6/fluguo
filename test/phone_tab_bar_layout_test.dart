import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('真实手机底栏：标签、选中轨道、页面占位、回顶随字号变化 width=$width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 640);
      tester.view.padding = const FakeViewPadding(bottom: 20);
      tester.view.viewPadding = const FakeViewPadding(bottom: 20);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final store = await openStore();
      final repository = FakeRepository()
        ..recommended = List.generate(22, (i) => drama('$i'));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: AppScope(
              repository: repository,
              formFactor: FormFactor.phone,
              child: child!,
            ),
          ),
          home: AppShell(store: store),
        ),
      );
      final bar = find.byKey(const ValueKey('bottom-chrome-motion'));
      final indicator = find.byKey(const ValueKey('liquid-nav-indicator'));
      final back = find.byKey(const ValueKey('shell-back-to-top'));
      var previousHeight = 0.0;
      for (final scale in [1.0, 2.0, 3.0]) {
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpAndSettle();
        final barRect = tester.getRect(bar);
        expect(barRect.bottom, 610); // 安全区 20 + 底边距 10，各扣一次。
        expect(barRect.left, 16);
        if (scale == 1) expect(barRect.height, 64);
        expect(barRect.height, greaterThan(previousHeight));
        previousHeight = barRect.height;
        for (final tab in AppTab.values) {
          final button = find.byKey(ValueKey('nav-${tab.name}'));
          final label = find.descendant(
            of: button,
            matching: find.text(tab.label),
          );
          final rect = tester.getRect(button);
          expect(button.hitTestable(), findsOneWidget);
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(52));
          expect(tester.getSize(indicator).height, rect.height);
          final rich = find.descendant(
            of: label,
            matching: find.byType(RichText),
          );
          final paragraph = tester.renderObject<RenderParagraph>(rich);
          expect(paragraph.textScaler.scale(10), closeTo(10 * scale, .001));
          expect(paragraph.didExceedMaxLines, isFalse, reason: tab.label);
          expect(
            tester.getBottomLeft(label).dy,
            lessThanOrEqualTo(rect.bottom),
          );
          expect(
            tester.getSemantics(label),
            isSemantics(
              label: tab.label,
              hasTapAction: true,
              isSelected: tab == AppTab.explore,
            ),
          );
        }
        final scroll = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        scroll.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('nav-explore')).hitTestable(),
          findsNothing,
        );
        final footer = find.byType(FeedFooter);
        final bottom = scroll.position.maxScrollExtent;
        scroll.jumpTo(bottom - 14); // 反向滚动展开；仍可看到最后一行。
        await tester.pumpAndSettle();
        expect(tester.getBottomLeft(footer).dy, lessThanOrEqualTo(barRect.top));
        expect(tester.getBottomLeft(back).dy, closeTo(barRect.top - 12, .01));
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(scroll.offset, 0);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('nav-follow')));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(indicator),
        tester.getRect(find.byKey(const ValueKey('nav-follow'))),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
