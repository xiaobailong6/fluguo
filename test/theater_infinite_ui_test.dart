import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart' show PreviewRepository, FakePreviewBackend;

class FinitePreviewRepository extends PreviewRepository {
  FinitePreviewRepository(this.count);
  final int count;
  CatalogPage content() => CatalogPage([
    for (var i = 0; i < count; i++) drama('finite-$i'),
  ], hasMore: false);
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage(const [], hasMore: false);
  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => content();
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => content();
}

void main() {
  for (final count in [1, 80]) {
    testWidgets('有限$count部剧持续翻页、裁剪保留当前预览且同剧再次出现重播', (tester) async {
      final store = await openStore();
      for (final source in store.sources.toList()) {
        if (source.id != 'hongguo') {
          await store.setSourceEnabled(source.id, false);
        }
      }
      final repo = FinitePreviewRepository(count);
      final backend = FakePreviewBackend();
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppScope(
            repository: repo,
            formFactor: FormFactor.phone,
            child: child!,
          ),
          home: TheaterPage(store: store, previewBackend: () => backend),
        ),
      );
      await tester.pumpAndSettle();
      final resolved = <String>{repo.resolved.last};
      for (var swipe = 0; swipe < (count == 1 ? 12 : 70); swipe++) {
        final view = tester.widget<PageView>(
          find.byKey(const ValueKey('theater-preview-flow')),
        );
        final index = view.controller!.page!.round();
        expect(index + 1, lessThan(view.childrenDelegate.estimatedChildCount!));
        backend.position = const Duration(seconds: 20);
        view.controller!.jumpToPage(index + 1);
        await tester.pumpAndSettle();
        final after = tester.widget<PageView>(
          find.byKey(const ValueKey('theater-preview-flow')),
        );
        expect(
          after.childrenDelegate.estimatedChildCount,
          lessThanOrEqualTo(60),
        );
        expect(backend.opens.last, Duration.zero);
        expect(backend.opens.length, swipe + 2);
        expect(
          find.byKey(const ValueKey('fake-preview-video')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        resolved.add(repo.resolved.last);
      }
      if (count > 1) expect(resolved.length, 71);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
