import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_motion.dart';
import 'glass/glass_popup_transition.dart';
import '../app_scope.dart';
import '../theme/glass_style.dart';
import 'glass/glass_feedback.dart';
import 'focus_ring.dart';
import 'glass/glass_surface.dart';

class ChoiceOption<T> {
  const ChoiceOption(this.value, this.label);
  final T value;
  final String label;
}

class ChoiceGrid {
  const ChoiceGrid({
    required this.phone,
    required this.wide,
    required this.television,
    required this.wideWidth,
    required this.televisionWidth,
  });
  final int phone;
  final int wide;
  final int television;
  final double wideWidth;
  final double televisionWidth;

  static const sources = ChoiceGrid(
    phone: 3,
    wide: 3,
    television: 2,
    wideWidth: 420,
    televisionWidth: 400,
  );
  static const categories = ChoiceGrid(
    phone: 4,
    wide: 5,
    television: 4,
    wideWidth: 520,
    televisionWidth: 440,
  );
}

typedef ChoiceAction = ({String label, IconData icon, VoidCallback onPressed});

/// 选择弹窗专用的「更透」玻璃：模糊加厚、染色减薄，更接近液态玻璃。
///
/// 压在整页内容上时透视感来自背景模糊而不是厚染色；电视端或用户关闭
/// 玻璃时解析结果本身就是不透明档，[GlassStyle.thinned] 会原样返回。
GlassStyle _thinnedPanelStyle(BuildContext context) {
  final base = GlassStyleResolver.of(context, role: GlassRole.panel);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final reduced = base.tier == GlassTier.reduced;
  return base.thinned(
    tintAlpha: reduced ? (dark ? .76 : .72) : (dark ? .68 : .64),
    blurSigma: reduced ? 14 : 24,
  );
}

Future<T?> showChoicePanel<T>({
  required BuildContext context,
  required String title,
  required List<ChoiceOption<T>> options,
  required T? selected,
  required ChoiceGrid grid,
  ChoiceAction? action,
}) {
  final form = AppScope.formFactorOf(context);
  Widget panel(BuildContext context) => _ChoicePanel<T>(
    form: form,
    title: title,
    options: options,
    selected: selected,
    columns: switch (form) {
      FormFactor.phone => grid.phone,
      FormFactor.pad || FormFactor.window => grid.wide,
      FormFactor.television => grid.television,
    },
    action: action,
  );
  final navigator = Navigator.of(context, rootNavigator: true);
  switch (form) {
    case FormFactor.phone:
    case FormFactor.pad:
    case FormFactor.window:
      // 三种形态统一用锚定弹窗：纯淡入淡出，从触发按钮下方展开，
      // 不再使用底部滑出面板，避免与底栏按钮相互闪烁。
      final overlay =
          navigator.overlay!.context.findRenderObject()! as RenderBox;
      final anchor = context.findRenderObject()! as RenderBox;
      final rect =
          anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
      return navigator.push(
        GlassPopupRoute<T>(
          context: context,
          barrierColor: form == FormFactor.phone ? Colors.black26 : null,
          builder: (context, animation) => GlassAnchoredPopup(
            anchor: rect,
            width: form == FormFactor.phone
                ? math.min(grid.wideWidth, 480.0)
                : grid.wideWidth,
            // 限制高度：选项多时在弹窗内上下滚动，不再撑满整屏。
            maxHeight: form == FormFactor.phone ? 420 : 520,
            animation: animation,
            child: GlassSurface(
              role: GlassRole.panel,
              style: _thinnedPanelStyle(context),
              radius: GlassRadius.card,
              child: panel(context),
            ),
          ),
        ),
      );
    case FormFactor.television:
      return Navigator.of(context, rootNavigator: true).push(
        GlassPopupRoute<T>(
          context: context,
          barrierColor: Colors.black54,
          builder: (context, animation) => Align(
            alignment: Alignment.centerRight,
            child: GlassPopupTransition(
              animation: animation,
              offset: const Offset(4, 0),
              child: GlassSurface(
                role: GlassRole.panel,
                style: _thinnedPanelStyle(context),
                child: SizedBox(
                  width: grid.televisionWidth,
                  height: double.infinity,
                  child: panel(context),
                ),
              ),
            ),
          ),
        ),
      );
  }
}

class _ChoicePanel<T> extends StatelessWidget {
  const _ChoicePanel({
    required this.form,
    required this.title,
    required this.options,
    required this.selected,
    required this.columns,
    required this.action,
  });
  final FormFactor form;
  final String title;
  final List<ChoiceOption<T>> options;
  final T? selected;
  final int columns;
  final ChoiceAction? action;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final colors = Theme.of(context).colorScheme;
    final television = form == FormFactor.television;
    final spacing = television ? 12.0 : 8.0;
    final header = Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: (television ? text.headlineSmall : text.titleLarge)
                    ?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: television || form == FormFactor.phone
                          ? null
                          : 17,
                    ),
              ),
              Text(
                '${options.length} 个',
                style: (television ? text.bodyMedium : text.bodySmall)
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        if (form == FormFactor.phone)
          IconButton(
            tooltip: '关闭',
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close_rounded),
          ),
      ],
    );
    return Padding(
      padding: switch (form) {
        FormFactor.phone => const EdgeInsets.fromLTRB(16, 16, 4, 20),
        FormFactor.pad ||
        FormFactor.window => const EdgeInsets.fromLTRB(16, 20, 16, 12),
        FormFactor.television => const EdgeInsets.fromLTRB(32, 36, 48, 32),
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          SizedBox(height: television ? 20 : 12),
          Flexible(
            child: Padding(
              padding: EdgeInsets.only(
                right: form == FormFactor.phone ? 12 : 0,
              ),
              child: GridView.builder(
                shrinkWrap: true,
                padding: EdgeInsets.all(television ? 12 : 6),
                itemCount: options.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: spacing,
                  crossAxisSpacing: spacing,
                  // 字号放大后仍保留上下留白，不把文字裁在固定高度里。
                  mainAxisExtent: math.max(
                    switch (form) {
                      FormFactor.phone => 44.0,
                      FormFactor.pad || FormFactor.window => 36.0,
                      FormFactor.television => 48.0,
                    },
                    MediaQuery.textScalerOf(
                          context,
                        ).scale(television ? 15 : 14) +
                        20,
                  ),
                ),
                itemBuilder: (context, index) => _ChoiceCell<T>(
                  option: options[index],
                  selected: options[index].value == selected,
                  form: form,
                ),
              ),
            ),
          ),
          if (action case final action?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FocusRing(
                radius: 999,
                child: TextButton.icon(
                  onPressed: () {
                    Navigator.pop(context);
                    action.onPressed();
                  },
                  icon: Icon(action.icon),
                  label: Text(action.label),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChoiceCell<T> extends StatelessWidget {
  const _ChoiceCell({
    required this.option,
    required this.selected,
    required this.form,
  });
  final ChoiceOption<T> option;
  final bool selected;
  final FormFactor form;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = switch (form) {
      FormFactor.phone => 12.0,
      FormFactor.pad || FormFactor.window => 10.0,
      FormFactor.television => 14.0,
    };
    return GlassFeedback(
      radius: radius,
      child: FocusRing(
        radius: radius,
        child: Material(
          animationDuration: AppMotion.duration(context, AppMotion.state),
          color: selected ? colors.secondaryContainer : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: selected
                ? BorderSide.none
                // outline 在亮/暗主题均比 outlineVariant 更清晰。
                : BorderSide(color: colors.outline, width: 1.5),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            autofocus: selected,
            focusColor: Colors.transparent,
            onTap: () => Navigator.pop(context, option.value),
            child: Semantics(
              selected: selected,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    option.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: form == FormFactor.television ? 15 : 14,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected
                          ? colors.onSecondaryContainer
                          : colors.onSurface,
                    ),
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
