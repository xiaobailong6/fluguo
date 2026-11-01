import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/ui/app.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/follow/follow_page.dart';
import 'package:duanju_app/ui/live/live_page.dart';
import 'package:duanju_app/ui/mine/mine_page.dart';
import 'package:duanju_app/ui/shell/app_shell.dart';
import 'package:duanju_app/ui/users/unlock_page.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:duanju_app/ui/widgets/glass/glass_header.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

Future<void> mountShell(
  WidgetTester tester,
  LocalStore store, {
  FormFactor form = FormFactor.phone,
  bool reduceMotion = false,
}) async {
  await tester.binding.setSurfaceSize(
    form == FormFactor.window ? const Size(1100, 844) : const Size(390, 844),
  );
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final repository = FakeRepository()
    ..recommended = List.generate(80, (index) => drama('$index'));
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: AppScope(
          repository: repository,
          formFactor: form,
          child: child!,
        ),
      ),
      home: AppShell(store: store),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Tab按需创建，切出后暂停动画，返回保留实例和滚动位置', (tester) async {
    final store = await openStore();
    await mountShell(tester, store);
    expect(find.byType(LivePage, skipOffstage: false), findsNothing);
    expect(find.byType(FollowPage, skipOffstage: false), findsNothing);
    expect(find.byType(MinePage, skipOffstage: false), findsNothing);
    final explore = tester.state(find.byType(ExplorePage));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(150);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pumpAndSettle();
    expect(find.byType(FollowPage), findsOneWidget);
    expect(
      TickerMode.valuesOf(tester.element(find.byType(FollowPage))).enabled,
      isTrue,
    );
    expect(
      TickerMode.valuesOf(
        tester.element(find.byType(ExplorePage, skipOffstage: false)),
      ).enabled,
      isFalse,
    );
    final follow = tester.state(find.byType(FollowPage));
    await tester.tap(find.byKey(const ValueKey('nav-explore')));
    await tester.pumpAndSettle();
    expect(identical(explore, tester.state(find.byType(ExplorePage))), isTrue);
    expect(scroll.offset, 150);
    await tester.tap(find.byKey(const ValueKey('nav-follow')));
    await tester.pumpAndSettle();
    expect(identical(follow, tester.state(find.byType(FollowPage))), isTrue);
    expect(find.byType(LivePage, skipOffstage: false), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('顶栏滚动显隐不重新创建海报网格', (tester) async {
    final store = await openStore();
    await mountShell(tester, store);
    final grid = tester.widget<DramaSliverGrid>(find.byType(DramaSliverGrid));
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    scroll.jumpTo(180);
    await tester.pumpAndSettle();
    expect(
      identical(
        grid,
        tester.widget<DramaSliverGrid>(find.byType(DramaSliverGrid)),
      ),
      isTrue,
    );
    final header = find.byType(GlassHeader);
    final slide = tester.widget<AnimatedSlide>(
      find.ancestor(of: header, matching: find.byType(AnimatedSlide)).first,
    );
    expect(slide.offset, const Offset(0, -1.15));
    scroll.jumpTo(80);
    await tester.pumpAndSettle();
    expect(
      identical(
        grid,
        tester.widget<DramaSliverGrid>(find.byType(DramaSliverGrid)),
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面侧栏不生成整高模糊，减少动画设置用于顶底栏', (tester) async {
    final store = await openStore();
    await mountShell(
      tester,
      store,
      form: FormFactor.window,
      reduceMotion: true,
    );
    final side = find
        .ancestor(
          of: find.byKey(const ValueKey('side-bar')),
          matching: find.byType(GlassSurface),
        )
        .first;
    expect(tester.widget<GlassSurface>(side).blur, isFalse);
    expect(
      find.descendant(of: side, matching: find.byType(BackdropFilter)),
      findsNothing,
    );
    final slide = tester.widget<AnimatedSlide>(
      find
          .ancestor(
            of: find.byType(GlassHeader),
            matching: find.byType(AnimatedSlide),
          )
          .first,
    );
    expect(slide.duration, Duration.zero);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('保存观看进度不重建MaterialApp，外观和锁定变化仍然生效', (tester) async {
    final store = await openStore();
    await tester.pumpWidget(
      DuanjuApp(repository: FakeRepository(), store: store),
    );
    await tester.pumpAndSettle();
    final initial = tester.widget<MaterialApp>(find.byType(MaterialApp));
    await store.saveWatch(watching(drama('watch'), position: 25));
    await tester.pumpAndSettle();
    expect(
      identical(initial, tester.widget<MaterialApp>(find.byType(MaterialApp))),
      isTrue,
    );
    expect(store.history.single.position, 25);
    await store.setThemeMode('dark');
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await store.setGlassEffects(false);
    await tester.pumpAndSettle();
    expect(AppScope.of(tester.element(find.byType(AppShell))).glass, isFalse);
    await tester.runAsync(
      () => store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      ),
    );
    store.lock();
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换store后解除旧监听并响应新设置', (tester) async {
    final oldStore = await openStore();
    final newStore = await openStore();
    final repository = FakeRepository();
    await tester.pumpWidget(DuanjuApp(repository: repository, store: oldStore));
    await tester.pumpAndSettle();
    await tester.pumpWidget(DuanjuApp(repository: repository, store: newStore));
    await tester.pumpAndSettle();
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    await oldStore.setGlassEffects(false);
    await tester.pumpAndSettle();
    expect(
      identical(app, tester.widget<MaterialApp>(find.byType(MaterialApp))),
      isTrue,
    );
    await newStore.setThemeMode('dark');
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
