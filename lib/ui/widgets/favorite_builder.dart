import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../local_store.dart';

/// 隐藏标签页解除订阅；恢复显示时读取最新值，保留海报自身的布局和焦点状态。
class FavoriteBuilder extends StatefulWidget {
  const FavoriteBuilder({
    super.key,
    required this.store,
    required this.id,
    required this.builder,
  });

  final LocalStore? store;
  final String id;
  final Widget Function(BuildContext, bool) builder;

  @override
  State<FavoriteBuilder> createState() => _FavoriteBuilderState();
}

class _FavoriteBuilderState extends State<FavoriteBuilder> {
  ValueListenable<TickerModeData>? _visibility;
  ValueListenable<bool>? _status;
  bool _followed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchVisibility();
  }

  @override
  void activate() {
    super.activate();
    _watchVisibility();
  }

  void _watchVisibility() {
    _visibility?.removeListener(_visibilityChanged);
    _visibility = TickerMode.getValuesNotifier(context);
    _visibility!.addListener(_visibilityChanged);
    _subscribe();
  }

  @override
  void didUpdateWidget(FavoriteBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store || oldWidget.id != widget.id) {
      _subscribe();
    }
  }

  void _subscribe() {
    _status?.removeListener(_changed);
    _status = null;
    if (_visibility?.value.enabled == true) {
      _status = widget.store?.favoriteStatus(widget.id);
      _status?.addListener(_changed);
      _followed = _status?.value ?? false;
    }
  }

  void _visibilityChanged() {
    final previous = _followed;
    _subscribe();
    if (_followed != previous) setState(() {});
  }

  void _changed() {
    final next = _status?.value ?? false;
    if (next != _followed) setState(() => _followed = next);
  }

  @override
  void dispose() {
    _visibility?.removeListener(_visibilityChanged);
    _status?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _followed);
}
