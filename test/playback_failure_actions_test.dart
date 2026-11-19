import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/player/player_surface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _Repository extends FakeRepository {
  String? errorCode;
  bool fail = true;
  int resolves = 0;
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    resolves++;
    if (fail) throw AppFailure('测试失败', code: errorCode ?? '');
    return const PlaybackPlan(url: 'memory:retry');
  }
}

void main() {
  for (final kind in ['progress', 'zero', 'login', 'local']) {
    testWidgets('错误页从头播放入口与原操作并存 $kind', (tester) async {
      final store = await openStore();
      final repo = _Repository()
        ..errorCode = switch (kind) {
          'login' => 'source_login',
          'local' => 'local_media',
          _ => null,
        };
      final player = FakePlayer();
      final session = PlaybackSession(
        repository: repo,
        store: store,
        detail: dramaDetail(drama('retry'), count: 1),
        player: player,
        index: 0,
        position: kind == 'zero' ? 0 : 35,
      );
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlaybackFailure(session: session, error: session.error!),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final restart = find.text('从头播放');
      expect(
        restart,
        ['progress', 'local'].contains(kind) ? findsOneWidget : findsNothing,
      );
      expect(find.text(kind == 'local' ? '重试本地播放' : '重试'), findsOneWidget);
      if (kind == 'local') expect(find.text('改为在线播放'), findsOneWidget);
      if (kind == 'progress') {
        repo.fail = false;
        await tester.tap(restart);
        await tester.runAsync(() => pumpEventQueue());
        expect(player.opened.single.start, isNull);
        expect(session.currentPosition, 0);
        expect(player.state.playing, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      session.dispose();
      await tester.runAsync(() => pumpEventQueue());
      expect(tester.takeException(), isNull);
    });
  }
}
