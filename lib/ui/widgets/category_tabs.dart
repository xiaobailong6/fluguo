import 'package:flutter/material.dart';

import '../app_scope.dart';
import '../app_motion.dart';
import 'glass/glass_feedback.dart';
import 'bar_button.dart';
import 'choice_panel.dart';
import 'focus_ring.dart';

class CategoryTabs<T> extends StatefulWidget {
  const CategoryTabs({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.onShowAll,
  });
  final List<ChoiceOption<T>> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final void Function(BuildContext anchor)? onShowAll;

  @override
  State<CategoryTabs<T>> createState() => _CategoryTabsState<T>();
}

class _CategoryTabsState<T> extends State<CategoryTabs<T>> {
  final _scroll = ScrollController();
  final _keys = <T, GlobalKey>{};
  final _row = GlobalKey();
  bool _overflows = false;
  Rect? _indicator;
  bool _sliding = false;

  @override
  void didUpdateWidget(covariant CategoryTabs<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _reveal() {
    final context = _keys[widget.selected]?.currentContext;
    if (context == null || !mounted) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
      duration: AppMotion.duration(context, AppMotion.enter),
      curve: AppMotion.curve,
    );
  }

  /// 量出当前选中项在整条分类栏里的位置，下划线据此滑动。
  ///
  /// 之前是每个 tab 自带一条下划线，切换时只能原地淡入淡出；改成整条栏
  /// 共用一条后，下划线会从旧位置滑到新位置。
  void _measure(double inset) {
    if (!mounted) return;
    final tab = _keys[widget.selected]?.currentContext?.findRenderObject();
    final row = _row.currentContext?.findRenderObject();
    if (tab is! RenderBox || row is! RenderBox || !tab.attached) return;
    final origin = tab.localToGlobal(Offset.zero, ancestor: row);
    final rect = Rect.fromLTWH(
      origin.dx + inset,
      0,
      tab.size.width - inset * 2,
      0,
    );
    if (rect == _indicator) return;
    setState(() {
      _sliding = _indicator != null;
      _indicator = rect;
    });
  }

  bool _metricsChanged(ScrollMetricsNotification notification) {
    final overflows = notification.metrics.maxScrollExtent > 0;
    if (overflows != _overflows) setState(() => _overflows = overflows);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final form = AppScope.formFactorOf(context);
    final colors = Theme.of(context).colorScheme;
    final (height, fontSize, padding, fade) = switch (form) {
      FormFactor.phone => (48.0, 15.0, 12.0, 32.0),
      FormFactor.pad || FormFactor.window => (48.0, 14.0, 14.0, 40.0),
      FormFactor.television => (44.0, 16.0, 16.0, 48.0),
    };
    _keys.removeWhere(
      (value, _) => !widget.options.any((option) => option.value == value),
    );
    final television = form == FormFactor.television;
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure(padding));
    final indicator = _indicator;
    final showAll = switch (widget.onShowAll) {
      final onShowAll? when _overflows => Padding(
        padding: EdgeInsets.only(right: television ? 10 : 0),
        child: Builder(
          builder: (anchor) => BarButton(
            icon: Icons.grid_view_rounded,
            tooltip: '全部分类',
            onPressed: () => onShowAll(anchor),
          ),
        ),
      ),
      _ => null,
    };
    return Container(
      height: height,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          if (television) ?showAll,
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // 用 SingleChildScrollView + Row 而不是 ListView：需要按整条栏的
                // 坐标系量出下划线位置，懒加载列表拿不到视口外的子项。
                final list = NotificationListener<ScrollMetricsNotification>(
                  onNotification: _metricsChanged,
                  child: SingleChildScrollView(
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.only(
                      left: form == FormFactor.phone ? 4 : 0,
                    ),
                    child: Stack(
                      key: _row,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final option in widget.options)
                              KeyedSubtree(
                                key: _keys.putIfAbsent(
                                  option.value,
                                  GlobalKey.new,
                                ),
                                child: _Tab(
                                  label: option.label,
                                  selected: option.value == widget.selected,
                                  fontSize: fontSize,
                                  padding: padding,
                                  onTap: () => widget.onSelected(option.value),
                                ),
                              ),
                          ],
                        ),
                        if (indicator != null)
                          AnimatedPositioned(
                            duration: _sliding
                                ? AppMotion.duration(context, AppMotion.state)
                                : Duration.zero,
                            curve: AppMotion.curve,
                            left: indicator.left,
                            width: indicator.width,
                            bottom: 0,
                            height: 3,
                            child: IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: colors.primary,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
                if (!_overflows) return list;
                // 用遮罩让右端内容自己淡出，而不是盖一块纯色：顶栏玻璃化之后，
                // 那块纯色遮罩在胶囊上就是一块不透明的白色方块。
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (rect) => LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: const [
                      Colors.black,
                      Colors.black,
                      Colors.transparent,
                    ],
                    stops: [
                      0,
                      (1 - fade / constraints.maxWidth).clamp(0.0, 1.0),
                      1,
                    ],
                  ).createShader(rect),
                  child: list,
                );
              },
            ),
          ),
          if (!television) ?showAll,
        ],
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.padding,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final double fontSize;
  final double padding;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: GlassFeedback(
        radius: 8,
        child: FocusRing(
          radius: 8,
          offset: -3,
          child: InkWell(
            onTap: onTap,
            focusColor: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              child: Center(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? colors.onSurface : colors.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
