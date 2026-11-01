import 'dart:ui' show PointerDeviceKind;

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/player/episode_grid.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<Episode> episodes(int start, int count) => [
  for (var i = 0; i < count; i++) Episode(const {}, start + i),
];

void main() {
  for (final width in [280.0, 320.0, 390.0, 800.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('选集三位数在宽$width 字号$scale下完整显示且可点击', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 640));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        var picked = -1;
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: EpisodeGrid(
                  episodes: episodes(100, 10),
                  current: 0,
                  selecting: false,
                  selected: <int>{},
                  onSelectionChanged: () {},
                  onPick: (index) => picked = index,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final grid = tester.widget<SliverFixedExtentList>(
          find.byType(SliverFixedExtentList),
        );
        expect(grid.itemExtent, greaterThanOrEqualTo(56));
        await tester.tap(find.text('100'));
        expect(picked, 0);
      });
    }
  }

  testWidgets('普通字号短集号保持五列，字号变化后重新定位当前集', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final items = episodes(1, 100);
    Future<void> mount(double scale, int current) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: EpisodeGrid(
                episodes: items,
                current: current,
                selecting: false,
                selected: <int>{},
                onSelectionChanged: () {},
                onPick: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await mount(1, 80);
    final before = tester.getRect(find.text('81'));
    expect(before.top, greaterThanOrEqualTo(0));
    expect(before.bottom, lessThanOrEqualTo(360));
    await mount(3, 80);
    expect(tester.takeException(), isNull);
    final after = tester.getRect(find.text('81'));
    expect(after.top, greaterThanOrEqualTo(0));
    expect(after.bottom, lessThanOrEqualTo(360));

    // 单位数集号的常规布局不因自适应而无谓减少列数。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EpisodeGrid(
            episodes: episodes(1, 9),
            current: 0,
            selecting: false,
            selected: <int>{},
            onSelectionChanged: () {},
            onPick: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('1')).dy,
      tester.getTopLeft(find.text('5')).dy,
    );
    expect(
      tester.getTopLeft(find.text('6')).dy,
      greaterThan(tester.getTopLeft(find.text('1')).dy),
    );
  });

  testWidgets('大字体拖选使用新行高和列数，跳过已下载集数', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final selected = <int>{};
    final items = episodes(100, 10);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => EpisodeGrid(
                episodes: items,
                current: 0,
                selecting: true,
                selected: selected,
                downloaded: const {1},
                onSelectionChanged: () => setState(() {}),
                onPick: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('100')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(tester.getCenter(find.text('102')));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, {0, 2});
    expect(tester.takeException(), isNull);
  });

  testWidgets('三倍字体VIP和下载角标不遮挡集号，显式最小宽度仍可自适应', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3)),
          child: Scaffold(
            body: EpisodeGrid(
              episodes: [
                Episode({'vip': true}, 100),
              ],
              current: 0,
              selecting: false,
              selected: <int>{},
              downloaded: const {0},
              minCellWidth: 48,
              onSelectionChanged: () {},
              onPick: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final number = tester.getRect(find.text('100'));
    final vip = tester.getRect(find.text('VIP'));
    final downloaded = tester.getRect(find.byIcon(Icons.check_rounded));
    expect(number.top, greaterThan(vip.bottom));
    expect(number.top, greaterThan(downloaded.bottom));
  });
}
