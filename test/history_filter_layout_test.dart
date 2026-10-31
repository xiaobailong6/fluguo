import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/recent_history.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/history/history_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final width in [320.0, 390.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('历史筛选层级适配宽度$width 字号$scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 1100));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final store = await openStore();
        await store.saveWatch(watching(drama('1', title: '短剧一')));
        await store.recordLiveWatch(
          'douyu',
          const LiveRoom(
            roomId: '1',
            title: '直播一',
            anchor: '主播',
            cover: '',
            area: '',
            online: '',
          ),
          profileEpoch: store.profileEpoch,
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: AppScope(
                repository: FakeRepository(),
                formFactor: width < 600 ? FormFactor.phone : FormFactor.window,
                child: child!,
              ),
            ),
            home: HistoryPage(store: store),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('内容类型'), findsOneWidget);
        expect(find.text('站源 / 平台'), findsOneWidget);
        expect(find.byType(DropdownButton<HistoryKind>), findsOneWidget);
        final selector = find.byKey(const ValueKey('history-kind-selector'));
        final sources = find.byKey(const ValueKey('history-source-filters'));
        if (width == 390 && scale == 1) {
          expect(
            tester.getRect(selector).right,
            lessThan(tester.getRect(sources).left),
          );
        } else if (width == 320 || scale == 2) {
          expect(
            tester.getRect(sources).top,
            greaterThan(tester.getRect(selector).bottom),
          );
        }
        await tester.tap(selector);
        await tester.pumpAndSettle();
        await tester.tap(find.text('直播').last);
        await tester.pumpAndSettle();
        expect(find.text('直播平台'), findsOneWidget);
        expect(find.text('短剧一'), findsNothing);
        expect(find.text('直播一'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
