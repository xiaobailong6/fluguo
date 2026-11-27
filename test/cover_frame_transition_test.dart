import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Repository extends FakeRepository {
  _Repository(this.path, {this.cacheHit = false});
  final String path;
  final bool cacheHit;
  @override
  bool coverCached(Drama drama) => cacheHit;
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => path;
}

void main() {
  for (final mode in [
    'normal',
    'reduceDuringFade',
    'cached',
    'reduced',
    'hidden',
    'scrolling',
  ]) {
    testWidgets('海报解码前保留占位，首帧显示策略 $mode', (tester) async {
      final path = 'cover-frame-$mode.png';
      final decoded = Completer<ImageInfo>();
      final provider = ResizeImage.resizeIfNeeded(
        192,
        null,
        FileImage(File(path)),
      );
      final key = await provider.obtainKey(ImageConfiguration.empty);
      tester.binding.imageCache.putIfAbsent(
        key,
        () => OneFrameImageStreamCompleter(decoded.future),
      );
      final repo = _Repository(path, cacheHit: mode == 'cached');
      final scroll = ScrollController();
      Widget frame({bool reduced = false}) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            devicePixelRatio: 1,
            disableAnimations: reduced || mode == 'reduced',
          ),
          child: TickerMode(
            enabled: mode != 'hidden',
            child: SingleChildScrollView(
              controller: scroll,
              physics: mode == 'scrolling' ? const _DeferPhysics() : null,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 150,
                  height: 240,
                  child: CoverImage(
                    repository: repo,
                    drama: drama(mode),
                    placeholder: const ColoredBox(
                      key: ValueKey('placeholder'),
                      color: Colors.grey,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(frame());
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
      expect(find.byType(RawImage), findsNothing);
      final size = tester.getSize(find.byType(CoverImage));
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(Colors.red, BlendMode.src);
      final picture = recorder.endRecording();
      decoded.complete(ImageInfo(image: picture.toImageSync(2, 3)));
      picture.dispose();
      await tester.pump();
      await tester.pump();
      final fade = find.descendant(
        of: find.byType(CoverImage),
        matching: find.byType(FadeTransition),
      );
      if (mode == 'normal' || mode == 'reduceDuringFade') {
        expect(fade, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 80));
        expect(
          tester.widget<FadeTransition>(fade).opacity.value,
          inExclusiveRange(0, 1),
        );
        expect(find.byKey(const ValueKey('placeholder')), findsOneWidget);
        if (mode == 'reduceDuringFade') {
          await tester.pumpWidget(frame(reduced: true));
        }
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('placeholder')), findsNothing);
      expect(fade, findsNothing);
      expect(tester.getSize(find.byType(CoverImage)), size);
      expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
      await tester.pumpWidget(frame());
      expect(fade, findsNothing);
      await tester.pumpWidget(const SizedBox());
      scroll.dispose();
      tester.binding.imageCache.evict(key);
      expect(tester.takeException(), isNull);
    });
  }
}

class _DeferPhysics extends ScrollPhysics {
  const _DeferPhysics({super.parent});
  @override
  _DeferPhysics applyTo(ScrollPhysics? ancestor) =>
      _DeferPhysics(parent: buildParent(ancestor));
  @override
  bool recommendDeferredLoading(
    double velocity,
    ScrollMetrics metrics,
    BuildContext context,
  ) => true;
}
