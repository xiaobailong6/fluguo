import 'package:duanju_app/live_history.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/history/history_page.dart';
import 'package:duanju_app/ui/mine/mine_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/widgets/recent_poster.dart';
import 'package:duanju_app/ui/widgets/group_card.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const room = LiveRoom(
  roomId: '123',
  title: '直播测试房间',
  anchor: '测试主播',
  cover: '',
  area: '',
  online: '',
);

void main() {
  for (final form in FormFactor.values) {
    testWidgets('混合历史类型、平台标记/筛选及选择删除：${form.name}', (tester) async {
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(390, 844)
          : const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      await store.saveWatch(
        watching(drama('123', title: '短剧测试', episodes: 10), episode: 7),
      );
      await store.recordLiveWatch(
        'bilibili',
        room,
        profileEpoch: store.profileEpoch,
      );
      LiveHistoryEntry? opened;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: FakeRepository(),
            formFactor: form,
            child: child!,
          ),
          home: HistoryPage(
            store: store,
            onOpenLive: (entry) => opened = entry,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('短剧测试'), findsOneWidget);
      expect(find.text('直播测试房间'), findsOneWidget);
      final tags = tester
          .widgetList<ProgressPoster>(find.byType(ProgressPoster))
          .map((poster) => poster.tag)
          .toList();
      expect(tags.any((tag) => tag!.startsWith('短剧 · ')), isTrue);
      expect(tags.any((tag) => tag!.startsWith('直播 · ')), isTrue);
      expect(
        find.byWidgetPredicate(
          (widget) => widget is RecentPoster && widget.entry.live != null,
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('history-kind-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直播').last);
      await tester.pumpAndSettle();
      expect(find.text('短剧测试'), findsNothing);
      await tester.tap(find.text('直播测试房间'));
      await tester.pumpAndSettle();
      expect(opened?.key, 'bilibili:123');
      await tester.tap(find.text('编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除').last);
      await tester.pumpAndSettle();
      expect(store.liveHistory, isEmpty);
      expect(store.history.single.episode, 7);
      await tester.tap(find.byKey(const ValueKey('history-kind-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('短剧').last);
      await tester.pumpAndSettle();
      expect(find.text('短剧测试'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();
      expect(store.history, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('我的移除用户管理卡，融合最近观看并保留设置：${form.name}', (tester) async {
      tester.view.physicalSize = form == FormFactor.phone
          ? const Size(390, 844)
          : const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      await store.saveWatch(watching(drama('123', title: '短剧测试')));
      await store.recordLiveWatch(
        'bilibili',
        room,
        profileEpoch: store.profileEpoch,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: FakeRepository(),
            formFactor: form,
            child: child!,
          ),
          home: AppShell(store: store),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-mine')));
      await tester.pumpAndSettle();
      expect(find.byType(MinePage), findsOneWidget);
      expect(find.text('管理员'), findsNothing);
      expect(find.textContaining('切换用户'), findsNothing);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('短剧测试'), findsOneWidget);
      expect(find.text('直播测试房间'), findsOneWidget);
      expect(find.byType(RecentPoster), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      final allHistory = form == FormFactor.television
          ? find.text('全部')
          : find.descendant(
              of: find.ancestor(
                of: find.text('最近观看'),
                matching: find.byType(SectionHeader),
              ),
              matching: find.text('全部'),
            );
      await tester.tap(allHistory);
      await tester.pumpAndSettle();
      expect(find.byType(HistoryPage), findsOneWidget);
      final historyState = tester.state(find.byType(HistoryPage));
      final historyContext = tester.element(find.byType(HistoryPage));
      await tester.tap(find.byKey(const ValueKey('history-kind-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('直播').last);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('history-source-live:bilibili')),
      );
      await tester.pumpAndSettle();
      final originRoute = ModalRoute.of(historyContext)!;
      final originNavigator = Navigator.of(historyContext);
      await tester.tap(find.text('直播测试房间'));
      // 在原生播放器挂载前检查真实push，避免测试初始化媒体后端。
      expect(originRoute.isCurrent, isFalse);
      expect(find.byType(HistoryPage), findsOneWidget);
      originNavigator.pop();
      await tester.pumpAndSettle();
      expect(originRoute.isCurrent, isTrue);
      expect(
        identical(historyState, tester.state(find.byType(HistoryPage))),
        isTrue,
      );
      expect(find.byType(MinePage, skipOffstage: false), findsOneWidget);
      expect(find.text('短剧测试'), findsNothing);
      expect(find.text('直播平台'), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('history-source-live:bilibili')),
            )
            .selected,
        isTrue,
      );
      originNavigator.pop();
      await tester.pumpAndSettle();
      final mineContext = tester.element(find.byType(MinePage));
      final mineRoute = ModalRoute.of(mineContext)!;
      final mineNavigator = Navigator.of(mineContext);
      await tester.tap(find.text('直播测试房间'));
      expect(mineRoute.isCurrent, isFalse);
      mineNavigator.pop();
      await tester.pumpAndSettle();
      expect(mineRoute.isCurrent, isTrue);
      expect(find.byType(MinePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
