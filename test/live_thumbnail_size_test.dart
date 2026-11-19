import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/ui/live/live_category_image.dart';
import 'package:duanju_app/ui/live/live_room_cover.dart';
import 'package:duanju_app/ui/live/live_thumbnail_size.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Platform extends Fake implements LivePlatform {
  int calls = 0;
  @override
  Future<String> categoryPicture(LiveCategory category) async {
    calls++;
    return category.picture;
  }
}

void main() {
  test('连续改变窗口宽度：仅有 8 种解码宽度，向上取档且不超过旧上限', () {
    final keys = <int>{};
    for (var width = 1; width <= 1300; width++) {
      final value = liveThumbnailWidth(width.toDouble(), 1);
      keys.add(value);
      expect(value, inInclusiveRange(width.clamp(1, 1200), 1200));
    }
    expect(keys, {128, 192, 256, 384, 512, 768, 1024, 1200});
    expect(liveThumbnailWidth(128, 2), 256);
    expect(liveThumbnailWidth(128.1, 2), 384);
  });

  testWidgets('房间与分区使用实际布局和 DPR 的 ResizeImage 键，尺寸变化不重新补图', (tester) async {
    final platform = _Platform();
    for (final (width, dpr, expected) in [
      (149.0, 1.0, 192),
      (149.0, 2.0, 384),
      (150.0, 2.0, 384),
      (150.0, 3.0, 512),
      (400.1, 3.0, 1200),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(devicePixelRatio: dpr),
            child: Center(
              child: SizedBox(
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(
                      height: 90,
                      child: LiveRoomCover(
                        url: 'https://images.test/room',
                        imagesEnabled: true,
                      ),
                    ),
                    SizedBox(
                      height: 90,
                      child: LiveCategoryImage(
                        platform: platform,
                        category: const LiveCategory(
                          name: '游戏',
                          parentId: '1',
                          picture: 'https://images.test/area',
                        ),
                        fallback: const SizedBox.expand(),
                        imagesEnabled: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      for (final widget in [LiveRoomCover, LiveCategoryImage]) {
        final image = tester.widget<Image>(
          find.descendant(
            of: find.byType(widget),
            matching: find.byType(Image),
          ),
        );
        final provider = image.image as ResizeImage;
        expect(provider.width, expected);
        expect(provider.height, isNull);
        expect(image.fit, BoxFit.cover);
      }
    }
    expect(platform.calls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
