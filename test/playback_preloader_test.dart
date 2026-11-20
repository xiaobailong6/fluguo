import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preloader.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

class _Repository extends FakeRepository {
  final requests = <Completer<PlaybackPlan?>>[];
  final released = <String>[];
  int cancels = 0;
  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) {
    final pending = Completer<PlaybackPlan?>();
    requests.add(pending);
    return pending.future;
  }

  @override
  Future<void> cancelPreload() async {
    cancels++;
  }

  @override
  Future<void> release(String session) async {
    released.add(session);
  }
}

PlaybackPlan plan(String id, {int expires = 0}) => PlaybackPlan(
  url: 'https://fixture.invalid/$id',
  session: id,
  expiresAt: expires,
  prefetchedBytes: 1024,
);

void main() {
  final show = drama('show');
  final episode = Episode({}, 2);
  testWidgets('接管在途请求，不重复解析或释放被接管的结果', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    final next = preloader.takeOrWait(show, episode)!;
    expect(preloader.claimed, isTrue);
    preloader.prepare(show, episode);
    repository.requests.single.complete(plan('next'));
    await tester.pump();
    expect((await next)?.session, 'next');
    expect(repository.requests, hasLength(1));
    expect(repository.released, isEmpty);
    preloader.dispose();
    expect(repository.released, isEmpty);
  });
  testWidgets('切集提前触发尚未开始的防抖任务', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(show, episode);
    final next = preloader.takeOrWait(show, episode)!;
    expect(repository.requests, hasLength(1));
    repository.requests.single.complete(plan('next'));
    await tester.pump();
    expect(await next, isNotNull);
    preloader.dispose();
  });
  testWidgets('旧取消任务退出后已接管的新任务立即启动，不重复防抖', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(show, Episode({}, 1));
    await tester.pump(const Duration(milliseconds: 201));
    preloader.prepare(show, episode);
    final next = preloader.takeOrWait(show, episode)!;
    await tester.pump(const Duration(milliseconds: 1400));
    expect(repository.requests, hasLength(1));
    repository.requests.first.complete(plan('old'));
    await tester.pump();
    expect(repository.requests, hasLength(2));
    repository.requests.last.complete(plan('next'));
    await tester.pump();
    expect((await next)?.session, 'next');
    expect(repository.released, ['old']);
    preloader.dispose();
  });

  testWidgets('接管超时及时回退，迟到结果释放且不覆盖新任务', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(
      repository,
      claimWait: const Duration(milliseconds: 50),
    );
    preloader.prepare(show, episode);
    final next = preloader.takeOrWait(show, episode)!;
    await tester.pump(const Duration(milliseconds: 51));
    expect(await next, isNull);
    expect(repository.cancels, 1);
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.requests, hasLength(1), reason: '旧请求未结束，新任务不能叠加');
    repository.requests.first.complete(plan('old'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.requests, hasLength(2));
    repository.requests.last.complete(plan('new'));
    await tester.pump();
    expect(repository.released, ['old']);
    expect(preloader.take(show, episode)?.session, 'new');
    preloader.dispose();
  });
  testWidgets('让路保留已准备缓存，取消在途并释放迟到结果', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    repository.requests.single.complete(plan('ready'));
    await tester.pump();
    preloader.pause();
    expect(preloader.ready, isTrue);
    expect(preloader.take(show, episode)?.session, 'ready');
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    preloader.pause();
    repository.requests.last.complete(plan('late'));
    await tester.pump();
    expect(repository.released, ['late']);
    preloader.dispose();
  });
  testWidgets('画质和来源意图不匹配不复用，过期不能交给播放器', (tester) async {
    final repository = _Repository();
    var now = DateTime.utc(2030);
    final preloader = PlaybackPreloader(repository, now: () => now);
    preloader.prepare(show, episode, quality: 720);
    await tester.pump(const Duration(milliseconds: 201));
    repository.requests.single.complete(plan('quality'));
    await tester.pump();
    expect(preloader.takeOrWait(show, episode, quality: 1080), isNull);
    expect(repository.released, ['quality']);
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    repository.requests.last.complete(
      plan(
        'expiry',
        expires: now.add(const Duration(seconds: 10)).millisecondsSinceEpoch,
      ),
    );
    await tester.pump();
    now = now.add(const Duration(seconds: 6));
    expect(preloader.takeOrWait(show, episode), isNull);
    expect(repository.released, ['quality', 'expiry']);
    preloader.dispose();
  });
  testWidgets('销毁唤醒接管者且迟到结果不通知或泄漏', (tester) async {
    final repository = _Repository();
    final preloader = PlaybackPreloader(repository);
    preloader.prepare(show, episode);
    final next = preloader.takeOrWait(show, episode)!;
    preloader.dispose();
    expect(await next, isNull);
    repository.requests.single.complete(plan('late'));
    await tester.pump();
    expect(repository.released, ['late']);
  });
  testWidgets('失败后30秒退避，过期结果按需刷新且只保留一集', (tester) async {
    final repository = _Repository();
    var now = DateTime.utc(2030);
    final preloader = PlaybackPreloader(repository, now: () => now);
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    repository.requests.single.completeError(StateError('offline'));
    await tester.pump();
    preloader.prepare(show, episode);
    await tester.pump(const Duration(seconds: 1));
    expect(repository.requests, hasLength(1));
    now = now.add(const Duration(seconds: 31));
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    repository.requests.last.complete(plan('ready'));
    await tester.pump();
    now = now.add(const Duration(minutes: 3));
    preloader.prepare(show, episode);
    await tester.pump(const Duration(milliseconds: 201));
    expect(repository.released, ['ready']);
    expect(repository.requests, hasLength(3));
    preloader.dispose();
    repository.requests.last.complete(null);
    await tester.pump();
  });
}
