import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import '../../local_store.dart';

/// 播控上可选的「时钟 / 缓存读速」小字。
///
/// `enabled` 由播放布局控制：短剧竖屏不计时、不读原生属性。
class PlayerStatsLabel extends StatefulWidget {
  const PlayerStatsLabel({
    super.key,
    required this.player,
    required this.store,
    this.compact = true,
    this.enabled = true,
    this.clock = true,
    this.cacheSpeed = true,
  });

  final Player player;
  final LocalStore store;
  final bool compact;
  final bool enabled;
  final bool clock;
  final bool cacheSpeed;

  @override
  State<PlayerStatsLabel> createState() => _PlayerStatsLabelState();
}

class _PlayerStatsLabelState extends State<PlayerStatsLabel> {
  Timer? _timer;
  String _speed = '0 KB/S';
  bool _speedAvailable = true;

  bool get _wanted =>
      widget.enabled &&
      (widget.clock && widget.store.playbackPreferences.showClock ||
          widget.cacheSpeed && widget.store.playbackPreferences.showCacheSpeed);

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_changed);
    _sync();
  }

  @override
  void didUpdateWidget(PlayerStatsLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.player, widget.player)) {
      _speed = '0 KB/S';
      _speedAvailable = true;
    }
    if (oldWidget.store != widget.store) {
      oldWidget.store.removeListener(_changed);
      widget.store.addListener(_changed);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.store.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _sync();
  }

  void _sync() {
    if (_wanted) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    if (!mounted) return;
    setState(() {});
    if (widget.enabled &&
        widget.cacheSpeed &&
        widget.store.playbackPreferences.showCacheSpeed) {
      unawaited(_readSpeed());
    }
  }

  Future<void> _readSpeed() async {
    if (!_speedAvailable || !widget.enabled || !widget.cacheSpeed) return;
    final player = widget.player;
    try {
      final platform = player.platform;
      final value = await (platform as dynamic).getProperty('cache-speed');
      if (!mounted ||
          !widget.enabled ||
          !widget.cacheSpeed ||
          !identical(player, widget.player)) {
        return;
      }
      setState(() => _speed = _format(value));
    } catch (_) {
      if (!mounted || !identical(player, widget.player)) return;
      _speedAvailable = false;
      setState(() => _speed = '0 KB/S');
    }
  }

  String _format(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return '0 KB/S';
    final bytes = double.tryParse(text);
    if (bytes == null || !bytes.isFinite || bytes <= 0) return '0 KB/S';
    const units = ['B/S', 'KB/S', 'MB/S', 'GB/S'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit++;
    }
    return '${size.toStringAsFixed(size >= 100 ? 0 : 1)} ${units[unit]}';
  }

  String _clock() {
    final now = TimeOfDay.now();
    final hour = now.hour.toString().padLeft(2, '0');
    return '$hour:${now.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final preferences = widget.store.playbackPreferences;
    if (!widget.enabled) return const SizedBox.shrink();
    final parts = <String>[
      if (widget.cacheSpeed && preferences.showCacheSpeed) _speed,
      if (widget.clock && preferences.showClock) _clock(),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    final labels = parts.map(
      (part) => Text(
        part,
        maxLines: 1,
        softWrap: false,
        style:
            (widget.compact
                    ? const TextStyle()
                    : Theme.of(context).textTheme.labelLarge ??
                          const TextStyle())
                .copyWith(
                  fontSize: widget.compact ? 11 : 14,
                  height: widget.compact ? 1 : null,
                  fontWeight: widget.compact
                      ? FontWeight.normal
                      : FontWeight.w500,
                  color: Colors.white.withValues(alpha: .82),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
      ),
    );
    final text = Row(
      mainAxisSize: MainAxisSize.min,
      spacing: widget.compact ? 8 : 12,
      children: labels.toList(),
    );
    if (widget.compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: text,
      );
    }
    return TextButton(
      onPressed: null,
      style: TextButton.styleFrom(
        fixedSize: const Size.fromHeight(40),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        disabledForegroundColor: Colors.white.withValues(alpha: .82),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      child: text,
    );
  }
}
