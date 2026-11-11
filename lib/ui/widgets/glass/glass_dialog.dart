import 'package:flutter/material.dart';

import '../../theme/glass_style.dart';
import 'glass_popup_transition.dart';
import 'glass_surface.dart';

/// 全应用统一的液态玻璃对话框。
///
/// 代替 `showDialog` + `AlertDialog`：外观、圆角、染色、退场时序只在这里定义
/// 一次，各页面不再各自拼 Material 不透明底。返回值和 `showDialog` 一致，
/// 点击遮罩、返回键的行为也由 [GlassPopupRoute] 保留。
Future<T?> showGlassDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  double maxWidth = 460,
}) {
  final screen = MediaQuery.sizeOf(context);
  return Navigator.of(context, rootNavigator: true).push(
    GlassPopupRoute<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .45),
      dismissible: dismissible,
      builder: (context, animation) => GlassPopupTransition(
        animation: animation,
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: screen.height * .82,
                ),
                child: GlassSurface(
                  role: GlassRole.panel,
                  radius: GlassRadius.dialog,
                  style: GlassStyleResolver.preset(
                    context,
                    GlassPreset.dialog,
                  ),
                  child: Builder(builder: builder),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 玻璃对话框的内容骨架：标题、可选正文/自定义内容、右下角操作按钮。
///
/// 只负责排版与滚动；焦点顺序、返回值由调用方给的动作决定。内容超高时
/// 正文在内部滚动，按钮始终可见。
class GlassDialogBody extends StatelessWidget {
  const GlassDialogBody({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.actions = const <Widget>[],
    this.titleStyle,
    this.scrollController,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<Widget> actions;

  /// 少数页面需要额外强调（例如删除确认），默认取 `titleMedium`。
  final TextStyle? titleStyle;

  /// 正文滚动控制器：长内容页（如剧情简介）需要自己的方向键滚动时传入。
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final message = this.message;
    final content = this.content;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: titleStyle ??
                theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          if (message != null || content != null)
            Flexible(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: content ??
                      Text(
                        message!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                ),
              ),
            ),
          // 进度型弹窗没有按钮，不留底部空档。
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 14),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: actions,
            ),
          ],
        ],
      ),
    );
  }
}
