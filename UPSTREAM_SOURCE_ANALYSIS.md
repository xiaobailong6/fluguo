# 上游站源逆向分析 + 当前代码排查（2026-11-11）

## 一、结论速览

| 问题 | 结论 |
| --- | --- |
| 站源能否从上游还原？ | **能，但只有一个。** APK 里以 JS 源码形式内嵌了 `hongguo`（红果）完整站源 |
| 其余站源在哪？ | 私有仓库 `guoapp-modules`，运行时按 `index.json` 下载 |
| 当前仓库缺站源吗？ | **不缺，反而比上游全** —— 当前用 164 个 Go 原生 provider，上游只有 82 个 Go 文件 + 1 个 JS 模块 |
| 当前代码有 bug 吗？ | 未发现编译级/阻塞级缺陷；有 3 处值得修的中低优先项 |

---

## 二、站源架构（关键发现）

上游与本仓库走的是**两条不同的技术路线**：

```
上游 (source/)
  native/core/module_loader.go   ← 通用 JS 模块运行时
  native/core/bundled/hongguo/   ← 仅内置红果
       manifest.json  (1.1 KB)
       main.js        (126 KB)
  其余站源 → https://raw.githubusercontent.com/guoapp-modules/index/main/index.json
              (镜像: cdn.jsdelivr.net/gh/guoapp-modules/index@main/index.json)

本仓库 (lib/ + native/)
  native/core/provider_*.go      ← 164 个 Go 文件，13+ 站源原生实现
  lib/source_catalog.dart, models.dart(SourceSite.allValues)  ← 站源清单
```

上游把「站源」抽象成**可热插拔的 JS 模块**（`runtime: "js"`, `api: 1`），
这样站源实现不进主仓库、可独立发版、可灰度，代价是主仓库只剩红果一个内置模块。

### 模块加载链路（上游 Go 侧）

| 文件 | 作用 |
| --- | --- |
| `module_index.go` | 拉 `index.json`，校验 `format=1` 与每个条的 `sha256`/`tag`/`repo` |
| `module_install.go` | 下载 + 校验 + 解压安装到模块根目录 |
| `module_loader.go` | 载入 manifest，按 `capabilities` 桥接 `host.*` 到 Go 能力 |
| `module_script.go` | JS 运行时（goja 类解释器，`(function(module, exports, host){…})`） |
| `module_host.go` | 暴露 `fetch/parseHtml/aesCbcEncrypt/hexEncode/cacheSet/randomBytes/...` |
| `module_bundled.go` | `//go:embed all:bundled`，把内置模块编进 `libduanju_core.so` |

### 模块契约（manifest.json）

```json
{
  "id": "hongguo", "name": "红果", "version": "1.0.1",
  "runtime": "js", "api": 1, "adult": false,
  "hosts": ["hongguoduanju.com", "www.hongguoduanju.com",
            "api5-normal-sinfonlineb.fqnovel.com", "log.snssdk.com"],
  "capabilities": ["search","suggestions","recommendations","danmaku",
                   "devices","rankings","seasons","cover","metadata","catalogState"],
  "baseUrl": "https://hongguoduanju.com",
  "continuousFeed": true,
  "rankings": [ {"id":"hongguo-hot","name":"总热播榜",…},
                {"id":"hongguo-real","name":"真人剧榜",…},
                {"id":"hongguo-comic","name":"漫剧榜",…},
                {"id":"hongguo-ai","name":"AI剧榜",…} ]
}
```

JS 侧导出 20 个入口：
`categories / validCategory / catalogPage / search / detail / resolveMedia /
suggestions / validRecommendation / recommendations / danmakuIds / danmaku /
devices / rankingPage / seasons / coverAddress / needsExtraMetadata /
extraMetadata / catalogState / restoreCatalogState`

红果站源内含完整签名实现（`argusSeal` / `argusSetup` / `commentArgus`）与
设备注册流程（`log.snssdk.com/service/2/device_register/`），不依赖任何外部私有常量。

### 已提取产物

```
upstream_modules/hongguo/manifest.json   1,102 B   （UTF-8）
upstream_modules/hongguo/main.js       126,049 B   3,756 行
```

提取方法（可复现，无需反编译）：

1. 从 APK 解出 `lib/arm64-v8a/libduanju_core.so`
2. 扫连续非零字节块，长度 >20 KB 的仅 9 个
3. 其中偏移 `2,732,704`、长度 `126,049` 的块以
   `const siteBaseUrl = "https://hongguoduanju.com";` 开头、
   以 `module.exports = { … };` 结尾 → 即 `bundled/hongguo/main.js`
4. manifest 在偏移 `2,693,984` 处，按大括号配平截取 1,102 B

---

## 三、能不能"补出别的站源"？

**不能从这份材料补出来。** 理由：

- APK 里 `bundled/` 下只有 `hongguo` 一个目录（`jsexample` 是仓库自带示例，未编入）。
- 其余站源的 JS 不在 APK 里，必须访问私有索引仓库才能拿到。
- 但**本仓库并不需要它们**：当前 `native/core/provider_*.go` 已覆盖
  红果/帝果/青空/鬼片/韩小圈/饭果/爽果/伍果/黄豆/剧果/野果/禁果/黑桃/笔盒/
  黄果(含 AI、旧版) 等，功能比上游内置模块更全。

换言之：**上游是"模块化削减版"，本仓库是"原生全量版"。**
如果目标是"让本仓库像上游一样支持在线装模块"，缺的是 `module_*.go`
那套运行时（可从上文列出的 6 个文件移植），而不是站源本身。

---

## 四、当前代码排查

### 4.1 已确认无问题的点

| 检查项 | 结果 |
| --- | --- |
| 我们改动的 5 个文件结构完整性 | 括号/嵌套配平正确，无重复定义 |
| `_seekDrag` 全量替换 `_seekValue` | 6 处引用全部替换，无残留 |
| `PlaybackProgressBuilder` 定义唯一性 | 仅 `player_surface.dart:1152` 一处 |
| `dispose` 顺序 | 先取消流、再 `_seekDrag.dispose()`，正确 |
| `setState` 内做 IO | 0 处 |
| `analysis_options.yaml` | 仅 `flutter_lints` 基线，`source/`、`live/` 已排除分析 |

### 4.2 值得修的问题

**P1　`CoverImage._decodedWidths` 无界增长**
`lib/ui/widgets/cover_image.dart:212`

```dart
final _decodedWidths = <String, Set<int>>{};
```

只在 `_retry(path)` 里对单条 path 做 `remove`，正常浏览（不重试）时
每个见过的封面路径都会留一条。长会话下 Map 持续增长。
建议：超过阈值（如 256 条）时淘汰最旧，或改为 LRU。

**P2　`app_shell._trackScroll` 每个滚动通知都做祖先查找**
`lib/ui/shell/app_shell.dart:742-753`

```dart
final route = source != null && source.mounted ? ModalRoute.of(source) : null;
...
final scrollable = source is StatefulElement && source.state is ScrollableState
    ? source.state as ScrollableState
    : Scrollable.maybeOf(source);
```

滚动时每帧触发 `ModalRoute.of` + `Scrollable.maybeOf`（InheritedWidget 查找）。
其中 `ModalRoute.of(source)` 在 build 之外调用会注册依赖，且结果对同一
Scrollable 恒定不变。建议按 `ScrollableState` 缓存一次 route 判定结果，
后续只比较 `notification.depth/axis`。

**P3　`drama_grid` 的 `_gridLayout` 在 `dramaTileWidth` 中仍会重复调用**
`lib/ui/widgets/drama_grid.dart:29-32`
`DramaSliverGrid.build` 已合并为一次，但 `dramaTileWidth` 是公开 API，
调用方若在 build 内与 delegate 并列调用仍会算两遍。影响很小，可留。

### 4.3 测试覆盖缺口

我们改动的两个核心文件**没有对应单测**：

| 文件 | 现有测试 |
| --- | --- |
| `lib/ui/player/player_surface.dart` | 无（`playback_*_test.dart` 均不覆盖 `PlayerSurface`） |
| `lib/ui/widgets/cover_image.dart` | 仅 `cover_decode_size_test.dart` 覆盖 `coverDecodeWidth`，不含状态机 |

建议补两条 widget test：
1. 拖动进度条 → 松手 → 断言 `_seekDrag` 归 null 且显示值回到播放器位置。
2. `CoverImage` 加载失败 → 断言 `_recordFailure` 在帧末生效、且换源后旧记账不生效。

---

## 五、合规提示

`upstream_modules/` 下的内容是从上游 APK 二进制中提取的私有模块产物。
若本仓库与 `guoapp-modules` 非同一权利人，使用前请确认授权范围；
若为同一权利人，建议把这些文件纳入 `source/` 的对照说明或直接删除，
避免以"提取物"形式进入主仓库版本历史。
