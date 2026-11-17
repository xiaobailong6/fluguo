import 'dart:async';

import 'package:flutter/material.dart';

import '../../models.dart';
import '../../playback_session.dart';
import '../widgets/app_notice.dart';
import '../widgets/choice_panel.dart';

/// 沿用现有选项弹窗；只增加入口，不更换选集面板和播放器布局。
class PlayerSeasonChoice extends StatefulWidget {
  const PlayerSeasonChoice({
    super.key,
    required this.session,
    this.enabled = true,
    this.onSelected,
    this.focusNode,
    this.onMenuChanged,
  });
  final PlaybackSession session;
  final bool enabled;
  final VoidCallback? onSelected;
  final FocusNode? focusNode;
  final ValueChanged<bool>? onMenuChanged;
  @override
  State<PlayerSeasonChoice> createState() => _PlayerSeasonChoiceState();
}

class _PlayerSeasonChoiceState extends State<PlayerSeasonChoice> {
  bool _failed = false;
  bool _loading = false;
  bool _choosing = false;
  String? _dramaId;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _dramaId = widget.session.detail.drama.id;
    unawaited(_load());
  }

  @override
  void didUpdateWidget(PlayerSeasonChoice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      oldWidget.session.removeListener(_changed);
      widget.session.addListener(_changed);
      _dramaId = widget.session.detail.drama.id;
      unawaited(_load());
    }
  }

  void _changed() {
    if (!mounted) return;
    final id = widget.session.detail.drama.id;
    if (_dramaId != id) {
      _dramaId = id;
      _failed = false;
    }
    setState(() {});
  }

  Future<void> _load() async {
    final session = widget.session;
    _loading = true;
    try {
      await session.loadSeasons();
      if (mounted && session == widget.session) _failed = false;
    } catch (_) {
      if (mounted && session == widget.session) _failed = true;
    } finally {
      if (mounted && session == widget.session) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  Future<void> _choose() async {
    final session = widget.session;
    if (_choosing || !widget.enabled || session.locked || session.loading) {
      return;
    }
    if (_failed) {
      await _load();
      return;
    }
    _choosing = true;
    widget.onMenuChanged?.call(true);
    try {
      final rows = session.seasons;
      final selected = await showChoicePanel<DramaSeason>(
        context: context,
        title: '选择季',
        options: [
          for (final season in rows) ChoiceOption(season, season.label),
        ],
        selected: rows
            .where((s) => s.drama.id == session.detail.drama.id)
            .firstOrNull,
        grid: ChoiceGrid.sources,
      );
      if (!mounted ||
          selected == null ||
          session != widget.session ||
          session.locked) {
        return;
      }
      if (await session.playSeason(selected) && mounted) {
        widget.onSelected?.call();
      }
    } catch (error) {
      if (mounted) showAppNotice(context, error.toString());
    } finally {
      _choosing = false;
      if (mounted) widget.onMenuChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final rows = session.seasons;
    if (_loading ||
        session.mediaHistoryId != null ||
        (!_failed && rows.length < 2)) {
      return const SizedBox.shrink();
    }
    final current = rows
        .where((s) => s.drama.id == session.detail.drama.id)
        .firstOrNull;
    return TextButton.icon(
      key: const ValueKey('player-season-choice'),
      focusNode: widget.focusNode,
      onPressed: widget.enabled && !session.locked && !session.loading
          ? _choose
          : null,
      icon: const Icon(Icons.expand_more_rounded, size: 18),
      label: Text(_failed ? '重试选季' : current?.label ?? '选季', maxLines: 1),
    );
  }
}
