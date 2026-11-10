import 'dart:async';

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
}
