import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../playback_preferences.dart';
import '../../playback_session.dart';
import '../app_motion.dart';
import '../widgets/glass/glass_popup_transition.dart';
import '../widgets/glass/glass_surface.dart';
import '../theme/app_theme.dart';
import '../theme/glass_style.dart';
import 'sleep_timer_options.dart';

/// 播放器深色配色的缓存位：亮色主题下每次进入播放页只构建一次。
(Color, ThemeData)? _darkPlayerTheme;

ThemeData playerTheme(BuildContext context) {
  final theme = Theme.of(context);
  if (theme.brightness == Brightness.dark) return theme;
  final seed = theme.colorScheme.primary;
  if (_darkPlayerTheme case (final cached, final dark) when cached == seed) {
    return dark;
  }
  final dark = AppTheme.build(seed, Brightness.dark, television: false);
  _darkPlayerTheme = (seed, dark);
  return dark;
}

/// 播放器内的玻璃面板：与播放控件同一套深色材质。
///
/// 播放页背后是持续变化的视频，逐帧模糊会明显增加合成开销，因此沿用
/// [GlassRole.playback] 的零模糊配方，只靠半透明染色、内高光和描边表达玻璃。
GlassStyle _playerGlassStyle(BuildContext context) {
  final base = GlassStyleResolver.of(context, role: GlassRole.playback);
  return base.thinned(tintAlpha: base.tier == GlassTier.none ? .94 : .8);
}

Widget _sheetGrabber(BuildContext context) => Padding(
  padding: const EdgeInsets.only(top: 8, bottom: 2),
  child: Center(
    child: Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .26),
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  ),
);

Future<void> showPlayerSheet(
  BuildContext context,
  WidgetBuilder builder, {
  bool dark = true,
}) {
  final theme = dark ? playerTheme(context) : Theme.of(context);
  final height = MediaQuery.sizeOf(context).height * .6;
  final safeBottom = MediaQuery.viewPaddingOf(context).bottom;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: .45),
    sheetAnimationStyle: AppMotion.sheet(context),
    constraints: BoxConstraints.tightFor(height: height),
    builder: (context) => Theme(
      data: theme,
      child: Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.fromLTRB(8, 0, 8, 8 + safeBottom),
          child: GlassSurface(
            role: GlassRole.panel,
            radius: GlassRadius.sheet,
            style: _playerGlassStyle(context),
            child: Column(
              children: [
                _sheetGrabber(context),
                Expanded(child: Builder(builder: builder)),
              ],
            ),
          ),
        ),
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
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: 340,
                  maxHeight: math.min(screen.height * .62, _panelMaxHeight),
                ),
                child: Theme(
                  data: theme,
                  child: Builder(
                    builder: (context) => GlassSurface(
                      role: GlassRole.panel,
                      radius: GlassRadius.dialog,
                      style: _playerGlassStyle(context),
                      child: Builder(builder: builder),
                    ),
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
      final sleepAt = session.sleepAt;
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
                const SizedBox(height: 18),
                Text('定时停止', style: label),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in sleepTimerOptions)
                      _Choice(
                        label: sleepTimerOptionLabel(option),
                        selected: selectedSleepTimer(session) == option,
                        onSelected: () => applySleepTimer(session, option),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  session.sleepAtEpisodeEnd
                      ? '本集结束后暂停，不自动播放下一集'
                      : sleepAt != null
                      ? '将在 ${sleepAt.hour.toString().padLeft(2, '0')}:${sleepAt.minute.toString().padLeft(2, '0')} 暂停，切集不重置'
                      : '仅对本次播放有效，退出播放页后取消',
                  style: label,
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
