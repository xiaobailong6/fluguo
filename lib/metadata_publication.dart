import 'catalog_updates.dart';
import 'local_store.dart';
import 'metadata_refresh.dart';
import 'models.dart';

// 只在同步 publish 通知期间标记责任归属，不缓存“已保存”的剧 ID；
// 因而失败后的下一次请求、迟到补充字段和其他后台发布都不会被去重吞掉。
final _owners = Expando<Map<LocalStore, Drama>>();

bool metadataPublicationOwned(CatalogUpdates updates, LocalStore store) {
  final expected = _owners[updates]?[store];
  final latest = updates.latest;
  // 同步监听中再 publish 另一份资料也必须保存，不能被外层发布的标记吞掉。
  return expected != null &&
      latest != null &&
      sameDramaMetadata(expected, latest);
}

Future<void> publishPersistedMetadata(
  CatalogUpdates updates,
  LocalStore store,
  Drama drama, {
  bool retryCover = false,
}) {
  final expected = updates.current(drama).merge(drama);
  final write = store.refreshDrama(expected);
  final owners = _owners[updates] ??= {};
  final previous = owners[store];
  owners[store] = expected;
  try {
    updates.publish(drama, retryCover: retryCover);
  } finally {
    if (previous == null) {
      owners.remove(store);
    } else {
      owners[store] = previous;
    }
  }
  return write;
}
