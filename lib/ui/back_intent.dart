import 'package:flutter/material.dart';

/// 返回意图门控。
///
/// 系统返回一次只应消费一层：关闭子页面（搜索、详情、设置等）时不能顺带
/// 武装“再按一次退出”。路由出栈与外壳 PopScope 回调可能处于同一帧的不同
/// 阶段，回调里读到的导航状态未必已经稳定，所以记时间戳 + 帧末复查，
/// 而不是在回调里直接推断。
abstract final class BackIntent {
  /// 出栈后这段时间内的返回都只算“关页面”。
  static const settle = Duration(milliseconds: 500);

  static DateTime? _lastPop;

  static void recordPop() => _lastPop = DateTime.now();

  /// 刚关闭过页面时为 false：此时按返回只应关页面，不能武装退出。
  static bool get quietSincePop {
    final last = _lastPop;
    return last == null || DateTime.now().difference(last) > settle;
  }
}

/// 监听根导航器出栈，供 [BackIntent] 记录时间戳。
class BackPopObserver extends NavigatorObserver {
  /// NavigatorObserver 没有 const 构造，这里也不能是 const。
  BackPopObserver();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      BackIntent.recordPop();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      BackIntent.recordPop();
}
