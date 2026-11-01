import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_motion.dart';
import '../widgets/glass/glass_popup_transition.dart';
import '../theme/app_theme.dart';

ThemeData playerTheme(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.dark
      ? theme
      : AppTheme.build(
          theme.colorScheme.primary,
          Brightness.dark,
          television: false,
        );
}

Future<void> showPlayerSheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final height = MediaQuery.sizeOf(context).height * .6;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    sheetAnimationStyle: AppMotion.sheet(context),
    backgroundColor: theme.colorScheme.surfaceContainerLow,
    constraints: BoxConstraints.tightFor(height: height),
    builder: (context) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: Builder(builder: builder),
      ),
    ),
  );
}

/// 屏幕正中央的悬浮菜单。
///
/// 播放设置原来走 [showPlayerSheet]（底部面板，占 60% 屏高）：内容只有倍速和
/// 清晰度两段，面板一半是空的，还压住了进度条。改成居中卡片后高度由内容决定，
/// 到 [_panelMaxHeight] 封顶，超出的部分在卡片内部滚动。
Future<void> showPlayerPanel(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final screen = MediaQuery.sizeOf(context);
  return Navigator.of(context, rootNavigator: true).push(
    GlassPopupRoute<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: .5),
      builder: (context, animation) => GlassPopupTransition(
        animation: animation,
        child: SafeArea(
          child: Dialog(
            backgroundColor: theme.colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 340,
                maxHeight: math.min(screen.height * .62, _panelMaxHeight),
              ),
              child: Theme(
                data: theme,
                child: DefaultTextStyle.merge(
                  style: TextStyle(color: theme.colorScheme.onSurface),
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

/// 悬浮菜单的最大高度（含标题行），再高就不是「小卡片」了。
const _panelMaxHeight = 400.0;

class SheetHeader extends StatelessWidget {
  const SheetHeader({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 48,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: Row(spacing: 8, children: children),
    ),
  );
}

const sheetTitle = TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

class PlaybackSettings extends StatelessWidget {
  const PlaybackSettings({
    super.key,
    required this.session,
    required this.onFailure,
  });
  final PlaybackSession session;
  final VoidCallback onFailure;

  Future<void> _change(Future<void> Function() change) async {
    try {
      await change();
    } catch (_) {
      onFailure();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final colors = Theme.of(context).colorScheme;
      final label = TextStyle(fontSize: 14, color: colors.onSurfaceVariant);
      return Column(
        // 悬浮卡片按内容撑高：纵向收缩交给 Flexible + shrinkWrap 的列表。
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetHeader(
            children: [
              const Expanded(child: Text('播放设置', style: sheetTitle)),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
                tooltip: '关闭',
              ),
            ],
          ),
          Flexible(
            child: ListView(
              // 菜单内容很短，撑满会留一大块空白；超出上限时这里自己滚。
              shrinkWrap: true,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Text('倍速', style: label),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final speed in playbackSpeeds)
                      _Choice(
                        label: '${speed}x',
                        selected: speed == session.speed,
                        onSelected: () =>
                            _change(() => session.setSpeed(speed)),
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text('清晰度', style: label),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: session.local
                      ? [
                          _Choice(
                            label: session.qualityLabel,
                            selected: true,
                            onSelected: null,
                          ),
                        ]
                      : [
                          for (final quality in [...session.qualities, 0])
                            _Choice(
                              label: quality == 0
                                  ? (session.quality == 0
                                        ? session.qualityLabel
                                        : '自动')
                                  : '${quality}P',
                              selected: quality == session.quality,
                              onSelected: session.ready
                                  ? () => _change(
                                      () => session.setQuality(quality),
                                    )
                                  : null,
                            ),
                        ],
                ),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onSelected,
  });
  final String label;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  Widget build(BuildContext context) => ChoiceChip(
    label: Text(label),
    selected: selected,
    showCheckmark: false,
    shape: const StadiumBorder(),
    onSelected: onSelected == null ? null : (_) => onSelected!(),
  );
}
