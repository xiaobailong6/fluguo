import 'package:flutter/widgets.dart';

import '../app_scope.dart';

/// 视频宽高比不参与页面选择，避免横屏短剧加载后切换另一套控件。
/// 横向桌面/平板和电视仍保留适合其输入方式的布局。
bool usesPortraitPlayback(
  FormFactor form,
  Size viewport, {
  bool fullscreen = false,
}) =>
    form == FormFactor.phone ||
    (form != FormFactor.television &&
        !fullscreen &&
        viewport.width <= viewport.height);
