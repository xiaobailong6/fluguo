import 'package:duanju_app/download_converter.dart';
import 'package:duanju_app/download_overview.dart';
import 'package:duanju_app/merge_queue.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/downloads/downloads_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Library extends MergedLibrary {
  @override
  Future<void> ensureInitialized() async {}
}

void main() {
  testWidgets('下载标签跟手，松手同步；编辑禁止横滑、快速点击最终目标一致', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = await openStore();
    final repo = FakeRepository()..jobs = [downloadJob(drama('one'), 1)];
    final overview = DownloadOverview(
      repo,
      store,
      interval: const Duration(hours: 1),
    );
    final converter = DownloadConverter(repo, overview);
    final library = _Library();
    final merges = MergeQueue(repo, library: library);
    var disposed = false;
    void dispose() {
      if (disposed) return;
      disposed = true;
      converter.dispose();
      overview.dispose();
      merges.dispose();
      library.dispose();
    }

    addTearDown(dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: repo,
          formFactor: FormFactor.phone,
          child: DownloadsPage(
            store: store,
            downloads: overview,
            converter: converter,
            merges: merges,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(330, 400));
    await gesture.moveBy(const Offset(-150, 0));
    await tester.pump();
    final pager = tester.widget<PageView>(find.byType(PageView)).controller!;
    expect(pager.page, inExclusiveRange(0, 1));
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(('download-page', 1)))).dx,
      lessThan(390),
    );
    await gesture.moveBy(const Offset(-170, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    final tabs = tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(tabs.index, 1);
    expect(tabs.animation!.value, closeTo(1, .001));
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TabBarView>(find.byType(TabBarView)).physics,
      isA<NeverScrollableScrollPhysics>(),
    );
    await tester.drag(find.byType(TabBarView), const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tabs.index, 1);
    tabs.animateTo(2);
    await tester.pump();
    tabs.animateTo(0);
    await tester.pumpAndSettle();
    expect(pager.page, closeTo(0, .001));
    expect(tabs.index, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    dispose();
  });
}
