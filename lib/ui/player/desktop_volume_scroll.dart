import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// 透明画面输入层；应放在进度条、选集列表等控件的下方而非包裹整页。
class DesktopVolumeScroll extends StatelessWidget {
  const DesktopVolumeScroll({
    super.key,
    required this.child,
    required this.readVolume,
    required this.onVolumeChanged,
    this.enabled = true,
    this.locked = false,
  });

  final Widget child;
  final double Function() readVolume;
  final ValueChanged<double> onVolumeChanged;
  final bool enabled;
  final bool locked;

  /// 同时供画面的鼠标右键使用，后台和被弹窗覆盖时不执行操作。
  static bool active(BuildContext context) {
    if (kIsWeb ||
        !{
          TargetPlatform.windows,
          TargetPlatform.macOS,
          TargetPlatform.linux,
        }.contains(defaultTargetPlatform)) {
      return false;
    }
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    return (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        ModalRoute.of(context)?.isCurrent == true;
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.opaque,
    onPointerSignal: (event) {
      if (!enabled ||
          locked ||
          !active(context) ||
          event is! PointerScrollEvent ||
          event.kind != PointerDeviceKind.mouse ||
          !event.scrollDelta.dy.isFinite ||
          event.scrollDelta.dy == 0) {
        return;
      }
      // 命中测试先到子控件：子 Scrollable 已登记时，本层不能抢走滚动。
      GestureBinding.instance.pointerSignalResolver.register(event, (_) {
        if (!context.mounted || !active(context)) return;
        final volume = readVolume();
        if (!volume.isFinite) return;
        final next = (volume + (event.scrollDelta.dy < 0 ? 5 : -5)).clamp(
          0.0,
          100.0,
        );
        onVolumeChanged(next);
      });
    },
    child: child,
  );
}
