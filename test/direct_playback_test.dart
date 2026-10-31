import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/resource_settings_editor.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/detail/detail_page.dart';
import 'package:duanju_app/ui/explore/explore_page.dart';
import 'package:duanju_app/ui/player/direct_playback_page.dart';
import 'package:duanju_app/ui/settings/settings_sections.dart';
import 'package:duanju_app/ui/widgets/drama_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class EntryRepository extends FakeRepository {
  Completer<DramaDetail>? held;
  bool fail = false;
  bool empty = false;
  @override
  Future<DramaDetail> detail(Drama item) async {
    if (fail) throw StateError('secret url must not appear');
    if (held != null) return held!.future;
    return dramaDetail(item, count: empty ? 0 : 4);
  }
}

Widget host(FakeRepository repo, Widget child) => MaterialApp(
  builder: (_, page) =>
      AppScope(repository: repo, formFactor: FormFactor.phone, child: page!),
  home: child,
);

void main() {
  testWidgets('播放设置提供过渡页开关并保存', (tester) async {
    final store = await openStore();
    final repo = FakeRepository();
    final editor = ResourceSettingsEditor(repo, store);
    addTearDown(editor.dispose);
    await tester.pumpWidget(
      host(
        repo,
        Scaffold(
          body: SingleChildScrollView(
            child: SettingsSection(
              group: SettingsGroup.playback,
              store: store,
              editor: editor,
              open: (_, _) {},
            ),
          ),
        ),
      ),
    );
    expect(store.showDramaDetails, isTrue);
    await tester.tap(find.text('显示剧集信息过渡页'));
    await tester.pumpAndSettle();
    expect(store.showDramaDetails, isFalse);
    expect(restartStore(store).showDramaDetails, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final showDetails in [true, false]) {
    testWidgets('短剧卡片过渡页开关 $showDetails', (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = await openStore();
      await store.setShowDramaDetails(showDetails);
      final repo = EntryRepository()..held = Completer<DramaDetail>();
      await tester.pumpWidget(host(repo, ExplorePage(store: store)));
      await tester.pumpAndSettle();
      final tile = find.byType(DramaTile).first;
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(tile);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byType(DetailPage),
        showDetails ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(DirectPlaybackPage),
        showDetails ? findsNothing : findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      repo.held!.complete(dramaDetail(drama('finished')));
      await tester.pump();
    });
  }

  testWidgets('直接播放续播位置、失败重试和空剧集不创建播放器', (tester) async {
    final store = await openStore();
    final item = drama('resume');
    await store.saveWatch(
      WatchEntry(
        drama: item,
        episode: 2,
        position: 24,
        duration: 100,
        updatedAt: DateTime.now(),
      ),
    );
    final repo = EntryRepository()..fail = true;
    int? index;
    double? position;
    await tester.pumpWidget(
      host(
        repo,
        DirectPlaybackPage(
          store: store,
          drama: item,
          playbackBuilder: (detail, i, p) {
            index = i;
            position = p;
            return const Scaffold(body: Text('in playback'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('无法加载剧集，请重试'), findsOneWidget);
    expect(index, isNull);
    repo.fail = false;
    repo.empty = true;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(index, isNull);
    repo.empty = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('in playback'), findsOneWidget);
    expect(index, 1);
    expect(position, 24);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('迟到详情不能越过撤权进入播放', (tester) async {
    final store = await openStore();
    final repo = EntryRepository()..held = Completer<DramaDetail>();
    var opened = false;
    final item = drama('late');
    await tester.pumpWidget(
      host(
        repo,
        DirectPlaybackPage(
          store: store,
          drama: item,
          playbackBuilder: (_, _, _) {
            opened = true;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();
    await store.setSourceEnabled('hongguo', false);
    repo.held!.complete(dramaDetail(item));
    await tester.pumpAndSettle();
    expect(opened, isFalse);
    expect(find.text('当前用户无权播放此内容'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
