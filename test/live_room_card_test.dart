import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/live/live_room_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _room = LiveRoom(
  roomId: '1',
  title: '直播标题',
  anchor: '主播',
  cover: '',
  area: '游戏',
  online: '',
);

void main() {
  for (final width in [240.0, 390.0, 1024.0]) {
    for (final scale in [1.0, 2.0, 3.0]) {
      testWidgets('直播网格适配宽度 $width 和字号 $scale', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => GridView.builder(
                  padding: const EdgeInsets.all(16),
                  gridDelegate: LiveRoomCard.gridDelegate(context),
                  itemCount: 1,
                  itemBuilder: (_, _) =>
                      LiveRoomCard(room: _room, onTap: () {}),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.byIcon(Icons.live_tv_rounded), findsOneWidget);
        final cover = tester.getSize(find.byType(ClipRRect));
        expect(cover.height, greaterThanOrEqualTo(cover.width * 9 / 16));
      });
    }
  }

  testWidgets('多选状态仍显示标题且点击可操作', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 190,
            child: LiveRoomCard(
              room: _room,
              selected: true,
              platformName: '测试平台',
              onTap: () => tapped = true,
            ),
          ),
        ),
      ),
    );
    expect(find.text('直播标题'), findsOneWidget);
    expect(find.text('测试平台'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    await tester.tap(find.text('直播标题'));
    expect(tapped, isTrue);
    expect(tester.takeException(), isNull);
  });
}
