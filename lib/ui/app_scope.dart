import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../core_bridge.dart';

enum FormFactor { phone, pad, window, television }

const televisionInset = 58.0;

/// 浮动底栏里单个 tab 的高度。
const tabItemHeight = 52.0;

/// 浮动底栏胶囊的内边距（上下左右一致）。
const tabBarPadding = 6.0;

/// 浮动底栏胶囊的总高度。
const tabBarHeight = tabItemHeight + tabBarPadding * 2;

/// 浮动底栏与屏幕底边之间的留白。
const tabBarGap = 10.0;

/// 页面内容需要为浮动底栏额外让出的高度（不含系统安全区）。
const tabBarInset = tabBarHeight + tabBarGap;

/// 当前形态下内容底部需要额外留出的高度。
///
/// 包含系统安全区：页面若用 `SafeArea(bottom: false)`，安全区仍留在
/// MediaQuery 里，这里补上；若已被 SafeArea 吃掉（值为 0），则视口本身
/// 已经缩了那么多，加起来正好都是「物理底边到胶囊顶部」的距离。
double bottomBarInset(BuildContext context) =>
    AppScope.formFactorOf(context) == FormFactor.phone
    ? tabBarInset + MediaQuery.paddingOf(context).bottom
    : 0;

bool get desktopPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.windows ||
  TargetPlatform.macOS ||
  TargetPlatform.linux => true,
  _ => false,
};

class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.repository,
    this.formFactor,
    this.systemColorAvailable = false,
    this.glass = true,
    this.version = '',
    required super.child,
  });
  final AppRepository repository;
  final FormFactor? formFactor;
  final bool systemColorAvailable;

  /// 用户是否开启液态玻璃外观。
  ///
  /// 关闭后所有玻璃件退化为不透明容器，电视形态也会强制关闭，
  /// 这是低端设备掉帧时的唯一逃生舱，务必保留。
  final bool glass;
  final String version;

  bool get television => formFactor == FormFactor.television;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  static FormFactor formFactorOf(BuildContext context) {
    if (of(context).formFactor case final form?) return form;
    final size = MediaQuery.sizeOf(context);
    if (desktopPlatform) {
      return size.width >= 600 ? FormFactor.window : FormFactor.phone;
    }
    return size.shortestSide >= 600 ? FormFactor.pad : FormFactor.phone;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      repository != oldWidget.repository ||
      formFactor != oldWidget.formFactor ||
      systemColorAvailable != oldWidget.systemColorAvailable ||
      glass != oldWidget.glass ||
      version != oldWidget.version;
}
