import 'package:duanju_app/ui/player/playback_seek_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('拖动仅重建局部进度和气泡，不重建页面或视频区域', (tester) async {
    final seek = PlaybackSeekController();
    var pageBuilds = 0;
    var videoBuilds = 0;
    var progressBuilds = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            pageBuilds++;
            return Column(
              children: [
                Builder(
                  builder: (context) {
                    videoBuilds++;
                    return const SizedBox(height: 100);
                  },
                ),
                ListenableBuilder(
                  listenable: seek,
                  builder: (context, _) {
                    progressBuilds++;
                    return Text('${seek.value.milliseconds}');
                  },
                ),
                ListenableBuilder(
                  listenable: seek,
                  builder: (context, _) =>
                      Text(seek.value.dragging ? 'dragging' : 'idle'),
                ),
              ],
            );
          },
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      if (i == 0) seek.start(0);
      seek.update(i * 1000.0);
      await tester.pump();
    }
    expect(pageBuilds, 1);
    expect(videoBuilds, 1);
    expect(progressBuilds, greaterThan(10));
    expect(find.text('dragging'), findsOneWidget);
    seek.finish(19000);
    await tester.pump();
    expect(find.text('idle'), findsOneWidget);
    expect(seek.value.milliseconds, 19000);
    seek.acceptPosition(const Duration(seconds: 19));
    await tester.pump();
    expect(seek.value.milliseconds, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    seek.dispose();
  });

  testWidgets('松手后等待目标回报，超时恢复实际进度', (tester) async {
    final seek = PlaybackSeekController();
    seek.start(10000);
    seek.finish(20000);
    seek.acceptPosition(const Duration(seconds: 2));
    expect(seek.value.milliseconds, 20000);
    await tester.pump(const Duration(seconds: 2));
    expect(seek.value.milliseconds, isNull);
    seek.dispose();
  });

  testWidgets('新拖动取消旧超时和目标，切集重置不留旧进度', (tester) async {
    final seek = PlaybackSeekController();
    seek.start(10000);
    seek.finish(20000);
    await tester.pump(const Duration(seconds: 1));
    seek.start(30000);
    seek.acceptPosition(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 2));
    expect(seek.value, (dragging: true, milliseconds: 30000.0));
    seek.reset();
    expect(seek.value, (dragging: false, milliseconds: null));
    seek.update(40000);
    expect(seek.value.milliseconds, isNull);
    seek.dispose();
  });

  testWidgets('销毁取消待回退计时器', (tester) async {
    final seek = PlaybackSeekController();
    seek.start(10000);
    seek.finish(20000);
    seek.dispose();
    await tester.pump(const Duration(seconds: 3));
    expect(tester.takeException(), isNull);
  });
}
