import 'dart:async';
import 'dart:io';

import 'package:duanju_app/app_failure.dart';
import 'package:duanju_app/drama_feed.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/source_catalog.dart';
import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/widgets/failure_recovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  test('错误码、等待时间和旧字符串保持兼容', () {
    final until = DateTime.utc(2030);
    final failure = AppFailure.fromJson({
      'error': '等待',
      'code': 'source_blocked',
      'retryAt': until.toIso8601String(),
    });
    expect(failure.toString(), '等待');
    expect(failure.retryAt, until);
    expect(
      failure.canRetryAt(until.subtract(const Duration(seconds: 1))),
      isFalse,
    );
    expect(failure.canRetryAt(until), isTrue);
    expect(AppFailure.fromJson({'error': '旧错误'}).retryable, isTrue);
    expect(AppFailure.fromJson({'retryAt': 'bad', 'code': 3}).retryAt, isNull);
    expect(AppFailure.from(TimeoutException('secret')).code, 'timeout');
    expect(
      AppFailure.from(const SocketException('secret')).message,
      isNot(contains('secret')),
    );
  });

  test('列表保留类型，失败页不会变成下一页，受限重试不发请求', () async {
    var calls = 0;
    const failure = AppFailure('请登录', code: 'source_login');
    final feed = DramaFeed(
      load: (_, _) async {
        calls++;
        throw failure;
      },
    );
    addTearDown(feed.dispose);
    await feed.reload();
    expect(feed.failure, same(failure));
    await feed.retry();
    expect(calls, 1);
    expect(feed.canLoadMore, isFalse);
  });

  test('部分结果的结构化警告经模型和目录继续保留', () async {
    final page = CatalogPage.fromJson({
      'items': [drama('partial').toJson()],
      'warning': '稍后再试',
      'warningDetails': {
        'code': 'source_blocked',
        'retryAt': '2030-01-01T00:00:00Z',
      },
    });
    final repository = _WarningRepository(page);
    final catalog = SourceCatalog(repository, SourceSite.hongguo);
    final feed = DramaFeed(
      load: (page, _) => catalog.search('partial', page: page),
    );
    addTearDown(feed.dispose);
    await feed.reload();
    expect(feed.items.single.id, 'hongguo:partial');
    expect(feed.failure?.code, 'source_blocked');
    expect(feed.failure?.retryAt, DateTime.utc(2030));
    expect(feed.error, '稍后再试');
  });

  testWidgets('网络错误提供网络设置，长文与大字体无溢出', (tester) async {
    final store = await openStore();
    var retried = 0;
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: Scaffold(
            body: SingleChildScrollView(
              child: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(3)),
                child: FailureRecovery(
                  failure: AppFailure('连接失败 ' * 30, code: 'network'),
                  store: store,
                  source: SourceSite.hongguo,
                  onRetry: () async {
                    retried++;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('网络设置'), findsOneWidget);
    await tester.ensureVisible(find.text('重试'));
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('访客登录失败不提供越权操作或无效重试', (tester) async {
    final store = await openStore(viewerPreferences);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FailureRecovery(
            failure: const AppFailure('请登录', code: 'source_login'),
            store: store,
            source: SourceSite.sorani,
            onRetry: () async {},
          ),
        ),
      ),
    );
    expect(find.text('此站源需要登录，请联系管理员'), findsOneWidget);
    expect(find.text('登录站源'), findsNothing);
    expect(find.text('重试'), findsNothing);
  });

  testWidgets('限流期间禁用重试，销毁清理计时器', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: FailureRecovery(
            failure: AppFailure(
              '稍后再试',
              code: 'source_blocked',
              retryAt: DateTime.now().add(const Duration(hours: 1)),
            ),
            onRetry: () async {
              calls++;
            },
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('重试'));
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
  testWidgets('限流到时自动恢复按钮，不自动发起请求', (tester) async {
    var now = DateTime.utc(2030);
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(
          repository: FakeRepository(),
          formFactor: FormFactor.phone,
          child: child!,
        ),
        home: Scaffold(
          body: FailureRecovery(
            failure: AppFailure(
              '等待',
              code: 'source_blocked',
              retryAt: now.add(const Duration(seconds: 2)),
            ),
            clock: () => now,
            onRetry: () async {
              calls++;
            },
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
          .onPressed,
      isNull,
    );
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '重试'))
          .onPressed,
      isNotNull,
    );
    expect(calls, 0);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
  });
}

class _WarningRepository extends FakeRepository {
  _WarningRepository(this.page);
  final CatalogPage page;
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async => this.page;
}
