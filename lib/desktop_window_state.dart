import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'picture_in_picture.dart';

/// 普通窗口与全屏/PiP 的几何数据分开，防止临时播放窗口污染下次启动。
class DesktopWindowState with WindowListener {
  DesktopWindowState._();
  static final instance = DesktopWindowState._();
  File? _file;
  Timer? _timer;
  int _generation = 0;
  bool _full = false;
  bool _ready = false;
  bool _closing = false;
  Future<void> _writes = Future.value();
  String? _saved;

  static Rect workArea(Display display) =>
      (display.visiblePosition ?? Offset.zero) &
      (display.visibleSize ?? display.size);

  /// 纯几何校验单独公开，便于测试移除显示器、负坐标和无效记录。
  static Rect? restoreBounds(
    Map<String, dynamic> value,
    List<Display> displays,
  ) {
    if (value['version'] != 1) return null;
    final display = displays
        .where((entry) => entry.id == value['display'])
        .firstOrNull;
    if (display == null) return null;
    final numbers = [
      for (final key in ['x', 'y', 'width', 'height']) value[key],
    ];
    if (numbers.any((entry) => entry is! num || !entry.isFinite)) return null;
    final x = (numbers[0] as num).toDouble();
    final y = (numbers[1] as num).toDouble();
    final width = (numbers[2] as num).toDouble();
    final height = (numbers[3] as num).toDouble();
    if (width < 480 || height < 320 || width > 20000 || height > 20000)
      return null;
    final area = workArea(display);
    if (area.width <= 0 || area.height <= 0) return null;
    final w = math.min(width, area.width);
    final h = math.min(height, area.height);
    return Rect.fromLTWH(
      x.clamp(area.left, area.right - w),
      y.clamp(area.top, area.bottom - h),
      w,
      h,
    );
  }

  Future<void> initialize(File file) async {
    if (_ready) return;
    _file = file;
    final displays = await screenRetriever.getAllDisplays();
    Rect? restored;
    for (final candidate in [file, File('${file.path}.bak')]) {
      try {
        if (await candidate.length() > 4096) continue;
        final value = Map<String, dynamic>.from(
          jsonDecode(await candidate.readAsString()) as Map,
        );
        restored = restoreBounds(value, displays);
        // 记录有效但原显示器不在，不使用更旧的显示器记录。
        if (value['version'] == 1) break;
      } catch (_) {}
    }
    if (restored == null) {
      final primary = await screenRetriever.getPrimaryDisplay();
      final area = workArea(primary);
      final size = Size(math.min(1280, area.width), math.min(720, area.height));
      restored = Rect.fromCenter(
        center: area.center,
        width: size.width,
        height: size.height,
      );
    }
    await windowManager.setBounds(restored);
    await windowManager.setPreventClose(true);
    _ready = true;
    windowManager.addListener(this);
    PictureInPicture.instance.addListener(_modeChanged);
    await _capture();
  }

  bool fullScreenRequested(bool value) {
    final previous = _full;
    _full = value;
    _modeChanged();
    return previous;
  }

  void _modeChanged() {
    ++_generation;
    _timer?.cancel();
  }

  void _schedule() {
    if (!_ready || _closing) return;
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 350),
      () => unawaited(_capture()),
    );
  }

  Future<void> _capture() async {
    final generation = _generation;
    if (!_ready ||
        _full ||
        PictureInPicture.instance.shown ||
        PictureInPicture.instance.leaving)
      return;
    try {
      if (await windowManager.isFullScreen() ||
          await windowManager.isMaximized() ||
          await windowManager.isMinimized())
        return;
      final bounds = await windowManager.getBounds();
      final displays = await screenRetriever.getAllDisplays();
      final display = displays
          .where((entry) => workArea(entry).contains(bounds.center))
          .firstOrNull;
      if (generation != _generation ||
          _full ||
          PictureInPicture.instance.shown ||
          display == null)
        return;
      final value = {
        'version': 1,
        'display': display.id,
        'x': bounds.left,
        'y': bounds.top,
        'width': bounds.width,
        'height': bounds.height,
      };
      if (restoreBounds(value, displays) == null) return;
      final text = jsonEncode(value);
      if (text == _saved) return;
      _writes = _writes.catchError((Object _) {}).then((_) async {
        final file = _file!;
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(text, flush: true);
        if (await file.exists()) await file.copy('${file.path}.bak');
        if (await file.exists()) await file.delete();
        await temp.rename(file.path);
        _saved = text;
      });
      await _writes;
    } catch (_) {
      /* 窗口偏好保存失败不能阻止使用和退出。 */
    }
  }

  @override
  void onWindowMove() => _schedule();
  @override
  void onWindowResize() => _schedule();
  @override
  void onWindowMaximize() => _modeChanged();
  @override
  void onWindowMinimize() => _modeChanged();
  @override
  void onWindowEnterFullScreen() {
    _full = true;
    _modeChanged();
  }

  @override
  void onWindowLeaveFullScreen() {
    _full = false;
    _modeChanged();
  }

  @override
  void onWindowClose() {
    if (_closing) return;
    _closing = true;
    _timer?.cancel();
    unawaited(() async {
      await _capture();
      await _writes.catchError((Object _) {});
      await windowManager.destroy();
    }());
  }
}
