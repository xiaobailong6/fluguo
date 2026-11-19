import 'package:duanju_app/danmaku_controller.dart';
import 'package:duanju_app/danmaku_models.dart';
import 'package:duanju_app/danmaku_style.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/player/danmaku_emoji_text.dart';
import 'package:duanju_app/ui/player/danmaku_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

// 所有数据均在内存中生成，不触发平台桥或网络请求。
class _Repository extends FakeRepository {
  _Repository(this.rows);
  final List<DanmakuItem> rows;
  int requests = 0;

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    requests++;
    return DanmakuPage(
      episodeId: plan.danmakuId,
      startMs: startMs,
      nextMs: durationMs,
      items: rows.where((item) => item.timeMs >= startMs).toList(),
    );
  }

  @override
  Future<void> cancelDanmaku() async {}
}

// 测试专用入口只发 dataRevision，覆盖异步加载而没有 motionRevision 的情况。
class _Controller extends DanmakuController {
  _Controller(super.repository);

  bool listening() => hasListeners;

  void replaceItems(List<DanmakuItem> next) {
    items = next;
    dataRevision++;
    notifyListeners();
  }
}

const _frameKey = ValueKey('overlay-frame');
const _style = DanmakuStyle(
  color: Color(0xFF80CCFF),
  opacity: .65,
  stroke: 2,
  shadow: 3,
);

DanmakuItem _item(String id, int timeMs) =>
    DanmakuItem(id: id, text: id, timeMs: timeMs);

void _update(
  DanmakuController controller, {
  int position = 0,
  bool playing = true,
  bool buffering = false,
  bool foreground = true,
  double speed = 1,
}) => controller.update(
  position: Duration(milliseconds: position),
  duration: const Duration(minutes: 3),
  speed: speed,
  playing: playing,
  buffering: buffering,
  foreground: foreground,
  available: true,
);

Future<_Controller> _open(
  List<DanmakuItem> items, {
  int position = 0,
  bool playing = true,
}) async {
  final controller = _Controller(_Repository(items))
    ..setPlan(
      const PlaybackPlan(
        url: 'https://offline.example.test/video.mp4',
        session: 'test',
        danmakuId: 'test',
      ),
    );
  addTearDown(controller.dispose);
  _update(controller, position: position, playing: playing);
  for (var index = 0; index < 8; index++) {
    await Future<void>.value();
  }
  return controller;
}

Widget _host(Widget child, {Size size = const Size(400, 240)}) => MediaQuery(
  data: const MediaQueryData(),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: SizedBox.fromSize(
        size: size,
        child: RepaintBoundary(key: _frameKey, child: child),
      ),
    ),
  ),
);

Widget _overlay(DanmakuController controller) =>
    DanmakuOverlay(controller: controller, aspectRatio: 5 / 3, style: _style);

Finder _motion(String id) => find.byKey(ValueKey('danmaku-motion-$id'));

RenderBox _textBox(WidgetTester tester, String id) =>
    tester.renderObject<RenderProxyBox>(_motion(id)).child!;

void _idle(WidgetTester tester) {
  expect(tester.binding.transientCallbackCount, 0);
  expect(tester.binding.hasScheduledFrame, isFalse);
}

// 使用原 Transform.translate 构造参考图，不依赖平台相关的磁盘 golden。
Widget _reference(DanmakuItem item, double ms, double width) {
  final fill = danmakuTextStyle(fontSize: 16, style: _style);
  final outline = danmakuTextStyle(fontSize: 16, style: _style, stroke: true);
  final painter = TextPainter(
    text: TextSpan(text: item.text, style: fill),
    textDirection: TextDirection.ltr,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  )..layout();
  final textWidth = painter.width.ceilToDouble() + 8;
  painter.dispose();
  Widget text(TextStyle style) => Text(
    item.text,
    style: style,
    textScaler: TextScaler.noScaling,
    textDirection: TextDirection.ltr,
    maxLines: 1,
    softWrap: false,
  );
  return Center(
    child: SizedBox(
      width: width,
      height: 240,
      child: ClipRect(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 8,
              width: textWidth,
              height: 24,
              child: Transform.translate(
                offset: Offset(
                  width -
                      (width + textWidth) *
                          (ms - item.timeMs) /
                          danmakuLifetimeMs,
                  0,
                ),
                child: RepaintBoundary(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [text(outline), text(fill)],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('设置即时更新同一条飞行中的弹幕，不重新请求', (tester) async {
    final store = await openStore();
    final controller = await _open([_item('[赞]', 0)], position: 1000);
    final repository = controller.repository as _Repository;
    final requests = repository.requests;
    Widget host(Size size) => _host(
      StoredDanmakuOverlay(
        controller: controller,
        aspectRatio: 2,
        store: store,
        source: 'hongguo',
        topLimit: 76,
      ),
      size: size,
    );
    double rowTop() =>
        tester.getTopLeft(_motion('[赞]')).dy -
        tester.getTopLeft(find.byKey(_frameKey)).dy;

    await tester.pumpWidget(host(const Size(320, 560)));
    final motion = tester.element(_motion('[赞]'));
    expect(rowTop(), 208);
    expect(find.text('[赞]'), findsWidgets);
    final initialOverlay = tester.widget<DanmakuOverlay>(
      find.byType(DanmakuOverlay),
    );
    await store.setHideVip(true);
    await tester.pump();
    expect(
      tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)),
      same(initialOverlay),
    );
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(speed: 1.5),
    );
    await tester.pump();
    expect(
      tester.widget<DanmakuOverlay>(find.byType(DanmakuOverlay)),
      same(initialOverlay),
    );
    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(danmakuEmoji: true),
    );
    await store.setDanmakuUpperBar(true);
    await tester.pump(const Duration(milliseconds: 32));
    expect(tester.element(_motion('[赞]')), same(motion));
    expect(find.byType(DanmakuEmojiText), findsOneWidget);
    expect(find.text('[赞]'), findsNothing);
    expect(rowTop(), 84);

    await store.setPlaybackPreferences(
      store.playbackPreferences.copyWith(danmakuEmoji: false),
    );
    await store.setDanmakuUpperBar(false);
    await tester.pump();
    expect(tester.element(_motion('[赞]')), same(motion));
    expect(find.byType(DanmakuEmojiText), findsNothing);
    expect(find.text('[赞]'), findsWidgets);
    expect(rowTop(), 208);

    await store.setDanmakuUpperBar(true);
    await tester.pumpWidget(host(const Size(320, 160)));
    expect(rowTop(), 8); // 没有上黑边，保持原位置。
    expect(repository.requests, requests);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('绘制、描边、透明度及坐标与原 Transform 一致', (tester) async {
    final item = _item('paint', 0);
    final controller = await _open([item], position: 2000, playing: false);
    await tester.pumpWidget(_host(_overlay(controller)));
    final box = _textBox(tester, item.id);
    final motion = tester.renderObject<RenderBox>(_motion(item.id));
    expect(
      box.localToGlobal(Offset.zero).dx - motion.localToGlobal(Offset.zero).dx,
      closeTo(400 - (400 + box.size.width) * .25, .0001),
    );
    expect(
      find.descendant(
        of: find.byType(DanmakuOverlay),
        matching: find.byType(IgnorePointer),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(DanmakuOverlay),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
    final actual = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_frameKey))
        .toImageSync();
    await tester.pumpWidget(_host(_reference(item, 2000, 400)));
    final reference = tester
        .renderObject<RenderRepaintBoundary>(find.byKey(_frameKey))
        .toImageSync();
    await expectLater(actual, matchesReferenceImage(reference));
    actual.dispose();
    reference.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生逐帧位移只重绘，不重建 widget 或重排文字', (tester) async {
    final controller = await _open([_item('move', 0)]);
    await tester.pumpWidget(_host(_overlay(controller)));
    await tester.pump();
    final element = tester.element(_motion('move'));
    final widget = element.widget;
    final box = _textBox(tester, 'move');
    final origin = box.localToGlobal(Offset.zero);
    final child = tester.renderObject<RenderProxyBox>(_motion('move')).child;
    // 120Hz 间隔也必须每帧更新，不能引入上游的 60Hz 降频。
    for (var frame = 1; frame <= 4; frame++) {
      await tester.pump(const Duration(microseconds: 8333));
      expect(identical(tester.element(_motion('move')).widget, widget), isTrue);
      expect(box.debugNeedsLayout, isFalse);
      expect(
        box.localToGlobal(Offset.zero).dx,
        closeTo(
          origin.dx -
              (400 + box.size.width) * frame * 8.333 / danmakuLifetimeMs,
          .001,
        ),
      );
      expect(
        tester.renderObject<RenderProxyBox>(_motion('move')).child,
        same(child),
      );
      expect(tester.binding.transientCallbackCount, 1);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _idle(tester);
  });

  testWidgets('空排期无持续帧或定时器', (tester) async {
    final controller = await _open([]);
    await tester.pumpWidget(_host(_overlay(controller)));
    _idle(tester);
    await tester.pump(const Duration(minutes: 1));
    _idle(tester);
    // 保留挂载到测试结束；binding 同时检查没有未取消的 Timer。
  });

  testWidgets('空档只等下一条，结束后停帧，回拖可重新入屏', (tester) async {
    final controller = await _open([
      _item('later', 1000),
      _item('last', 12000),
    ]);
    await tester.pumpWidget(_host(_overlay(controller)));
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 999));
    expect(_motion('later'), findsNothing);
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_motion('later'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump(const Duration(milliseconds: danmakuLifetimeMs));
    expect(_motion('later'), findsNothing);
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 2999));
    expect(_motion('last'), findsNothing);
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_motion('last'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pump(const Duration(milliseconds: danmakuLifetimeMs));
    expect(_motion('last'), findsNothing);
    _idle(tester);
    controller.beginSeek();
    controller.endSeek(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(_motion('later'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    _idle(tester);
  });

  testWidgets('暂停、缓冲、隐藏和 seek 取消等待，恢复后重新唤醒', (tester) async {
    final controller = await _open([_item('later', 1000)]);
    await tester.pumpWidget(_host(_overlay(controller)));
    for (final mode in ['pause', 'buffer', 'hidden', 'seek']) {
      if (mode == 'seek') {
        controller.beginSeek();
      } else {
        _update(
          controller,
          playing: mode != 'pause',
          buffering: mode == 'buffer',
          foreground: mode != 'hidden',
        );
      }
      await tester.pump();
      _idle(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(_motion('later'), findsNothing);
      _idle(tester);
      if (mode == 'seek') controller.endSeek(Duration.zero);
      _update(controller);
      await tester.pump();
      _idle(tester);
    }
    await tester.pump(const Duration(seconds: 1));
    expect(_motion('later'), findsOneWidget);
    _update(controller, position: 1200, playing: false);
    await tester.pump();
    final stopped = _textBox(tester, 'later').localToGlobal(Offset.zero);
    await tester.pump(const Duration(seconds: 2));
    expect(_textBox(tester, 'later').localToGlobal(Offset.zero), stopped);
    _idle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('倍速与 motionRevision 重算等待，普通回报不拉回锚点', (tester) async {
    final controller = await _open([_item('later', 1000)]);
    await tester.pumpWidget(_host(_overlay(controller)));
    _update(controller, speed: 2);
    await tester.pump(const Duration(milliseconds: 499));
    expect(_motion('later'), findsNothing);
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_motion('later'), findsOneWidget);
    controller.beginSeek();
    controller.endSeek(const Duration(milliseconds: 800));
    await tester.pump();
    expect(_motion('later'), findsNothing);
    await tester.pump(const Duration(milliseconds: 99));
    expect(_motion('later'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(_motion('later'), findsOneWidget);
    final before = _textBox(tester, 'later').localToGlobal(Offset.zero);
    // 不经过 update 的漂移检测，只模拟一次普通控制器通知。
    controller.positionMs = 900;
    final revision = controller.motionRevision;
    controller.retry();
    await tester.pump(const Duration(milliseconds: 10));
    expect(controller.motionRevision, revision);
    expect(
      _textBox(tester, 'later').localToGlobal(Offset.zero).dx,
      lessThan(before.dx),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('新数据与零行尺寸恢复重新排期，并取消旧唤醒', (tester) async {
    final controller = await _open([]);
    await tester.pumpWidget(_host(_overlay(controller)));
    await tester.pump(const Duration(seconds: 1));
    controller.replaceItems([_item('new', 1500)]);
    await tester.pump();
    _idle(tester);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_motion('new'), findsOneWidget);
    await tester.pumpWidget(
      _host(_overlay(controller), size: const Size(40, 24)),
    );
    await tester.pump();
    _idle(tester);
    await tester.pumpWidget(_host(_overlay(controller)));
    expect(_motion('new'), findsOneWidget);
    expect(tester.binding.transientCallbackCount, 1);
    controller.replaceItems([_item('future', 5000)]);
    await tester.pump();
    _idle(tester);
    controller.replaceItems([]);
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(_motion('future'), findsNothing);
    _idle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('dispose 取消等待并解绑；替换 controller 不沿用旧排期', (tester) async {
    final first = await _open([_item('first', 1000)]);
    final second = await _open([_item('second', 2000)]);
    await tester.pumpWidget(_host(_overlay(first)));
    await tester.pumpWidget(_host(_overlay(second)));
    expect(first.listening(), isFalse);
    await tester.pump(const Duration(seconds: 1));
    expect(_motion('first'), findsNothing);
    _idle(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(second.listening(), isFalse);
    await tester.pump(const Duration(seconds: 3));
    _update(first, position: 500);
    _update(second, position: 500);
    await tester.pump();
    _idle(tester);
    expect(tester.takeException(), isNull);
  });
}
