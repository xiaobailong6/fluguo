import 'package:flutter/material.dart';

import 'live_control_pill.dart';

/// 右侧按钮组按内容收缩后贴右，不让画质的flex与左侧空白平分整栏。
class LivePlaybackControls extends StatelessWidget {
  const LivePlaybackControls({
    super.key,
    required this.playing,
    required this.full,
    required this.quality,
    required this.onTogglePlayback,
    required this.onQuality,
    required this.onFullscreen,
    this.onLine,
    this.showLine = false,
    this.showMini = false,
    this.onMini,
    this.fullscreenTooltip = '全屏',
    this.middle,
  });
  final bool playing;
  final bool full;
  final String quality;
  final bool showLine;
  final bool showMini;
  final VoidCallback? onTogglePlayback;
  final VoidCallback? onLine;
  final VoidCallback? onQuality;
  final VoidCallback? onMini;
  final VoidCallback? onFullscreen;
  final String fullscreenTooltip;
  final Widget? middle;

  Widget _menu(String key, String label, VoidCallback? onPressed) => full
      ? LiveControlPill(key: ValueKey(key), label: label, onPressed: onPressed)
      : TextButton(
          key: ValueKey(key),
          onPressed: onPressed,
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
        );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Row(
      children: [
        IconButton(
          key: const ValueKey('live-playback-toggle'),
          tooltip: playing ? '暂停' : '播放',
          onPressed: onTogglePlayback,
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
          color: Colors.white,
        ),
        if (middle != null)
          Expanded(
            child: Center(
              child: FittedBox(fit: BoxFit.scaleDown, child: middle!),
            ),
          )
        else
          const Spacer(),
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: constraints.maxWidth - 48),
          child: IntrinsicWidth(
            child: Align(
              alignment: Alignment.centerRight,
              child: Row(
                key: const ValueKey('live-right-controls'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (showLine) _menu('live-line-control', '线路', onLine),
                  Flexible(
                    child: _menu('live-quality-control', quality, onQuality),
                  ),
                  if (showMini)
                    IconButton(
                      key: const ValueKey('live-mini-control'),
                      tooltip: '画中画',
                      onPressed: onMini,
                      icon: const Icon(Icons.picture_in_picture_alt_rounded),
                      color: Colors.white,
                    ),
                  IconButton(
                    key: const ValueKey('live-fullscreen-control'),
                    tooltip: fullscreenTooltip,
                    onPressed: onFullscreen,
                    icon: Icon(
                      full
                          ? Icons.fullscreen_exit_rounded
                          : Icons.fullscreen_rounded,
                    ),
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
