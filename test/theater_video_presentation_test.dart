import 'package:duanju_app/theater_video_presentation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

class _SurfaceProbe extends StatefulWidget {
  const _SurfaceProbe({required this.ratio});
  final double? ratio;
  @override
  State<_SurfaceProbe> createState() => _SurfaceProbeState();
}

class _SurfaceProbeState extends State<_SurfaceProbe> {
  @override
  Widget build(BuildContext context) => Center(
    child: AspectRatio(
      aspectRatio: widget.ratio ?? 1,
      child: const ColoredBox(key: ValueKey('fake-texture'), color: Colors.red),
    ),
  );
}

void main() {
  test('成对显示尺寸、旋转与非方形像素，不使用单独宽高或未校正原始尺寸', () {
    expect(previewDisplaySize(const VideoParams(w: 1920, h: 1080)), isNull);
    expect(previewDisplaySize(const VideoParams(dw: 1920)), isNull);
    expect(previewDisplaySize(const VideoParams(dw: 1920, dh: 0)), isNull);
    expect(previewDisplaySize(const VideoParams(dw: 1, dh: 1)), isNull);
    expect(
      previewDisplaySize(const VideoParams(w: 720, h: 576, dw: 1024, dh: 576)),
      const Size(1024, 576),
    );
    for (final rotation in [0, 180, 360]) {
      expect(
        previewDisplaySize(VideoParams(dw: 1920, dh: 1080, rotate: rotation)),
        const Size(1920, 1080),
      );
    }
    for (final rotation in [90, 270, -90]) {
      expect(
        previewDisplaySize(VideoParams(dw: 1920, dh: 1080, rotate: rotation)),
        const Size(1080, 1920),
      );
    }
  });

  test('open完成、成对尺寸、纹理ID和正确比例全部就绪才允许显画', () {
    final presentation = TheaterVideoPresentation();
    addTearDown(presentation.dispose);
    presentation.begin();
    presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    presentation.textureChanged(const Rect.fromLTWH(0, 0, 1920, 1080), 2);
    expect(presentation.value.ready, isFalse);
    presentation.opened();
    expect(presentation.value.ready, isTrue);
    for (final size in [
      const Size(1, 1),
      const Size(1080, 1920),
      const Size(double.nan, 1080),
    ]) {
      presentation.textureChanged(Offset.zero & size, 2);
      expect(presentation.value.ready, isFalse);
    }
    presentation.textureChanged(const Rect.fromLTWH(0, 0, 960, 540), null);
    expect(presentation.value.ready, isFalse);
    presentation.textureChanged(const Rect.fromLTWH(0, 0, 960, 540), 2);
    expect(presentation.value.ready, isTrue);
  });

  for (final size in [const Size(1920, 1080), const Size(1080, 1920)]) {
    for (final textureFirst in [false, true]) {
      testWidgets('首个可见画面就按正确比例 $size textureFirst=$textureFirst', (
        tester,
      ) async {
        final presentation = TheaterVideoPresentation();
        final cover = find.byKey(const ValueKey('preview-frame-cover'));
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox.expand(
              child: StablePreviewSurface(
                presentation: presentation,
                videoBuilder: (ratio) => _SurfaceProbe(ratio: ratio),
              ),
            ),
          ),
        );
        final surface = tester.state(find.byType(_SurfaceProbe));
        expect(cover, findsOneWidget);
        presentation.begin();
        presentation.opened();
        if (textureFirst) {
          presentation.textureChanged(Offset.zero & size, 7);
        } else {
          presentation.parametersChanged(
            VideoParams(dw: size.width.toInt(), dh: size.height.toInt()),
          );
          presentation.textureChanged(const Rect.fromLTWH(0, 0, 1, 1), 7);
        }
        await tester.pump();
        expect(cover, findsOneWidget);
        expect(tester.state(find.byType(_SurfaceProbe)), same(surface));
        if (textureFirst) {
          presentation.parametersChanged(
            VideoParams(dw: size.width.toInt(), dh: size.height.toInt()),
          );
        } else {
          presentation.textureChanged(Offset.zero & size, 7);
        }
        await tester.pump();
        // 正确比例先完成一帧布局，下一帧才撤罩，不卸载/重建原生表面。
        expect(cover, findsOneWidget);
        await tester.pump();
        expect(cover, findsNothing);
        final rect = tester.getRect(find.byKey(const ValueKey('fake-texture')));
        expect(
          rect.width / rect.height,
          closeTo(size.width / size.height, .0001),
        );
        expect(tester.state(find.byType(_SurfaceProbe)), same(surface));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        presentation.dispose();
      });
    }
  }

  testWidgets('横竖互切和停止使旧显画任务失效，复用表面但不闪旧比例', (tester) async {
    final presentation = TheaterVideoPresentation();
    final cover = find.byKey(const ValueKey('preview-frame-cover'));
    await tester.pumpWidget(
      MaterialApp(
        home: StablePreviewSurface(
          presentation: presentation,
          videoBuilder: (ratio) => _SurfaceProbe(ratio: ratio),
        ),
      ),
    );
    final surface = tester.state(find.byType(_SurfaceProbe));
    for (final size in [
      const Size(1920, 1080),
      const Size(1080, 1920),
      const Size(1920, 1080),
    ]) {
      presentation.begin();
      presentation.parametersChanged(
        VideoParams(dw: size.width.toInt(), dh: size.height.toInt()),
      );
      presentation.opened();
      await tester.pump();
      expect(cover, findsOneWidget);
      presentation.textureChanged(Offset.zero & size, 1);
      await tester.pump();
      expect(cover, findsOneWidget);
      await tester.pump();
      expect(cover, findsNothing);
      expect(tester.state(find.byType(_SurfaceProbe)), same(surface));
    }
    presentation.begin();
    presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    presentation.opened();
    await tester.pump();
    presentation.stop();
    await tester.pump();
    expect(cover, findsOneWidget);
    presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    presentation.opened();
    await tester.pump();
    expect(cover, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    presentation.dispose();
    expect(tester.takeException(), isNull);
  });

  test('相同视频参数/纹理不重复通知，无进度级重建', () {
    final presentation = TheaterVideoPresentation();
    addTearDown(presentation.dispose);
    presentation.begin();
    presentation.opened();
    presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    presentation.textureChanged(const Rect.fromLTWH(0, 0, 1920, 1080), 1);
    var changes = 0;
    presentation.addListener(() => changes++);
    for (var i = 0; i < 100; i++) {
      presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
      presentation.textureChanged(const Rect.fromLTWH(0, 0, 1920, 1080), 1);
    }
    expect(changes, 0);
  });

  testWidgets('未完成的显画回调在销毁或更换呈现源后不作用新页面', (tester) async {
    final first = TheaterVideoPresentation();
    final second = TheaterVideoPresentation();
    await tester.pumpWidget(
      MaterialApp(
        home: StablePreviewSurface(
          presentation: first,
          videoBuilder: (ratio) => _SurfaceProbe(ratio: ratio),
        ),
      ),
    );
    first.begin();
    first.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    first.textureChanged(const Rect.fromLTWH(0, 0, 1920, 1080), 2);
    first.opened();
    await tester.pumpWidget(
      MaterialApp(
        home: StablePreviewSurface(
          presentation: second,
          videoBuilder: (ratio) => _SurfaceProbe(ratio: ratio),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('preview-frame-cover')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    first.dispose();
    second.dispose();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('改变屏幕约束仍等比留黑且不重新挂载视频表面', (tester) async {
    final presentation = TheaterVideoPresentation();
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: StablePreviewSurface(
          presentation: presentation,
          videoBuilder: (ratio) => _SurfaceProbe(ratio: ratio),
        ),
      ),
    );
    final surface = tester.state(find.byType(_SurfaceProbe));
    presentation.begin();
    presentation.parametersChanged(const VideoParams(dw: 1920, dh: 1080));
    presentation.textureChanged(const Rect.fromLTWH(0, 0, 1920, 1080), 4);
    presentation.opened();
    for (final screen in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(280, 600),
    ]) {
      tester.view.physicalSize = screen;
      await tester.pump();
      await tester.pump();
      final rect = tester.getRect(find.byKey(const ValueKey('fake-texture')));
      expect(rect.width / rect.height, closeTo(16 / 9, .0001));
      expect(rect.width, lessThanOrEqualTo(screen.width));
      expect(rect.height, lessThanOrEqualTo(screen.height));
      expect(find.byKey(const ValueKey('preview-frame-cover')), findsNothing);
      expect(tester.state(find.byType(_SurfaceProbe)), same(surface));
    }
    await tester.pumpWidget(const SizedBox.shrink());
    presentation.dispose();
    expect(tester.takeException(), isNull);
  });
}
