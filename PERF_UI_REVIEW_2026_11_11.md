# 性能与 UI 排查报告（2026-11-11）

> 范围：`duanju_app`（Flutter 多端短剧应用），`lib/` 约 192 个文件。
> 方法：逐行阅读 key 热路径 + 全库 grep（`BackdropFilter/ImageFiltered/Opacity/notifyListeners/同步 IO/Timer` 等）。
> **验证限制：本机无 Flutter / Dart 工具链**（`flutter`、`dart`、`fvm` 均不在 PATH，
> `.dart_tool` 引用的工具链路径不存在），因此**未运行 `dart analyze` / `flutter test`**，
> 本报告全部结论来自静态阅读。合并前请在带工具链的机器上补跑
> `dart analyze --fatal-infos lib test` 与 `flutter test`，并用
> `flutter run --dart-define=PERF_HUD=true` 真机测基线。

---

## 一、总体结论

这是一份**已经过 1～2 轮性能专项治理**的成熟代码。热点路径上的关键做法都是对的：

- **液态玻璃**：全应用唯一的 `BackdropFilter` 实现点（`glass_surface.dart`），
  三档降级（full/reduced/none，电视与低端逃生舱）、`ImageFilter`/`Shader`/派生档全局缓存、
  边框全用 `CustomPaint` 矢量绘制不额外叠 `saveLayer`（`glass_style.dart`、
  `glass_surface.dart`）。
- **弹幕**：整层单 Ticker + 共享时钟插值，文本包 `RepaintBoundary`，逐帧只更新 `Transform`
  （`danmaku_overlay.dart`）。
- **播放会话**：`stream.position` 只推进内部同步、**不**触发 `ChangeNotifier`；
  进度每 5s `quiet` 保存，列表无实质变化时不通知（`playback_session.dart:1191+`）；
  预加载有完整门控（`_syncPreload`）。
- **封面链路**：按档位解码宽度、`CoverLoader` 并发限流 6、HEIC 转换队列化 +
  后台 isolate 剪枝（`cover_image.dart` / `cover_loader.dart` / `cover_decoder.dart`）。
- **壳层**：`IndexedStack` + 未访问 tab 惰性构建，底栏显隐/滚动用 `ValueNotifier`
  隔离，避免整棵壳层重建（`app_shell.dart`）。

因此**没有发现阻塞性 / 编译级问题**。下文按收益从高到低列出仍可收口的地方，
多数是“边际收益”，勿把它们当紧急缺陷。

---

## 二、问题清单（按优先级）

### P1-1　`DramaSliverGrid` 每张海报监听整个 `LocalStore`
- 位置：[drama_grid.dart](../lib/ui/widgets/drama_grid.dart:97)
- 现状：每个 tile 包一层 `ListenableBuilder(listenable: store)`，
  当 `store` 发出任意通知（追剧切换、来源切换、进度非 quiet 保存等），
  **所有可见海报**的 builder 都会重跑一遍 `DramaTile`。
  虽然有 `ValueKey(drama.id)` + `CoverImage` 内部 `_image` 缓存兜底，实际是
  “N 个 tile × 一次轻量 build”，滚动时无影响（滚动不通知 store），
  只有离散状态变更时发生，所以严重度评“中”。
- 建议（收益中、改动小）：把“是否追剧”退成**只订阅收藏集合**的细粒度通知，
  例如 `store.favoritesRevision`（若已有）或一个 `ValueListenable<Set<String>>`，
  让 `DramaSliverGrid` 只在该集合变化时重建；其余 store 变更不再搅动海报网格。
  至少要确认 `isFavorite(id)` 是 O(1) 集合查询（当前看起来是）。

### P1-2　`CoverImage` 在 build 期间改状态
- 位置：[cover_image.dart](../lib/ui/widgets/cover_image.dart:329)（`_failure`）
  与 [cover_image.dart](../lib/ui/widgets/cover_image.dart:362)（`_decodedWidths.add`）
- 现状：
  1. `_failure(path)` 会在 build/errorBuilder 里同步写 `_failed`/`_failedPath`，
     并在 `_retryOnFailure` 时调 `_queueRetry()`，其中又调用了
     `WidgetsBinding.instance.ensureVisualUpdate()`——在 build 阶段请求视觉更新
     属于“脏 build”信号，容易埋下未来 `setState during build` 的雷。
  2. `_decodedWidths[path].add(width)` 是 build 内对实例字段的副作用（纯记账、
     不重建，目前无功能 bug，但违反 build 纯度）。
- 建议（收益中、风险低）：错误重试的入口移到 FutureBuilder 之外
  （errorBuilder 里只返回失败 UI，真正的 `_failed=true`+重试排队放到
  `addPostFrameCallback`/microtask）；`_decodedWidths` 的登记移到 `_load`/重试路径
  或 post-frame，不要在 `build` 里 mutate。

### P1-3　播放页位置刷新会重建整个 surface 子树
- 位置：[player_surface.dart](../lib/ui/player/player_surface.dart:107)（position/buffer
  监听）与 [player_surface.dart](../lib/ui/player/player_surface.dart:174)（`_refresh`）
- 现状：`build` 用 `ListenableBuilder(listenable: _session)` 包住**整个 Stack**
  （视频、弹幕、控制栏、提示层）。`_session` 本身不随 position 通知（这点是对的），
  但可视状态下 position/buffer 事件仍会走 `_refresh()` → `setState`，
  整棵 `_PlayerSurfaceState.build` 重跑，进而重建这份大 Stack 与 `_controls`
  （Slider、时长文本、渐变遮罩等），可视时约每秒多次。
- 建议（收益中、风险中）：把“进度条 + 时钟 + 缓冲条”这一小块收敛到文件里已存在、
  但当前未在此处使用的 `PlaybackProgressBuilder`，外面套 `RepaintBoundary`；
  让 position/buffer tick 只震到这一小块，视频/弹幕/工具按钮不参与重建。
  注意 `PlayerVideo`（keyed）、`DanmakuOverlay`（独立时钟）本就有隔离，收益主要集中在
  `_controls` 与控制层栅格化范围。

---

### P2-1　根组件每次 build 都注册一个 post-frame 回调
- 位置：[app.dart](../lib/ui/app.dart:325)
- 现状：`_application` 每次 build 都 `addPostFrameCallback` 去设
  `FocusManager.highlightStrategy`，该值只在“电视/非电视”切换时真正变化。
  主题、取色、profile 变更等重建都会白白排一次队。
- 建议（零风险）：状态字段 `_highlightStyle` 缓存最后值，仅当
  `television` 变化时才注册回调；或迁到 `initState` + `didUpdateWidget`。

### P2-2　`main.dart` 相邻的重复 mounted 判定
- 位置：[main.dart](../lib/main.dart:133)
- 现状：`if (!mounted) { local.dispose(); return; }` 之后紧接又一行
  `if (!mounted) return;`，后一条永远不可达。
- 建议（零风险）：删除 `137` 行这一条。

### P2-3　merged_library 首次初始化含同步 IO
- 位置：[merged_library.dart](../lib/merged_library.dart:233)（`readAsStringSync`）、
  [merged_library.dart](../lib/merged_library.dart:146) / `:375` / `:412`（`listSync`）
- 现状：`ensureInitialized` 一次性读取索引、必要时列目录，均为同步 IO。
  好处是有界（索引大小与条目数都有上限），且只在首次打开合并库时执行一次；
  坏处是索引/目录较大时会在 UI isolate 上停一下。
- 建议（低优先）：维持现状可接受；若真机观察到首次打开“我的/合并库”有卡顿，
  再把 `_readIndex` + 目录抢救逻辑迁到 `Isolate`（`_persist` 已是 async 写，无需动）。

---

### P3（洁净度 / 稳健性）

1. [drama_tile.dart](../lib/ui/widgets/drama_tile.dart:241) 的 `_line` 使用
   `style.fontSize!` 非空断言——当前所有调用点自带 `fontSize`，暂时安全；
   建议去掉断言或给默认值，避免未来某人传无字号样式直接崩溃。
2. [drama_tile.dart](../lib/ui/widgets/drama_tile.dart:291) 与
   [drama_grid.dart](../lib/ui/widgets/drama_grid.dart:34) 的多处 `extentFor` /
   `dramaGridDelegate` 重复计算列数与 `TextStyle`（每次 build 新建）——分配极小，
   属锦上添花。
3. [tab_page_transition.dart](../lib/ui/shell/tab_page_transition.dart:70) 切 tab 的
   `Opacity` 过渡在 200ms 内会叠一层 `saveLayer`；只在切 tab 瞬间、非持续开销，
   低端 Android 若掉帧可考虑只保留 `Transform.translate` 的纯位移过渡。

---

## 三、UI 优化建议（视觉与体验）

1. **玻璃降级策略已经很好，补一条自适应**：桌面端窗口**拖拽/改变大小时**临时降到
   `GlassTier.reduced`（或暂停 `BackdropFilter`），拖动结束恢复，能明显改善
   大窗拖拽掉帧。`GlassStyleResolver.of` 已把档位决策集中，改动只在一处。
2. **播放控制层加 `RepaintBoundary`**：见 P1-3。它不仅减少重建，还能把进度条逐帧
   重绘限制在控制条自己的图层，避免带动全屏栅格。
3. **暗色/高对比/减少动画降级链路已闭环**（`GlassStyleResolver`、`AppMotion.reduced`），
   UI 侧无需再加；保持现状即可。
4. 电视端焦点高亮（`FocusManager.highlightStrategy`）与焦点环（`focus_ring.dart`）、
   语义与键盘导航已完整，未见 UI 缺陷。

---

## 四、建议执行顺序

| 序 | 项 | 风险 | 收益 |
| --- | --- | --- | --- |
| 1 | P2-1 app.dart post-frame 条件化 | 零 | 低 |
| 2 | P2-2 删除重复 mounted | 零 | 低 |
| 3 | P1-2 cover_image build 副作用收敛 | 低 | 中 |
| 4 | P1-1 收藏状态细粒度监听 | 低-中 | 中 |
| 5 | P1-3 播放页进度刷新隔离 | 中 | 中 |
| 6 | P2-3 / P3 清理项 | 低 | 低 |

---

## 五、需在工具链机器上补做的验证

- `dart analyze --fatal-infos lib test`
- `flutter test`
- `flutter run --dart-define=PERF_HUD=true`：重点看列表快速滚动、播放页控制栏显隐、
  切 tab、低端机玻璃降级四类场景的 jank%。

---

## 六、落实情况（第 1～3 步）

已按「第 1～3 步」落地，均不改视觉：同样的像素，少做无用功。

| 项 | 文件 | 改法 |
| --- | --- | --- |
| P2-2 重复 `mounted` | `lib/main.dart` | 已删除（工作区里先行完成） |
| P3-1 `_line` 非空断言 | `lib/ui/widgets/drama_tile.dart` | 改 `fontSize/height` 显式兜底 |
| P3-2 布局/样式重复计算 | `lib/ui/widgets/drama_tile.dart`、`lib/ui/widgets/drama_grid.dart` | `extentFor` 只取一次样式；grid 只走一次 `_gridLayout`（后者工作区先行完成）；`ProgressPoster.build` 复用同一份 `TextStyle` |
| P1-2 build 期间改状态 | `lib/ui/widgets/cover_image.dart` | `_failure` 只出界面，失败记账经 `_recordFailure` 推到帧末，并按图源身份丢弃过期记账；解码档登记改为写一次 |
| P1-3 播放页整树重建 | `lib/ui/player/player_surface.dart` | 进度行包进 `RepaintBoundary` + `PlaybackProgressBuilder(active: visible)`；拖动值改 `ValueNotifier<double?>`，`onChanged` 不再 `setState` 整页；`_bind` 不再为位置/缓冲调 `_refresh` |

未做：P1-1（依赖收藏集合与源可用性两个变量）、P2-1、P2-3、P3-3（会让切页少一次淡入）、
桌面拖拽降玻璃——按上一轮结论留到真机 `PERF_HUD` 有数据后再定。

回归重点：拖动进度条松手后进度显示是否立即交还播放器位置；暂停/缓冲/切集时控制栏
显隐与「再按一次返回」不受影响；快速滚动列表时海报爱心标记是否随追剧/换源更新。