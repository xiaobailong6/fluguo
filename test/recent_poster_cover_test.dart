import 'package:duanju_app/live_history.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/recent_history.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/live/live_room_cover.dart';
import 'package:duanju_app/ui/widgets/cover_image.dart';
import 'package:duanju_app/ui/widgets/recent_poster.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  for (final live in [true, false]) {
    testWidgets(live ? '直播历史封面不进入短剧解析器' : '短剧历史保留原封面加载路径', (tester) async {
      final store = await openStore();
      final entry = live
          ? RecentEntry.live(
              LiveHistoryEntry(
                platformId: 'bilibili',
                room: const LiveRoom(
                  roomId: '1',
                  title: '直播标题',
                  anchor: '主播',
                  cover: 'https://example.test/live.jpg',
                  area: '',
                  online: '',
                ),
                updatedAt: DateTime(2026),
              ),
            )
          : RecentEntry.drama(watching(drama('1')));
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppScope(
            repository: FakeRepository(),
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                height: 220,
                child: RecentPoster(store: store, entry: entry, width: 100),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(LiveRoomCover), live ? findsOneWidget : findsNothing);
      expect(find.byType(DramaCover), live ? findsNothing : findsOneWidget);
      if (live) expect(find.text('直播 · 哔哩哔哩'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
