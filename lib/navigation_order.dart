/// 菜单顺序只保存稳定名称，不改变 AppTab 的身份索引或 Navigator 顺序。
const defaultNavigationOrder = ['theater', 'explore', 'live', 'follow', 'mine'];

List<String> normalizeNavigationOrder(Iterable<Object?> values) =>
    List.unmodifiable({
      for (final value in values)
        if (value is String && defaultNavigationOrder.contains(value)) value,
      ...defaultNavigationOrder,
    });
