import 'dart:async';
import 'dart:io';

/// 跨仓库、列表与界面保留错误码，不通过中文错误文本猜测恢复动作。
class AppFailure implements Exception {
  const AppFailure(this.message, {this.code = '', this.retryAt});

  final String message;
  final String code;
  final DateTime? retryAt;

  factory AppFailure.fromJson(Map<String, dynamic> value) => AppFailure(
    value['error'] is String ? value['error'] as String : '读取失败，请重试',
    code: value['code'] is String ? value['code'] as String : '',
    retryAt: value['retryAt'] is String
        ? DateTime.tryParse(value['retryAt'] as String)
        : null,
  );

  factory AppFailure.from(Object error) {
    if (error is AppFailure) return error;
    if (error is TimeoutException) {
      return const AppFailure('连接超时，请稍后重试', code: 'timeout');
    }
    if (error is SocketException || error is HttpException) {
      return const AppFailure('无法连接站源，请检查网络', code: 'network');
    }
    return AppFailure(error.toString());
  }

  bool get retryable => !const {
    'source_login',
    'permission',
    'source_unavailable',
    'protocol_mismatch',
    'core_unavailable',
    'invalid_request',
    'cancelled',
  }.contains(code);

  bool canRetryAt(DateTime now) =>
      retryable && (retryAt == null || !now.isBefore(retryAt!));

  @override
  String toString() => message;
}
