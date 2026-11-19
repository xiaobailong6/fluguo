import 'dart:async';
import 'dart:convert';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app.dart';
import 'package:duanju_app/ui/widgets/category_tabs.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _HeldRecommendations extends FakeRepository {
  final pending = Completer<CatalogPage>();

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) => pending.future;
}

void main() {
  for (final resume in [true, false]) {
    testWidgets('电视短剧加载、空列表和切换到非空分类不卸载分类或抢焦点：续看=$resume', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 720);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final store = await openStore({
        if (resume)
          'history': jsonEncode([
            WatchEntry(
              drama: drama('上次看到这里'),
              episode: 2,
              position: 20,
              duration: 100,
              updatedAt: DateTime.now(),
            ),
          ]),
      });
      final repository = _HeldRecommendations();
      await tester.pumpWidget(
        DuanjuApp(store: store, repository: repository, television: true),
      );
      await tester.pump();
      await tester.pump();
      final tabs = find.byType(CategoryTabs<String>);
      final element = tester.element(tabs);
      FocusNode focusOf(String label) => Focus.of(
        tester.element(find.descendant(of: tabs, matching: find.text(label))),
      );
      final all = find.descendant(of: tabs, matching: find.text('全部'));
      void expectBar() {
        expect(tabs, findsOneWidget);
        expect(tester.element(tabs), same(element));
        expect(tester.getSemantics(all).label, contains('全部'));
        expect(tester.takeException(), isNull);
      }

      expectBar();
      expect(resume ? find.text('继续观看') : find.text('正在加载'), findsOneWidget);
      if (resume) {
        expect(
          find.byWidgetPredicate(
            (w) => w is LinearProgressIndicator && w.value == null,
          ),
          findsOneWidget,
        );
      }
      // 从电视导航头向下进入分类，不直接给分类节点 requestFocus。
      tester
          .widget<InkWell>(find.byKey(const ValueKey('nav-explore')))
          .focusNode!
          .requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final labels = ['推荐', '全部', '真人剧'];
      final index = labels.indexWhere(
        (label) => focusOf(label).hasPrimaryFocus,
      );
      expect(index, isNot(-1));
      if (index != 1) {
        await tester.sendKeyEvent(
          index == 0
              ? LogicalKeyboardKey.arrowRight
              : LogicalKeyboardKey.arrowLeft,
        );
        await tester.pump();
      }
      final node = focusOf('全部');
      expect(node.hasPrimaryFocus, isTrue);

      repository.pending.complete(CatalogPage([]));
      await tester.pumpAndSettle();
      expectBar();
      expect(resume ? find.text('已经到底了') : find.text('这里还没有剧'), findsOneWidget);
      if (resume) expect(find.text('继续观看'), findsOneWidget);
      expect(focusOf('全部'), same(node));
      expect(node.hasPrimaryFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(repository.catalogRequests, isNotEmpty);
      expect(find.byType(DramaTile), findsOneWidget);
      expectBar();
      expect(focusOf('全部'), same(node));
      expect(node.hasPrimaryFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
