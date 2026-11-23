import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 每个分类保留占位的上次布局高度，离屏回收后也能按同一坐标系恢复。
class ExploreHeaderInsetState {
  double? extent;
  double? offset;
}

/// 顶栏收起时真正去掉占位，而不是等待横滑结束后重新显示顶栏遮住空白。
/// 高度变化用 sliver correction 在同一次布局内补偿offset，不发伪造滚动通知。
class ExploreHeaderInset extends LeafRenderObjectWidget {
  const ExploreHeaderInset({
    super.key,
    required this.extent,
    required this.state,
  });

  final double extent;
  final ExploreHeaderInsetState state;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderExploreHeaderInset(extent, state);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant RenderExploreHeaderInset renderObject,
  ) => renderObject.update(extent, state);
}

class RenderExploreHeaderInset extends RenderSliver {
  RenderExploreHeaderInset(this._extent, this._state);

  double _extent;
  ExploreHeaderInsetState _state;
  bool _restore = true;

  void update(double extent, ExploreHeaderInsetState state) {
    if (extent == _extent && identical(state, _state)) return;
    if (!identical(state, _state)) _restore = true;
    _extent = extent;
    _state = state;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    if (_restore) {
      _restore = false;
      final saved = _state.offset;
      // correction不会触发ScrollEnd，PageStorage可能仍保存收起前的旧offset。
      // 恢复实际布局坐标，再按下面的高度差校正，避免每次回到分类多偏移一层顶栏。
      if (saved != null &&
          (saved - constraints.scrollOffset).abs() > precisionErrorTolerance) {
        geometry = SliverGeometry(
          scrollOffsetCorrection: saved - constraints.scrollOffset,
        );
        return;
      }
    }
    final previous = _state.extent;
    _state.extent = _extent;
    if (previous != null &&
        previous != _extent &&
        (previous == 0 || _extent == 0) &&
        constraints.scrollOffset > 0) {
      // 在首屏之外保住当前卡片的屏幕位置；靠近顶部时最多回到0，不生成负offset。
      final correction = math.max(
        -constraints.scrollOffset,
        _extent - previous,
      );
      if (correction.abs() > precisionErrorTolerance) {
        geometry = SliverGeometry(scrollOffsetCorrection: correction);
        return;
      }
    }
    _state.offset = constraints.scrollOffset;
    geometry = SliverGeometry(
      scrollExtent: _extent,
      paintExtent: calculatePaintOffset(constraints, from: 0, to: _extent),
      cacheExtent: calculateCacheOffset(constraints, from: 0, to: _extent),
      maxPaintExtent: _extent,
    );
  }
}
