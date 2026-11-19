import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_hero.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final mode in ['normal', 'disable', 'accessible']) {
    testWidgets('首页大卡片采用B档时长且尊重减少动态效果 $mode', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final store = await openStore();
      final item = drama('hero-motion');
      WatchEntry entry(int episode) => WatchEntry(
        drama: item,
        episode: episode,
        position: 10,
        duration: 100,
        updatedAt: DateTime.now(),
      );
      await store.saveWatch(entry(1));
      final repository = FakeRepository();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: mode == 'disable',
              accessibleNavigation: mode == 'accessible',
            ),
            child: AppScope(
              repository: repository,
              formFactor: FormFactor.phone,
              child: child!,
            ),
          ),
          home: ExplorePage(store: store),
        ),
      );
      await tester.pumpAndSettle();
      final finder = find.byKey(const ValueKey('explore-hero-motion'));
      final switcher = tester.widget<AnimatedSwitcher>(finder);
      final reduced = mode != 'normal';
      expect(switcher.duration, reduced ? Duration.zero : AppMotion.heroEnter);
      expect(
        switcher.reverseDuration,
        reduced ? Duration.zero : AppMotion.heroExit,
      );
      final sizeFinder = find.ancestor(
        of: finder,
        matching: find.byType(AnimatedSize),
      );
      if (reduced) {
        // 减少动画采用最终尺寸，不创建会在布局中同步通知的零时长动画。
        expect(sizeFinder, findsNothing);
      } else {
        expect(
          tester.widget<AnimatedSize>(sizeFinder.first).duration,
          AppMotion.chrome,
        );
      }
      await store.saveWatch(entry(2));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final hero = find.descendant(
        of: finder,
        matching: find.byType(ExploreHero),
      );
      if (reduced) {
        expect(hero, findsOneWidget);
        // 只检查切换层，不把卡片内部按钮的零位移焦点反馈当成卡片动画。
        for (final type in [SlideTransition, ScaleTransition]) {
          final wrappers = find.ancestor(of: hero, matching: find.byType(type));
          expect(find.descendant(of: finder, matching: wrappers), findsNothing);
        }
      } else {
        expect(hero, findsNWidgets(2));
        final fades = tester.widgetList<FadeTransition>(
          find.descendant(of: finder, matching: find.byType(FadeTransition)),
        );
        expect(
          fades.any((fade) => fade.opacity.value > 0 && fade.opacity.value < 1),
          isTrue,
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('继续第 2 集'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
