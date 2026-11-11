import 'dart:async';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_session.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_handle.dart';
import 'package:duanju_app/ui/player/portrait_player_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_player.dart';
import 'support/fakes.dart';

class _WaitingRepository extends FakeRepository {
  final result = Completer<PlaybackPlan>();
  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0}) => result.future;
}

class _Handle implements PlaybackHandle {
  _Handle(this.session);
  @override
  final PlaybackSession session;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final hiddenBars in [false, true]) {
    testWidgets('系统栏隐藏=$hiddenBars，底部上滑不翻页，画面内上滑仍切集', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late PlaybackSession session;
      final repository = _WaitingRepository();
      await tester.runAsync(() async {
        session = PlaybackSession(
          repository: repository, store: await openStore(),
          detail: dramaDetail(drama('gesture'), count: 3),
          player: FakePlayer(), index: 0,
        );
        await pumpEventQueue();
      });
      await tester.pumpWidget(MaterialApp(
        builder: (context, child) => AppScope(
          repository: repository, formFactor: FormFactor.phone,
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewPadding: const EdgeInsets.only(bottom: 24),
              padding: EdgeInsets.only(bottom: hiddenBars ? 0 : 24),
            ),
            child: child!,
          ),
        ),
        home: PortraitPlayerPage(store: session.store, handle: _Handle(session)),
      ));
      await tester.pump();
      final controller = tester.widget<PageView>(find.byType(PageView)).controller!;
      expect(tester.getSize(find.byKey(const ValueKey('system-gesture-guard'))).height, 24);
      await tester.dragFrom(const Offset(195, 835), const Offset(0, -650));
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.page, closeTo(0, .01));
      expect(session.index, 0);
      await tester.dragFrom(const Offset(195, 450), const Offset(0, -650));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(controller.page, closeTo(1, .01));
      expect(session.index, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        session.dispose();
        repository.result.completeError(AppFailure('测试结束'));
        await pumpEventQueue();
      });
      expect(tester.takeException(), isNull);
    });
  }
}
