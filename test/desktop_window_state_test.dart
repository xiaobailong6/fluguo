import 'package:duanju_app/desktop_window_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_retriever/screen_retriever.dart';

void main() {
  const displays = [
    Display(
      id: 'primary',
      size: Size(1920, 1080),
      visiblePosition: Offset.zero,
      visibleSize: Size(1920, 1040),
    ),
    Display(
      id: 'left',
      size: Size(1280, 1024),
      visiblePosition: Offset(-1280, 0),
      visibleSize: Size(1280, 984),
    ),
  ];
  final value = <String, dynamic>{
    'version': 1,
    'display': 'left',
    'x': -1200,
    'y': 50,
    'width': 1000,
    'height': 700,
  };
  test('普通窗口保留负坐标显示器位置', () {
    expect(
      DesktopWindowState.restoreBounds(value, displays),
      const Rect.fromLTWH(-1200, 50, 1000, 700),
    );
  });
  test('原显示器不在时回退默认位置而不是恢复到屏幕外', () {
    expect(DesktopWindowState.restoreBounds(value, [displays.first]), isNull);
  });
  test('工作区缩小时约束位置与大小，损坏或小窗尺寸不接受', () {
    expect(
      DesktopWindowState.restoreBounds({
        ...value,
        'x': -9999,
        'width': 1800,
      }, displays),
      const Rect.fromLTWH(-1280, 50, 1280, 700),
    );
    expect(
      DesktopWindowState.restoreBounds({...value, 'x': double.nan}, displays),
      isNull,
    );
    expect(
      DesktopWindowState.restoreBounds({
        ...value,
        'width': 320,
        'height': 180,
      }, displays),
      isNull,
    );
    expect(
      DesktopWindowState.restoreBounds({...value, 'version': 2}, displays),
      isNull,
    );
  });
}
