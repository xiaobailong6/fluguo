import 'package:duanju_app/ui/app_scope.dart';
import 'package:duanju_app/ui/player/playback_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('桌面全屏期间竖屏显示器不触发布局切换，退出后恢复', () {
    const portrait = Size(1080, 1920);
    const landscape = Size(1920, 1080);
    expect(usesPortraitPlayback(FormFactor.window, landscape), isFalse);
    expect(usesPortraitPlayback(FormFactor.window, portrait, fullscreen: true), isFalse);
    expect(usesPortraitPlayback(FormFactor.window, portrait), isTrue);
  });
  test('手机始终使用统一竖屏控件，视频比例不触发布局切换', () {
    expect(
      usesPortraitPlayback(FormFactor.phone, const Size(390, 844)),
      isTrue,
    );
    expect(
      usesPortraitPlayback(FormFactor.phone, const Size(844, 390)),
      isTrue,
    );
  });
  test('竖向平板和窄窗口使用统一控件，横向与全屏保留专用布局', () {
    for (final form in [FormFactor.pad, FormFactor.window]) {
      expect(usesPortraitPlayback(form, const Size(800, 1200)), isTrue);
      expect(usesPortraitPlayback(form, const Size(1200, 800)), isFalse);
      expect(
        usesPortraitPlayback(form, const Size(800, 1200), fullscreen: true),
        isFalse,
      );
    }
    expect(
      usesPortraitPlayback(FormFactor.television, const Size(800, 1200)),
      isFalse,
    );
  });
}
