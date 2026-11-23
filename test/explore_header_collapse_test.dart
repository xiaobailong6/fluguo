import 'package:duanju_app/ui/explore/explore_header_inset.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final initialOffset in [0.0, 70.0, 160.0, 600.0]) {
    testWidgets('占位折叠展开补偿且不重复累计 offset=$initialOffset', (tester) async {
      final state = ExploreHeaderInsetState();
      final height = ValueNotifier(108.0);
      final scroll = ScrollController(initialScrollOffset: initialOffset);
      addTearDown(height.dispose);
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              controller: scroll,
              slivers: [
                ValueListenableBuilder<double>(
                  valueListenable: height,
                  builder: (_, extent, _) =>
                      ExploreHeaderInset(extent: extent, state: state),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(key: ValueKey('content'), height: 2000),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = tester
          .getTopLeft(find.byKey(const ValueKey('content')))
          .dy;
      for (var i = 0; i < 3; i++) {
        height.value = 0;
        await tester.pump();
        expect(
          scroll.offset,
          closeTo((initialOffset - 108).clamp(0, double.infinity), .01),
        );
        final top = tester.getTopLeft(find.byKey(const ValueKey('content'))).dy;
        expect(top, closeTo(initialOffset > 108 ? before : 0, .01));
        height.value = 108;
        await tester.pump();
        // 已在内容中间的列表保住屏幕位置；顶部列表展开完整占位。
        expect(
          scroll.offset,
          closeTo(initialOffset > 108 ? initialOffset : 0, .01),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('离屏重建按保存的占位高度校正一次，不重复补偿', (tester) async {
    final state = ExploreHeaderInsetState()..extent = 108;
    final scroll = ScrollController(initialScrollOffset: 380);
    addTearDown(scroll.dispose);
    Widget page() => MaterialApp(
      home: Scaffold(
        body: CustomScrollView(
          controller: scroll,
          slivers: [
            ExploreHeaderInset(extent: 0, state: state),
            const SliverToBoxAdapter(child: SizedBox(height: 2000)),
          ],
        ),
      ),
    );
    await tester.pumpWidget(page());
    expect(scroll.offset, 272);
    await tester.pumpWidget(page());
    expect(scroll.offset, 272);
    expect(state.extent, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
