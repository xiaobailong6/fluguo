import 'dart:ui' show PointerDeviceKind;

import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theme/glass_style.dart';
import 'package:duanju_app/ui/widgets/glass/glass_feedback.dart';
import 'package:duanju_app/ui/widgets/glass/glass_selection_track.dart';
import 'package:duanju_app/ui/widgets/glass/glass_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('胶囊连续移动、快速反向与点击即时响应 $direction', (tester) async {
      var selected = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Center(
              child: SizedBox(
                width: 300,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    return GlassSelectionTrack(
                      context: context,
                      selectedIndex: selected,
                      height: 48,
                      children: [
                        for (var i = 0; i < 3; i++)
                          TextButton(
                            onPressed: () => setState(() => selected = i),
                            child: Text('tab$i'),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final indicator = find.byKey(const ValueKey('liquid-nav-indicator'));
      final start = tester.getRect(indicator);
      await tester.tap(find.text('tab2'));
      expect(selected, 2);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final midway = tester.getRect(indicator);
      expect((midway.left - start.left).abs(), greaterThan(1));
      expect((midway.left - start.left).abs(), lessThan(201));
      update(() => selected = 1);
      await tester.pump();
      expect(tester.getRect(indicator).left, closeTo(midway.left, 8));
      await tester.pumpAndSettle();
      expect(
        tester.getRect(indicator).center.dx,
        closeTo(tester.getCenter(find.text('tab1')).dx, .5),
      );
      expect(tester.getSize(indicator).width, 100);
      expect(indicator, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final media in [
    const MediaQueryData(disableAnimations: true),
    const MediaQueryData(accessibleNavigation: true),
  ]) {
    testWidgets('减少动态效果时胶囊立即到位且按压不缩放 $media', (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: media,
            child: Center(
              child: SizedBox(
                width: 300,
                child: StatefulBuilder(
                  builder: (context, setState) => GlassSelectionTrack(
                    context: context,
                    selectedIndex: selected,
                    height: 48,
                    children: [
                      for (var i = 0; i < 3; i++)
                        GlassFeedback(
                          child: TextButton(
                            onPressed: () => setState(() => selected = i),
                            child: Text('tab$i'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('tab2'));
      await tester.pump();
      final indicator = find.byKey(const ValueKey('liquid-nav-indicator'));
      expect(
        tester.getRect(indicator).center.dx,
        tester.getCenter(find.text('tab2')).dx,
      );
      expect(tester.getSize(indicator).width, 100);
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('tab1')),
      );
      await tester.pump();
      for (final scale in tester.widgetList<AnimatedScale>(
        find.byType(AnimatedScale),
      )) {
        expect(scale.scale, 1);
        expect(scale.duration, Duration.zero);
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('反馈保留点击、滚动、取消和禁用行为，悬停不缩放且子树不重建', (tester) async {
    var taps = 0;
    var childBuilds = 0;
    final scroll = ScrollController();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          height: 200,
          child: ListView(
            controller: scroll,
            children: [
              GlassFeedback(
                child: Builder(
                  builder: (context) {
                    childBuilds++;
                    return TextButton(
                      onPressed: () => taps++,
                      child: const Text('action'),
                    );
                  },
                ),
              ),
              const SizedBox(height: 1500),
            ],
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('action')),
    );
    await tester.pump(const Duration(milliseconds: 110));
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, .98);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(taps, 0);
    await tester.tap(find.text('action'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.text('action')));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    expect(childBuilds, 1);
    await mouse.removePointer();
    await tester.drag(find.byType(ListView), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0));
    expect(taps, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: GlassFeedback(
          enabled: false,
          child: TextButton(onPressed: null, child: const Text('disabled')),
        ),
      ),
    );
    final disabled = await tester.startGesture(
      tester.getCenter(find.text('disabled')),
    );
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale, 1);
    await disabled.up();
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('玻璃用途分层和播放器零模糊 $brightness', (tester) async {
      late GlassStyle chrome, panel, surface, playback;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.orange,
              brightness: brightness,
            ),
          ),
          home: AppScope(
            repository: FakeRepository(),
            formFactor: FormFactor.phone,
            child: Builder(
              builder: (context) {
                surface = GlassStyleResolver.of(context);
                chrome = GlassStyleResolver.of(context, role: GlassRole.chrome);
                panel = GlassStyleResolver.of(context, role: GlassRole.panel);
                playback = GlassStyleResolver.of(
                  context,
                  role: GlassRole.playback,
                );
                return const Center(
                  child: SizedBox(
                    width: 200,
                    height: 60,
                    child: GlassSurface(
                      role: GlassRole.playback,
                      child: Text('player'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      expect(chrome.sheen.a, lessThan(surface.sheen.a));
      expect(panel.tint.a, greaterThan(chrome.tint.a));
      expect(
        chrome.shadow.first.blurRadius,
        lessThan(panel.shadow.first.blurRadius),
      );
      expect(playback.blurSigma, 0);
      expect(playback.filter, isNull);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(AppMotion.enter, const Duration(milliseconds: 480));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('菜单显隐改变数量时胶囊保持有效范围，单菜单不越界', (tester) async {
    var count = 5;
    var selected = 4;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return GlassSelectionTrack(
                  context: context,
                  selectedIndex: selected,
                  height: 48,
                  children: [for (var i = 0; i < count; i++) Text('menu$i')],
                );
              },
            ),
          ),
        ),
      ),
    );
    update(() {
      count = 1;
      selected = 0;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final indicator = find.byKey(const ValueKey('liquid-nav-indicator'));
    expect(tester.getSize(indicator).width, 300);
    await tester.pumpAndSettle();
    expect(indicator, findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
