import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [89.0, 110.0, 160.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('海报同排徽标与百分比 ${width}px $scale倍字体', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: AppScope(
            repository: FakeRepository(),
            formFactor: FormFactor.phone,
            child: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Center(
                  child: ProgressPoster(
                    drama: drama('poster'),
                    cover: const ColoredBox(color: Colors.black),
                    width: width,
                    tag: '红果',
                    status: '合并中',
                    inlineStatus: true,
                    progress: .99,
                    progressLabel: '99%',
                    caption: '第 1-80 集',
                    showMenuButton: false,
                    onTap: () {},
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pump();
        final source = tester.getRect(find.text('红果'));
        final state = tester.getRect(find.text('合并中'));
        expect(source.center.dy, closeTo(state.center.dy, 1));
        expect(source.width, greaterThan(8));
        expect(state.width, greaterThan(12));
        expect(state.left, greaterThan(source.right));
        final percent = tester.widget<Text>(find.text('99%'));
        expect(percent.overflow, isNot(TextOverflow.ellipsis));
        expect(percent.style!.fontSize, 20);
        expect(tester.getRect(find.text('99%')).width, greaterThan(20));
        expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
