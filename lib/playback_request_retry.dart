import 'app_failure.dart';

/// 仅对瞬时网络/超时补一次请求。权限、取消、限流以及未知业务失败不重试；
/// 旧切集/旧用户意图失效后不能再发请求或抢占新播放。
Future<T> retryPlaybackRequest<T>(
  Future<T> Function() request, {
  required bool Function() isCurrent,
}) async {
  try {
    return await request();
  } catch (error) {
    final failure = AppFailure.from(error);
    if (!isCurrent() ||
        !const {'network', 'timeout'}.contains(failure.code) ||
        !failure.canRetryAt(DateTime.now())) {
      rethrow;
    }
    return request();
  }
}
