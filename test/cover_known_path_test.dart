import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/native_request_pool.dart';
import 'package:duanju_app/ui/widgets/cover_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const _placeholder = ValueKey('cover-placeholder');

class _PendingRepository extends FakeRepository {
  final known = <String, String>{};
  final requests = <({Drama drama, bool force, Completer<String> result})>[];

  String key(Drama drama) => '${drama.source}:${drama.id}:${drama.cover}';
  @override
  String? knownCover(Drama drama) => known[key(drama)];
  @override
  bool coverCached(Drama drama) => true;
  @override
  Future<String> cover(Drama drama, {bool force = false}) {
    final result = Completer<String>();
    requests.add((drama: drama, force: force, result: result));
    return result.future;
  }
}

class _Worker implements NativeRequestWorker {
  _Worker(this.run);
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) run;
  final _dead = Completer<void>();
  @override
  Future<void> get dead => _dead.future;
  @override
  Future<Map<String, dynamic>> execute(String body) =>
      run(jsonDecode(body) as Map<String, dynamic>);
}

NativeRepository _native(
  Future<Map<String, dynamic>> Function(Map<String, dynamic>) run,
) => NativeRepository(
  dispatcher: NativeRequestDispatcher(() async => _Worker(run), concurrency: 2),
);

Map<String, dynamic> _path(String path) => {
  'ok': true,
  'data': {'path': path},
};

Widget _cover(AppRepository repository, Drama item) => MaterialApp(
  home: Center(
    child: SizedBox(
      width: 150,
      height: 240,
      child: MediaQuery(
        data: const MediaQueryData(devicePixelRatio: 1),
        child: CoverImage(
          repository: repository,
          drama: item,
          placeholder: const SizedBox.expand(key: _placeholder),
        ),
      ),
    ),
  ),
);

String _imagePath(WidgetTester tester) =>
    ((tester.widget<Image>(find.byType(Image)).image as ResizeImage)
                .imageProvider
            as FileImage)
        .file
        .path;

// 在内存中生成并预热一个像素，不访问网络或真实媒体文件。
Future<void> _warmImage(WidgetTester tester, String path) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawColor(Colors.red, BlendMode.src);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(1, 1);
  picture.dispose();
  final key = await ResizeImage.resizeIfNeeded(
    192,
    null,
    FileImage(File(path)),
  ).obtainKey(ImageConfiguration.empty);
  tester.binding.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image))),
  );
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('默认仓库没有同步封面提示', () {
    expect(FakeRepository().knownCover(drama('default')), isNull);
  });

  testWidgets('热缓存首帧直接挂载图片，异步完成和普通重建复用同一个Image', (tester) async {
    final repository = _PendingRepository();
    final item = drama('warm');
    repository.known[repository.key(item)] = 'warm-cover.png';
    await _warmImage(tester, 'warm-cover.png');
    await tester.pumpWidget(_cover(repository, item));
    expect(find.byKey(_placeholder), findsNothing);
    expect(_imagePath(tester), 'warm-cover.png');
    expect(tester.widget<RawImage>(find.byType(RawImage)).image, isNotNull);
    final image = tester.widget<Image>(find.byType(Image));
    expect(repository.requests.single.result.isCompleted, isFalse);
    await tester.pumpWidget(_cover(repository, item));
    expect(identical(tester.widget<Image>(find.byType(Image)), image), isTrue);
    repository.requests.single.result.complete('warm-cover.png');
    await tester.pump();
    expect(identical(tester.widget<Image>(find.byType(Image)), image), isTrue);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('清理通知立即撤下已完成图片，不用旧提示或旧Future回填', (tester) async {
    final repository = _PendingRepository();
    final item = drama('clear');
    repository.known[repository.key(item)] = 'old-clear.png';
    await _warmImage(tester, 'old-clear.png');
    await tester.pumpWidget(_cover(repository, item));
    repository.requests.single.result.complete('old-clear.png');
    await tester.pump();
    // 故意保留 fake 的旧提示，验证 widget 清理后不会再用它作 initialData。
    repository.cacheChanges.value++;
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(_placeholder), findsOneWidget);
    await _warmImage(tester, 'new-clear.png');
    repository.requests.last.result.complete('new-clear.png');
    await tester.pump();
    await tester.pump();
    expect(_imagePath(tester), 'new-clear.png');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('强制重试挂起时不能显示旧提示，旧请求晚到也不能回填', (tester) async {
    final repository = _PendingRepository();
    final item = drama('retry');
    repository.known[repository.key(item)] = 'old-retry.png';
    await _warmImage(tester, 'old-retry.png');
    await tester.pumpWidget(_cover(repository, item));
    final image = tester.widget<Image>(find.byType(Image));
    final failure =
        image.errorBuilder!(
              tester.element(find.byType(Image)),
              StateError('synthetic decode failure'),
              null,
            )
            as Center;
    (failure.child! as IconButton).onPressed!();
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(find.byKey(_placeholder), findsOneWidget);
    expect(repository.requests.last.force, isTrue);
    repository.requests.first.result.complete('old-retry.png');
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await _warmImage(tester, 'new-retry.png');
    repository.requests.last.result.complete('new-retry.png');
    await tester.pump();
    await tester.pump();
    expect(_imagePath(tester), 'new-retry.png');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('切剧、同ID换源、换仓库时不继承旧snapshot或热缓存', (tester) async {
    final repository = _PendingRepository();
    final first = drama('switch');
    repository.known[repository.key(first)] = 'old-switch.png';
    await _warmImage(tester, 'old-switch.png');
    await tester.pumpWidget(_cover(repository, first));
    final second = drama('second');
    await tester.pumpWidget(_cover(repository, second));
    expect(find.byType(Image), findsNothing);
    repository.requests.first.result.complete('old-switch.png');
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await _warmImage(tester, 'second.png');
    repository.requests.last.result.complete('second.png');
    await tester.pump();
    await tester.pump();
    expect(_imagePath(tester), 'second.png');
    final otherSource = Drama(id: second.id, source: 'sorani', title: 'other');
    await tester.pumpWidget(_cover(repository, otherSource));
    expect(find.byType(Image), findsNothing);
    final otherRepository = _PendingRepository();
    await tester.pumpWidget(_cover(otherRepository, otherSource));
    repository.requests.last.result.complete('wrong-source.png');
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await _warmImage(tester, 'correct.png');
    otherRepository.requests.single.result.complete('correct.png');
    await tester.pump();
    await tester.pump();
    expect(_imagePath(tester), 'correct.png');
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  test('同步提示按来源、身份、权限和缓存清理屏障隔离', () async {
    final item = drama('native-known');
    final clear = Completer<Map<String, dynamic>>();
    final repository = _native(
      (input) async => input['action'] == 'clearCache'
          ? clear.future
          : _path('native-known.png'),
    );
    final store = await openStore(viewerPreferences);
    repository.access = store;
    await repository.cover(item);
    expect(repository.knownCover(item), 'native-known.png');
    expect(
      repository.knownCover(Drama(id: item.id, source: 'sorani', title: '')),
      isNull,
    );
    expect(
      repository.knownCover(Drama(id: item.id, source: 'unknown', title: '')),
      isNull,
    );
    repository.access = await openStore();
    expect(repository.knownCover(item), isNull);
    await repository.cover(item);
    final clearing = repository.clearCache();
    expect(repository.knownCover(item), isNull);
    await pumpEventQueue();
    clear.complete({'ok': true, 'data': <String, dynamic>{}});
    await clearing;
    expect(repository.knownCover(item), isNull);
  });

  test('删除的缓存文件仍经异步exists核对并回退原生加载', () async {
    var calls = 0;
    final item = drama('deleted-known');
    final repository = _native((_) async {
      calls++;
      return _path(
        calls == 1 ? 'deleted-cover-never-existed.png' : 'replacement.png',
      );
    });
    expect(await repository.cover(item), 'deleted-cover-never-existed.png');
    expect(repository.knownCover(item), 'deleted-cover-never-existed.png');
    expect(await repository.cover(item), 'replacement.png');
    expect(calls, 2);
    expect(repository.knownCover(item), 'replacement.png');
  });

  test('强制请求失败会撤销已知路径，不能复活旧缓存', () async {
    final retry = Completer<Map<String, dynamic>>();
    final repository = _native(
      (input) async =>
          input['force'] == true ? retry.future : _path('forced-old.png'),
    );
    final item = drama('native-retry');
    await repository.cover(item);
    final failed = expectLater(
      repository.cover(item, force: true),
      throwsA(isA<AppFailure>()),
    );
    expect(repository.knownCover(item), isNull);
    retry.complete({'ok': false, 'error': 'synthetic failure'});
    await failed;
    expect(repository.knownCover(item), isNull);
  });

  test('强制重试使旧在途请求失效，旧响应晚到不覆盖新提示', () async {
    final old = Completer<Map<String, dynamic>>();
    final repository = _native(
      (input) async =>
          input['force'] == true ? _path('forced-fresh.png') : old.future,
    );
    final item = drama('native-force-race');
    final stale = expectLater(
      repository.cover(item),
      throwsA(isA<AppFailure>()),
    );
    await pumpEventQueue();
    expect(await repository.cover(item, force: true), 'forced-fresh.png');
    old.complete(_path('forced-stale.png'));
    await stale;
    expect(repository.knownCover(item), 'forced-fresh.png');
  });

  testWidgets('Native清理屏障开始即撤图，不必等清理完成通知', (tester) async {
    final clear = Completer<Map<String, dynamic>>();
    final repository = _native(
      (input) async => input['action'] == 'clearCache'
          ? clear.future
          : _path('native-clear-widget.png'),
    );
    final item = drama('native-clear-widget');
    await tester.runAsync(() => repository.cover(item));
    await tester.pumpWidget(_cover(repository, item));
    expect(find.byType(Image), findsOneWidget);
    final clearing = repository.clearCache();
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(repository.knownCover(item), isNull);
    var finished = false;
    clearing.then((_) => finished = true);
    clear.complete({'ok': true, 'data': <String, dynamic>{}});
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(finished, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  test('清理开始后在途封面不能重新登记旧路径', () async {
    final response = Completer<Map<String, dynamic>>();
    final repository = _native(
      (input) async => input['action'] == 'cover'
          ? response.future
          : {'ok': true, 'data': <String, dynamic>{}},
    );
    final item = drama('clear-race');
    final stale = expectLater(
      repository.cover(item),
      throwsA(isA<AppFailure>()),
    );
    await pumpEventQueue();
    final clearing = repository.clearCache();
    response.complete(_path('stale-clear.png'));
    await stale;
    await clearing;
    expect(repository.knownCover(item), isNull);
  });

  testWidgets('权限通知撤下热缓存首帧，用户切换后迟到响应不泄露', (tester) async {
    final profiles = {
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: 'Admin',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: 'Viewer',
          sources: ['hongguo'],
        ).toJson(),
        const LocalProfile(
          id: 'blocked',
          name: 'Blocked',
          sources: [],
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
    };
    final store = await tester.runAsync(() => openStore(profiles));
    final pending = Completer<Map<String, dynamic>>();
    var calls = 0;
    final repository = _native(
      (_) async => ++calls == 1 ? _path('permission-old.png') : pending.future,
    )..access = store;
    final item = drama('permissions');
    await tester.runAsync(() => repository.cover(item));
    await tester.pumpWidget(_cover(repository, item));
    expect(_imagePath(tester), 'permission-old.png');
    await tester.runAsync(() => pumpEventQueue());
    await tester.runAsync(() => store!.switchProfile('blocked'));
    expect(repository.knownCover(item), isNull);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    pending.complete(_path('permission-late.png'));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump(const Duration(milliseconds: 160));
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(repository.knownCover(item), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('锁定通知撤下已完成图片；替换access后重新订阅新用户', (tester) async {
    final repository = _native((_) async => _path('locked-cover.png'));
    final item = drama('lock-notification');
    await tester.pumpWidget(_cover(repository, item));
    await tester.pump(const Duration(milliseconds: 160));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(_imagePath(tester), 'locked-cover.png');
    final store = await tester.runAsync(
      () => openStore({
        ...viewerPreferences,
        'activeProfile': 'default',
        'forceLogin': false,
      }),
    );
    repository.access = store;
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await tester.pump(const Duration(milliseconds: 160));
    await tester.runAsync(() => pumpEventQueue());
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    store!.lock();
    expect(repository.knownCover(item), isNull);
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
