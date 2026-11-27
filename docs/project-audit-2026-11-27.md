# 项目补充排查（2026-11-27）

本轮在红果取流修复之后，检查实际应用的 Flutter 请求与状态管理、下载转换/导出、本地保存，以及部分 Go 播放代理和下载路径。`source/`、`live/` 为参考项目，不作为当前应用的生产代码。开始时工作区干净。

## 已确认并修复

### 连续刷新会被旧分类或榜单覆盖

`SourceCatalog.loadCategories` 原来直接提交每次异步读取结果。旧请求晚于强制刷新返回时，页面会退回旧分类或榜单。旧请求先结束时，还可能让 `ExploreFeed` 提前认定上次分类不存在，把保存的分类替换成默认推荐页。

修复在缓存、榜单和分类的异步边界核对请求代次；过期请求不再写入状态或派发下一步读取，并返回“未应用”，调用方因此保留待恢复的分类。回归覆盖旧分类迟到、旧榜单迟到和旧空分类先结束的三种顺序。

涉及 `lib/source_catalog.dart`、`lib/explore_feed.dart`，对应 `test/source_catalog_test.dart`、`test/explore_feed_test.dart`。

### 剧场把警告缓存页当作成功，可能误判推荐耗尽

仓库接口会在网络失败时返回带 `warning` 的旧缓存。`TheaterFeed` 原来仅在抛出异常时识别失败，仍会按缓存页的 `hasMore` 推进或关闭游标，并清除错误提示。因此恢复网络后的重试可能跳过失败页，或继续循环旧内容。

修复保留可展示的缓存，但带警告或结构化失败的响应不推进、也不关闭游标；结束本轮自动请求并显示重试提示。显式重试重新请求失败页，成功后恢复分页。回归分别覆盖有缓存条目和空缓存。

涉及 `lib/theater_feed.dart`，对应 `test/theater_infinite_test.dart`。

### 自动导出可能早于待办保存确认

`DownloadAutoExporter.queue` 先更新内存再等待写盘，期间总览的完成快照可以调用 `_sync`，提前执行导出；开启导出后删除时，也可能执行内部副本清理。即使这次待办写入随后失败，处理已经开始。这违反了待办保存成功后再处理的恢复约定。

修复记录排队和进行中的待办写入；保存确认前不启动新导出。保存失败保留错误和待办，用户重试保存成功后再执行。回归用可控的偏好存储模拟写入延迟、写入返回失败，以及后续重试，检查导出和删除在确认前均为零次。

涉及 `lib/download_auto_export.dart`，对应 `test/download_auto_export_test.dart`。

## 验证记录

- 修改前：`dart analyze --fatal-infos lib`、`test` 均无问题；标准版完整 Flutter 测试 1,386 通过、0 失败、2 项跳过。
- 前六个新增用例在原实现上全部失败，分别表现为旧数据覆盖、缺少失败提示、写盘确认前已执行导出/删除。分类恢复用例另行复现了保存偏好被改成 `app:recommend`。
- 修复后：10 个相关测试文件共 91 项全部通过，包含连续滑动 800 项、分类邻页预取、剧场生命周期、下载转换和自动导出等既有回归。
- 修复后标准版、全站源版完整 Flutter 测试各 1,393 通过、0 失败、2 项跳过；两项跳过均因 Windows 符号链接权限限制。两个版本的执行进程均退出 0。
- 最终 `dart analyze --fatal-infos lib`、`test` 均无问题；`dart format --output=none --set-exit-if-changed lib test` 检查 422 个文件无变化；标准/全站源 `scripts/check_source_capabilities.dart` 各检查 20 项通过；`git diff --check` 通过。
- 本地测试日志保存在忽略目录：`build/audit-flutter-baseline.log`、`build/audit-regressions-before.log`、`build/audit-refresh-before.log`、`build/audit-regressions-fixed.log`、`build/audit-flutter-standard.log`、`build/audit-flutter-all-sources.log`。

测试使用现有 Flutter 3.47.4 / Dart 3.13.3 和现有依赖，全部传入 `--dart-define=DISABLE_REMOTE_IMAGES=true`。没有升级依赖或修改原生核心；本轮未打包安装或进行真机媒体解码测试。此次排查和离线测试不代表所有第三方站源当前均可用。

## UI 与动画的后续优化建议

以下保留首次代码审查时的结论与候选方案。用户随后选定的第 1、3、4 项已实施，更新后的验收记录见 `docs/ui-motion-2026-11-27.md`；其余项目仍为建议。现有统一动效参数、减少动画支持、电视时长上限、列表按需构建、海报解码尺寸控制和玻璃样式缓存继续保留。

1. **优先处理页面转场曲线的生命周期。** `lib/ui/app_motion.dart` 的 `transitionsBuilder` 每次执行都创建 `CurvedAnimation`，没有单独释放。本机 Flutter SDK 的 `animations.dart` 明确说明此对象会注册状态监听，应创建一次并在不再需要时释放；父动画销毁也会清理监听，因此不应描述为页面退出后永久泄漏。建议用有状态的转场组件持有曲线，并在动画父对象变化和组件销毁时释放。这样也能保留中途反向时的曲线方向状态；补充进入未结束就返回、重复构建时监听不增长的回归。

2. **补齐程序触发的翻页与定位动画对系统设置的响应。** `portrait_player_page.dart` 的滚轮翻集固定 250ms，`theater_page.dart` 的键盘翻页和 `episode_grid.dart` 的当前集定位固定 200ms；详情和日志的键盘滚动固定 150ms。这些路径没有使用统一的减少动画判定。建议走统一策略，减少动画时使用 `jumpToPage` / `jumpTo`，正常模式保留合适时长；不能直接把 `animateTo` 的时长改成零。用户直接拖动的跟手滚动应保留。

3. **首屏加载保持内容布局。** `explore_page.dart` 的空数据加载态使用 `StatusView.loading`，目前主要是居中的转圈和文字。可在首次加载时按现有网格尺寸展示静态海报、标题占位，加载完成后替换对应内容；已有内容刷新时继续保留原列表。骨架无需为每张卡片各启动一个常驻动画。

4. **海报首帧衔接更平滑。** `cover_image.dart` 已有文件缓存和 `cacheWidth`，目前直接返回 `Image.file`，没有解码首帧占位和显现过渡。可用首帧状态保留同尺寸占位，仅对首次异步显示的图片做短淡入；缓存命中、减少动画和快速滚动时避免反复播放。需要验证长列表滚动与封面重试，不应把网络慢或解码等待伪装成持续装饰动画。

5. **把现有玻璃降级能力开放成明确的画质选择。** `appearance_settings.dart` 只有玻璃开关；`GlassStyleResolver` 已有 full/reduced/none 三档，但 reduced 目前由无障碍设置触发，没有读取省电或设备性能。可增加完整、轻量、关闭选项，让用户独立选择模糊开销。保留播放器零模糊和列表静态卡片不模糊的现有设计；是否需要进一步合并背景滤镜，应在目标设备采集栅格耗时后决定。

另外，底部 Tab 的 360ms 整页过渡、浮栏的 400ms 显隐，以及内容区的 200ms 过渡，可在连续切换和请求刚好完成的场景下一起验收，避免重复入场让内容显得迟滞。`TabPageTransition` 和 `LocalContentTransition` 已把 child 提到动画 builder 外；改用绘制阶段驱动的过渡组件可作为测量后的优化，不应先声称现有实现必然导致卡顿。
