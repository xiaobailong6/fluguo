import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/player_season_choice.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

final _first = drama('choice-first');
final _second = drama('choice-second');
final _rows = [
  DramaSeason(number: 1, drama: _first),
  DramaSeason(number: 2, drama: _second),
];

class _Repository extends FakeRepository {
  List<DramaSeason> rows = _rows;
  Completer<DramaDetail>? detailGate;
  bool failSeasons = false;
  int seasonCalls = 0;
  @override
  Future<List<DramaSeason>> seasons(Drama drama) async {
    seasonCalls++;
    if (failSeasons) throw StateError('offline fixture');
    return rows;
  }

  @override
  Future<DramaDetail> detail(Drama drama) async =>
      detailGate?.future ?? dramaDetail(drama, count: 4);
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan(url: 'https://fixture.invalid/${drama.id}');
}

void main() {
  Future<PlaybackSession> mount(
    WidgetTester tester,
    _Repository repo, {
    FocusNode? focus,
  }) async {
    final store = await tester.runAsync(openStore);
    final session = PlaybackSession(
      repository: repo,
      store: store!,
      detail: dramaDetail(_first, count: 3),
      player: FakePlayer(),
      index: 0,
    );
    await tester.runAsync(() => pumpEventQueue());
    await tester.pumpWidget(
      AppScope(
        repository: repo,
        formFactor: FormFactor.phone,
        child: MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Center(
              child: PlayerSeasonChoice(session: session, focusNode: focus),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return session;
  }

  testWidgets(
    'existing choice popup selects official season and disables while pending',
    (tester) async {
      final repo = _Repository()..detailGate = Completer<DramaDetail>();
      final session = await mount(tester, repo);
      expect(find.text('第 1 季'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-season-choice')));
      await tester.pumpAndSettle();
      expect(find.text('选择季'), findsOneWidget);
      await tester.tap(find.text('第 2 季'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => pumpEventQueue());
      expect(session.switchingSeason, isTrue);
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('player-season-choice')),
            )
            .onPressed,
        isNull,
      );
      repo.detailGate!.complete(dramaDetail(_second, count: 4));
      await tester.runAsync(() => pumpEventQueue());
      await tester.pumpAndSettle();
      expect(find.text('第 2 季'), findsOneWidget);
      expect(session.detail.drama.id, _second.id);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets(
    'single season has no entry and screen lock disables an existing entry',
    (tester) async {
      final single = _Repository()..rows = [_rows.first];
      final firstSession = await mount(tester, single);
      expect(find.byKey(const ValueKey('player-season-choice')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      firstSession.dispose();
      final session = await mount(tester, _Repository());
      session.setLocked(true);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('player-season-choice')),
            )
            .onPressed,
        isNull,
      );
      session.setLocked(false);
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('player-season-choice')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox());
      session.dispose();
    },
  );
  testWidgets('failed initial load keeps a focusable keyboard retry entry', (
    tester,
  ) async {
    final focus = FocusNode();
    final repo = _Repository()..failSeasons = true;
    final session = await mount(tester, repo, focus: focus);
    expect(find.text('重试选季'), findsOneWidget);
    // TV 焦点行以实际节点是否挂载/可聚焦为准，不依赖成功加载后的季数。
    expect(focus.context, isNotNull);
    expect(focus.canRequestFocus, isTrue);
    focus.requestFocus();
    await tester.pump();
    repo.failSeasons = false;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(repo.seasonCalls, 2);
    expect(find.text('第 1 季'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
    focus.dispose();
  });
}
