import 'dart:async';
import 'dart:io';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/widgets/cover_backdrop.dart';
import 'package:duanju_app/ui/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _TrackingCache extends ImageCache {
  final evicted = <Object>[];
  @override
  bool evict(Object key, {bool includeLive = true}) {
    evicted.add(key);
    return super.evict(key, includeLive: includeLive);
  }
}

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ImageCache createImageCache() => _TrackingCache();
}

class _Repository extends FakeRepository {
  final forced = <String>[];
  final retry = Completer<String>();
  final path = 'cover-decode-size-nonexistent.png';
  @override
  bool coverCached(Drama drama) => true;
  @override
  Future<String> cover(Drama drama, {bool force = false}) {
    if (force) {
      forced.add(drama.id);
      return retry.future;
    }
    return Future.value(path);
  }
}

void main() {
  final binding = _Binding();

  test('解码按物理宽度向上选有限档位，并对无界/异常布局安全回退', () {
    expect(coverDecodeTiers, [128, 192, 256, 384, 512, 768, 1024]);
    for (final tier in coverDecodeTiers) {
      expect(coverDecodeWidth(tier.toDouble(), 1), tier);
      expect(coverDecodeWidth(tier / 2, 2), tier);
    }
    expect(coverDecodeWidth(70, 1), 128);
    expect(coverDecodeWidth(70, 3), 256);
    expect(coverDecodeWidth(150, 3), 512);
    expect(coverDecodeWidth(151, 3), 512);
    expect(coverDecodeWidth(400, 2), 1024);
    expect(coverDecodeWidth(2000, 4), 1024);
    expect(coverDecodeWidth(double.infinity, 2), 512);
    expect(coverDecodeWidth(double.nan, 2), 512);
    expect(coverDecodeWidth(0, 2), 512);
    expect(coverDecodeWidth(100, 0), 512);
    expect(coverDecodeWidth(2000, 4, lowResolution: true), 128);
  });

  testWidgets('真实布局和DPR决定ResizeImage键，重试清除同路径已用过的所有档位', (tester) async {
    final repository = _Repository();
    final item = drama('decode');
    Future<void> show(
      double width,
      double dpr, {
      bool lowResolution = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: dpr),
            child: Center(
              child: SizedBox(
                width: width,
                height: 300,
                child: CoverImage(
                  drama: item,
                  repository: repository,
                  placeholder: const SizedBox.expand(),
                  lowResolution: lowResolution,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(100, 1);
    expect(
      (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width,
      128,
    );
    await show(200, 2);
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as ResizeImage).width, 512);
    final failure =
        image.errorBuilder!(
              tester.element(find.byType(Image)),
              StateError('decode'),
              null,
            )
            as Center;
    final cache = binding.imageCache as _TrackingCache;
    cache.evicted.clear();
    (failure.child! as IconButton).onPressed!();
    await tester.pump();
    await tester.pump();
    for (final width in [128, 512]) {
      final key = await ResizeImage.resizeIfNeeded(
        width,
        null,
        FileImage(File(repository.path)),
      ).obtainKey(ImageConfiguration.empty);
      expect(cache.evicted, contains(key));
    }
    expect(repository.forced, [item.id]);
    repository.retry.complete(repository.path);
    await tester.pumpAndSettle();
    await show(700, 3, lowResolution: true);
    expect(
      (tester.widget<Image>(find.byType(Image)).image as ResizeImage).width,
      128,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('禁用远程图片时背景仍保留模糊和占位，不启动加载', (tester) async {
    expect(DramaCover.imagesDisabled, isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 500,
          height: 300,
          child: CoverBackdrop(
            drama: drama('backdrop'),
            overlay: const LinearGradient(
              colors: [Colors.transparent, Colors.black],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsOneWidget);
    expect(find.byType(CoverImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
