import 'package:flutter/material.dart';
import '../widgets/app_notice.dart';

import '../../live_models.dart';
import '../../local_store.dart';

class LiveFavoriteButton extends StatefulWidget {
  const LiveFavoriteButton({
    super.key,
    required this.store,
    required this.platformId,
    required this.room,
    this.color,
  });
  final LocalStore store;
  final String platformId;
  final LiveRoom room;
  final Color? color;
  @override
  State<LiveFavoriteButton> createState() => _LiveFavoriteButtonState();
}

class _LiveFavoriteButtonState extends State<LiveFavoriteButton> {
  var _saving = false;
  Future<void> _toggle() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.store.toggleLiveFavorite(widget.platformId, widget.room);
    } catch (_) {
      if (mounted) {
        showAppNotice(context, '未能保存直播收藏，请重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.store,
    builder: (context, _) {
      final saved = widget.store.isLiveFavorite(
        widget.platformId,
        widget.room.roomId,
      );
      return IconButton(
        key: ValueKey(
          'live-favorite-${widget.platformId}-${widget.room.roomId}',
        ),
        tooltip: saved ? '取消收藏主播' : '收藏主播',
        onPressed: _saving ? null : _toggle,
        icon: Icon(
          saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
        ),
        color: saved ? Theme.of(context).colorScheme.primary : widget.color,
      );
    },
  );
}
