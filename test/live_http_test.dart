import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/live_http.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('完整小错误响应正常排空，保留连接复用', () async {
    var aborted = 0;
    await drainLiveErrorResponse(
      Stream.fromIterable([[1, 2], [3]]),
      abort: () => aborted++,
    );
    expect(aborted, 0);
  });

  test('错误响应永不结束时，总时限触发中断和取消订阅', () async {
    var aborted = 0;
    var cancelled = 0;
    final response = StreamController<List<int>>(
      onCancel: () {
        cancelled++;
      },
    );
    final draining = drainLiveErrorResponse(
      response.stream,
      abort: () => aborted++,
      timeout: const Duration(milliseconds: 20),
    );
    response.add([1]);
    await draining.timeout(const Duration(seconds: 2));
    expect(aborted, 1);
    expect(cancelled, 1);
    await response.close();
  });

  test('错误响应超限立即中断，不继续消费响应', () async {
    var aborted = 0;
    var cancelled = 0;
    final response = StreamController<List<int>>(
      onCancel: () {
        cancelled++;
      },
    );
    final draining = drainLiveErrorResponse(
      response.stream,
      abort: () => aborted++,
      maxBytes: 3,
    );
    response.add([1, 2, 3, 4]);
    await draining.timeout(const Duration(seconds: 2));
    expect(aborted, 1);
    expect(cancelled, 1);
    await response.close();
  });

  test('错误响应读取失败时清理连接，不覆盖上层 HTTP 错误', () async {
    var aborted = 0;
    await drainLiveErrorResponse(
      Stream<List<int>>.error(StateError('body failed')),
      abort: () => aborted++,
    );
    expect(aborted, 1);
  });
  test('成功响应按字节边界读取，支持拆开的 UTF8 字符', () async {
    final bytes = utf8.encode('直播');
    final result = await readLiveResponse(
      Stream.fromIterable([bytes.sublist(0, 1), bytes.sublist(1)]),
      maxBytes: bytes.length,
      abort: () => fail('完整响应不应中断'),
    );
    expect(utf8.decode(result), '直播');
    await expectLater(readLiveResponse(
      Stream.value(bytes), maxBytes: bytes.length - 1, abort: () {},
    ), throwsStateError);
  });

  test('持续滴流成功响应仍按总时限取消', () async {
    var aborted = false;
    var cancelled = false;
    final controller = StreamController<List<int>>(onCancel: () { cancelled = true; });
    final timer = Timer.periodic(const Duration(milliseconds: 2), (_) => controller.add([1]));
    try {
      await expectLater(readLiveResponse(controller.stream,
        timeout: const Duration(milliseconds: 30), abort: () { aborted = true; }),
        throwsA(isA<TimeoutException>()));
      expect(aborted, isTrue);
      expect(cancelled, isTrue);
    } finally {
      timer.cancel();
      await controller.close();
    }
  });

  test('获取 request 超时后晚到的 request 必须 abort', () async {
    final opening = Completer<HttpClientRequest>();
    final request = _Request();
    await expectLater(requestLiveResponse(() => opening.future,
      timeout: const Duration(milliseconds: 10)), throwsA(isA<TimeoutException>()));
    opening.complete(request);
    await Future<void>.delayed(Duration.zero);
    expect(request.aborted, isTrue);
    expect(request.closed, isFalse);
  });

  test('等待响应头超时会 abort 已获取请求', () async {
    final request = _Request();
    await expectLater(requestLiveResponse(() async => request,
      timeout: const Duration(milliseconds: 10)), throwsA(isA<TimeoutException>()));
    expect(request.closed, isTrue);
    expect(request.aborted, isTrue);
  });

  test('配置请求失败时，取消产生的 done 错误也被消费', () async {
    final request = _Request();
    await expectLater(
      requestLiveResponse(
        () async => request,
        configure: (_) => throw StateError('配置失败'),
      ),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);
    expect(request.aborted, isTrue);
    expect(request.closed, isFalse);
  });
}

class _Request implements HttpClientRequest {
  bool aborted = false;
  bool closed = false;
  final _done = Completer<HttpClientResponse>();
  @override
  Future<HttpClientResponse> get done => _done.future;
  @override
  void abort([Object? exception, StackTrace? stackTrace]) {
    aborted = true;
    if (!_done.isCompleted) {
      _done.completeError(exception ?? const HttpException('aborted'), stackTrace);
    }
  }
  @override
  Future<HttpClientResponse> close() {
    closed = true;
    return done;
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
