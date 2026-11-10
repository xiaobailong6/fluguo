import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../app_scope.dart';
import 'cover_image.dart';

class CoverBackdrop extends StatelessWidget {
  const CoverBackdrop({
    super.key,
    required this.drama,
    required this.overlay,
    this.sigma = 32,
    this.opacity = 0.85,
  });
  final Drama drama;
  final Gradient overlay;
  final double sigma;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final fallback = ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: Opacity(
            opacity: opacity,
            child: ImageFiltered(
              imageFilter: _blurFilter(sigma),
              child: DramaCover.imagesDisabled || drama.id.isEmpty
                  ? fallback
                  : CoverImage(
                      key: ValueKey('${drama.id}\u0000${drama.cover}'),
                      drama: drama,
                      repository: AppScope.of(context).repository,
                      placeholder: fallback,
                      retryable: false,
                      lowResolution: true,
                    ),
            ),
          ),
        ),
        IgnorePointer(
          child: DecoratedBox(decoration: BoxDecoration(gradient: overlay)),
        ),
      ],
    );
  }
}

/// 按半径缓存模糊滤镜。
///
/// `ImageFilter` 每次新建都会打断滤镜自身的复用：详情页、发现页每次 setState
/// 重建背景都会重造一遍（写法与 `glass_style.dart` 的 `filter` 一致）。
ImageFilter _blurFilter(double sigma) {
  final cached = _blurFilters[sigma];
  if (cached != null) return cached;
  if (_blurFilters.length >= 16) _blurFilters.clear();
  return _blurFilters[sigma] = ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: TileMode.clamp,
  );
}

final _blurFilters = <double, ImageFilter>{};
