import 'core_bridge.dart';

/// 退出未确认时隔离暂存目录，避免阻塞库串行操作或删除仍在写入的文件。
class MediaCleanupPending extends AppFailure {
  MediaCleanupPending(super.message, this.whenSafe);
  final Future<void> Function() whenSafe;
}
