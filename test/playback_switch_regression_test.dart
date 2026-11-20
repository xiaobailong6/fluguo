import 'dart:async';

import 'package:duanju_app/app_failure.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_loader.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:duanju_app/theater_preview.dart';
import 'package:duanju_app/playback_request_retry.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/theater/theater_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';
import 'theater_test.dart'
    show PreviewRepository, FakePreviewBackend, flushPreview;

class _TransientRepository extends PreviewRepository {
  int failures = 1;
  int calls = 0;
  String code = 'network';
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    calls++;
    if (failures-- > 0) throw AppFailure('synthetic', code: code);
    return super.resolve(drama, episode, quality: quality);
  }
}

class _PreloadRepository extends FakeRepository {
  final released = <String>[];
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan(
    url: 'https://example.invalid/media',
    session: episode.raw['id'] as String,
  );
  @override
  Future<void> release(String session) async => released.add(session);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('剧场上划切剧遇单次网络错误无需手动重试', (tester) async {
    final repo = _TransientRepository()..failures = 0;
    final backend = FakePreviewBackend();
    final store = await openStore();
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
    final initialCalls = repo.calls;
    final initialTitle = tester
        .widget<Text>(find.byKey(const ValueKey('theater-drama-title')))
        .data;
    repo.failures = 1;
    await tester.drag(
      find.byKey(const ValueKey('theater-preview-flow')),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(repo.calls, initialCalls + 2);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('theater-drama-title')))
          .data,
      isNot(initialTitle),
    );
    expect(find.text('预览加载失败，请重试'), findsNothing);
    expect(backend.playing, isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  test('剧场上划遇瞬时取流失败仅重试一次并继续播放新剧', () async {
    final repo = _TransientRepository()..failures = 0;
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(
      repo,
      await openStore(),
      backend: () => backend,
    );
    preview.select(drama('a'));
    preview.setVisible(true);
    await flushPreview();
    repo.failures = 1;
    preview.select(drama('b'));
    await flushPreview();
    expect(preview.error, isNull);
    expect(preview.loading, isFalse);
    expect(backend.playing, isTrue);
    expect(repo.calls, 3);
    expect(repo.resolved.last, '${drama('b').id}:1');
    preview.dispose();
    await flushPreview();
  });
  test('剧场加载失败后重新显示成功不残留错误遮罩', () async {
    final repo = PreviewRepository()..detailFailure = 'offline';
    final backend = FakePreviewBackend();
    final preview = TheaterPreview(
      repo,
      await openStore(),
      backend: () => backend,
    );
    preview.select(drama('a'));
    preview.setVisible(true);
    await flushPreview();
    expect(preview.error, isNotNull);
    await preview.suspend();
    repo.detailFailure = '';
    preview.setVisible(true);
    await flushPreview();
    expect(backend.playing, isTrue);
    expect(preview.error, isNull);
    preview.dispose();
    await flushPreview();
  });
  test('普通切集和搜索播放共用加载器可恢复瞬时网络失败', () async {
    final repo = _TransientRepository();
    final loader = PlaybackLoader(repo);
    expect(
      await loader.load(drama('search'), Episode({'id': '1'}, 1)),
      isNotNull,
    );
    repo.failures = 1;
    expect(
      await loader.load(drama('search'), Episode({'id': '2'}, 2)),
      isNotNull,
    );
    expect(repo.calls, 4);
    await loader.close();
  });
  for (final code in ['permission', 'cancelled', 'rate_limit']) {
    test('播放加载器不自动重试 $code', () async {
      final repo = _TransientRepository()..code = code;
      final loader = PlaybackLoader(repo);
      await expectLater(
        loader.load(drama('a'), Episode({}, 1)),
        throwsA(isA<AppFailure>()),
      );
      expect(repo.calls, 1);
      await loader.close();
    });
  }
  test('瞬时错误最多重试一次，失效请求不再重试', () async {
    var calls = 0;
    await expectLater(
      retryPlaybackRequest<int>(() async {
        calls++;
        throw const AppFailure('offline', code: 'network');
      }, isCurrent: () => true),
      throwsA(isA<AppFailure>()),
    );
    expect(calls, 2);
    calls = 0;
    final pending = Completer<int>();
    var current = true;
    final result = retryPlaybackRequest(() {
      calls++;
      return pending.future;
    }, isCurrent: () => current);
    final checked = expectLater(result, throwsA(isA<AppFailure>()));
    current = false;
    pending.completeError(const AppFailure('offline', code: 'timeout'));
    await checked;
    expect(calls, 1);
  });

  testWidgets('预载不能把同集号旧分集结果交给刷新后的分集', (tester) async {
    final repo = _PreloadRepository();
    final preloader = PlaybackPreloader(repo);
    final show = drama('same');
    preloader.prepare(show, Episode({'id': 'old', 'videoUrl': 'old'}, 2));
    await tester.pump(const Duration(milliseconds: 201));
    expect(preloader.ready, isTrue);
    expect(
      preloader.takeOrWait(show, Episode({'id': 'new', 'videoUrl': 'new'}, 2)),
      isNull,
    );
    expect(repo.released, ['old']);
    preloader.dispose();
  });
}
