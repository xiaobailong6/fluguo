import 'dart:async';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ui/app_motion.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/search/search_page.dart';
import 'package:duanju_app/ui/widgets/drama_grid.dart';
import 'package:duanju_app/ui/widgets/local_content_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class PendingSearchRepository extends FakeRepository {
  final pending = <(String, int), Completer<CatalogPage>>{};

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) {
    catalogRequests.add('$source|$query|$page');
    final request = Completer<CatalogPage>();
    pending[(query, page)] = request;
    return request.future;
  }
}

Future<void> mountSearch(
  WidgetTester tester,
  LocalStore store,
  PendingSearchRepository repository, {
  String query = 'first',
}) async {
  await tester.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: AppScope(
        repository: repository,
        formFactor: FormFactor.phone,
        child: SearchPage(
          store: store,
          source: SourceSite.hongguo,
          query: query,
        ),
      ),
    ),
  );
}

LocalContentTransition searchMotion(WidgetTester tester) =>
    tester.widget<LocalContentTransition>(find.byType(LocalContentTransition));

double searchOpacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find
          .descendant(
            of: find.byType(LocalContentTransition),
            matching: find.byType(Opacity),
          )
          .first,
    )
    .opacity;

Future<void> submit(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
}

void main() {
  testWidgets('async results enter once without rebuilding the focused field', (
    tester,
  ) async {
    final store = await openStore();
    final repository = PendingSearchRepository();
    await mountSearch(tester, store, repository);
    expect(searchMotion(tester).identity, ('hongguo', 'first', 'loading'));
    expect(searchMotion(tester).ready, isFalse);
    expect(searchOpacity(tester), 1);
    expect(find.text('正在搜索'), findsOneWidget);
    final fieldState = tester.state(find.byType(TextField));
    final field = tester.widget<TextField>(find.byType(TextField));
    await tester.showKeyboard(find.byType(TextField));
    expect(field.focusNode!.hasFocus, isTrue);

    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('one', title: 'First result')]),
    );
    await tester.pump();
    expect(searchMotion(tester).identity, ('hongguo', 'first', 'content'));
    expect(searchOpacity(tester), closeTo(.55, .001));
    expect(find.byType(DramaSliverGrid), findsOneWidget);
    expect(tester.state(find.byType(TextField)), same(fieldState));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller,
      same(field.controller),
    );
    expect(field.focusNode!.hasFocus, isTrue);
    await tester.pump(AppMotion.state);
    expect(searchOpacity(tester), 1);
    expect(repository.catalogRequests, ['hongguo|first|1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('latest query wins and error retry enters empty state', (
    tester,
  ) async {
    final store = await openStore();
    final repository = PendingSearchRepository();
    await mountSearch(tester, store, repository);
    await submit(tester, 'second');
    expect(searchMotion(tester).ready, isFalse);
    expect(searchOpacity(tester), 1);
    repository.pending[('first', 1)]!.complete(
      CatalogPage([drama('stale', title: 'Stale result')]),
    );
    await tester.pump();
    expect(find.text('Stale result'), findsNothing);
    expect(find.byType(DramaSliverGrid), findsNothing);
    expect(searchMotion(tester).identity, ('hongguo', 'second', 'loading'));

    repository.pending[('second', 1)]!.completeError(StateError('offline'));
    await tester.pump();
    expect(searchMotion(tester).identity, ('hongguo', 'second', 'error'));
    expect(searchOpacity(tester), closeTo(.55, .001));
    await tester.pump(AppMotion.state);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(searchMotion(tester).ready, isFalse);
    expect(searchOpacity(tester), 1);
    repository.pending[('second', 1)]!.complete(CatalogPage(const []));
    await tester.pump();
    expect(searchMotion(tester).identity, ('hongguo', 'second', 'empty'));
    expect(searchOpacity(tester), closeTo(.55, .001));
    expect(find.text('没有找到「second」'), findsOneWidget);
    expect(find.byType(LocalContentTransition), findsOneWidget);
    await tester.pump(AppMotion.state);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pagination keeps scroll state and suggestions do not animate', (
    tester,
  ) async {
    final store = await openStore();
    final repository = PendingSearchRepository();
    await mountSearch(tester, store, repository);
    repository.pending[('first', 1)]!.complete(
      CatalogPage(List.generate(60, (i) => drama('item-$i')), hasMore: true),
    );
    await tester.pump();
    await tester.pump(AppMotion.state);
    final scrollFinder = find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    );
    final scroll = tester.state<ScrollableState>(scrollFinder);
    scroll.position.jumpTo(300);
    await tester.pump();
    final motionState = tester.state(find.byType(LocalContentTransition));
    final grid = tester.widget<DramaSliverGrid>(find.byType(DramaSliverGrid));
    final feed = tester.widget<AutoLoadMore>(find.byType(AutoLoadMore)).feed;
    unawaited(feed.loadMore());
    await tester.pump();
    expect(searchOpacity(tester), 1);
    repository.pending[('first', 2)]!.complete(
      CatalogPage([drama('appended')], page: 2),
    );
    await tester.pump();
    expect(searchOpacity(tester), 1);
    expect(tester.state<ScrollableState>(scrollFinder), same(scroll));
    expect(scroll.position.pixels, 300);
    expect(
      tester.state(find.byType(LocalContentTransition)),
      same(motionState),
    );
    expect(
      tester
          .widget<DramaSliverGrid>(find.byType(DramaSliverGrid))
          .items
          .map((item) => item.id),
      [...grid.items.map((item) => item.id), 'hongguo:appended'],
    );
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(repository.catalogRequests, ['hongguo|first|1', 'hongguo|first|2']);

    // 输入尚未提交时不能成为新的结果身份；建议列表本身不包动效。
    await tester.enterText(find.byType(TextField), 'f');
    await tester.pump(const Duration(milliseconds: 250));
    expect(searchMotion(tester).identity, ('hongguo', 'first', 'content'));
    expect(searchOpacity(tester), 1);
    repository.suggestionList = ['first suggestion'];
    await tester.enterText(find.byType(TextField), 'fi');
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();
    expect(find.text('first suggestion'), findsOneWidget);
    expect(find.byType(LocalContentTransition), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('entry motion does not bypass the profile source-access guard', (
    tester,
  ) async {
    final store = await openStore(viewerPreferences);
    final repository = PendingSearchRepository();
    await mountSearch(tester, store, repository);
    final blocked = drama('blocked', source: 'dsd');
    repository.pending[('first', 1)]!.complete(CatalogPage([blocked]));
    await tester.pump();
    expect(searchOpacity(tester), closeTo(.55, .001));
    expect(store.allowsSource(blocked.source), isFalse);
    tester
        .widget<DramaSliverGrid>(find.byType(DramaSliverGrid))
        .onOpen(blocked);
    await tester.pump(AppMotion.state);
    expect(find.byType(SearchPage), findsOneWidget);
    expect(repository.detailRequests, 0);
    expect(searchOpacity(tester), 1);
    expect(tester.takeException(), isNull);
  });
}
