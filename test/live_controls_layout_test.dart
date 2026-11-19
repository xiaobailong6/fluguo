import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/live/live_playback_controls.dart';
import 'package:duanju_app/ui/live/live_playback_header.dart';
import 'package:duanju_app/ui/live/live_favorite_button.dart';
import 'package:duanju_app/ui/player/player_stats_label.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'support/fake_player.dart';

void main() {
  testWidgets('320 宽直播顶栏按标题和主播画质的实际行高展开', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await openStore();
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(showClock: true),
    );
    final player = FakePlayer();
    addTearDown(player.dispose);
    const room = LiveRoom(
      roomId: '1',
      title: '直播测试房间',
      anchor: '测试主播',
      area: '',
      online: '',
      cover: '',
    );
    var backs = 0;
    var previous = 0.0;
    for (final scale in [1.0, 2.0, 3.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 640),
                textScaler: TextScaler.linear(scale),
              ),
              child: Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 4,
                    right: 12,
                    child: LivePlaybackHeader(
                      room: room,
                      quality: '原画',
                      onBack: () => backs++,
                      stats: PlayerStatsLabel(
                        store: store,
                        player: player,
                        compact: false,
                        cacheSpeed: false,
                      ),
                      favorite: LiveFavoriteButton(
                        store: store,
                        platformId: 'bilibili',
                        room: room,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      final bar = tester.getRect(find.byType(LivePlaybackHeader));
      final title = tester.getRect(find.text(room.title));
      final detail = tester.getRect(find.text('测试主播 · 原画'));
      if (scale == 1) expect(bar.height, 60);
      expect(bar.height, greaterThan(previous));
      previous = bar.height;
      expect(title.height, greaterThanOrEqualTo(16 * scale));
      expect(detail.height, greaterThanOrEqualTo(12 * scale));
      expect(detail.top, greaterThanOrEqualTo(title.bottom));
      expect(detail.bottom, lessThanOrEqualTo(bar.bottom));
      expect(title.width, greaterThan(16 * scale));
      expect(find.byType(LiveFavoriteButton).hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('返回'));
      expect(tester.takeException(), isNull);
    }
    expect(backs, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final full in [false, true]) {
    for (final width in [320.0, 1200.0]) {
      testWidgets('直播按钮贴右下且长画质无溢出 full=$full width=$width', (tester) async {
        tester.view.physicalSize = Size(width, 600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var lines = 0;
        var qualities = 0;
        for (final scale in [1.0, 2.0]) {
          for (final quality in ['原画', '超高清原画非常长的清晰度名称']) {
            await tester.pumpWidget(
              MaterialApp(
                home: Scaffold(
                  backgroundColor: Colors.black,
                  body: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 600),
                      textScaler: TextScaler.linear(scale),
                    ),
                    child: Stack(
                      children: [
                        Positioned(
                          left: 8,
                          right: 8,
                          bottom: 8,
                          child: LivePlaybackControls(
                            playing: true,
                            full: full,
                            middle: full ? null : const Text('0 KB/S'),
                            quality: quality,
                            showLine: true,
                            showMini: true,
                            onTogglePlayback: () {},
                            onLine: () => lines++,
                            onQuality: () => qualities++,
                            onMini: () {},
                            onFullscreen: () {},
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
            await tester.pump();
            final group = tester.getRect(
              find.byKey(const ValueKey('live-right-controls')),
            );
            final line = tester.getRect(
              find.byKey(const ValueKey('live-line-control')),
            );
            final qualityRect = tester.getRect(
              find.byKey(const ValueKey('live-quality-control')),
            );
            final mini = tester.getRect(
              find.byKey(const ValueKey('live-mini-control')),
            );
            final fullButton = tester.getRect(
              find.byKey(const ValueKey('live-fullscreen-control')),
            );
            expect(group.right, closeTo(width - 8, .01));
            expect(fullButton.right, closeTo(width - 8, .01));
            expect(group.bottom, closeTo(592, .01));
            expect(fullButton.center.dy, closeTo(group.center.dy, .01));
            expect(mini.left - qualityRect.right, lessThanOrEqualTo(1));
            expect(qualityRect.left - line.right, lessThanOrEqualTo(1));
            if (width > 600 && quality == '原画') {
              expect(line.left, greaterThan(width * .65));
            }
            expect(tester.takeException(), isNull);
            await tester.tap(find.byKey(const ValueKey('live-line-control')));
            await tester.tap(
              find.byKey(const ValueKey('live-quality-control')),
            );
          }
        }
        expect(lines, 4);
        expect(qualities, 4);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
