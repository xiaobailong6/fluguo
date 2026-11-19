# FlGuo 1.0.97+197：代码格式、性能与 UI 审查

> **后续状态（1.0.98+198）**：已完成本轮修复，标准版与全站源版 Flutter 全量各 966 项通过、0 失败、2 项因符号链接权限跳过。本文保留修复前的证据与当时源码行号；最新结果和原生/实机限制见 [开发说明](<E:/Github Local/fluguo/DEVELOPMENT.md:337>) 与 [更新日志](<E:/Github Local/fluguo/CHANGELOG.md:1>)。

**结论：先修下载任务身份和两个已复现的 UI 边界，再消除后台弹幕请求和剧库重复写盘。格式治理单开变更，不宜直接对整个仓库执行 formatter。** 当前主应用静态分析没有 error/warning，但两个版别的回归基线都不是全绿。

基线为 `e545f17` 加工作区已有的 36 个改动文件。检查对象是正在构建的根 Flutter 应用、其测试、Go 核心、构建脚本及当前涉及的原生交互；本地覆盖包单独统计。不含历史参考工程 `source/`、`live/` 和上游快照。本次仅新增报告，未改业务代码、测试、生成物、版本或 CI。以下实验用假播放器、内存仓库或临时目录，不以线上站源表现作证据。

## 一、实际执行结果

| 检查 | 结果与口径 |
| --- | --- |
| Dart 格式，Flutter 3.47.4 / Dart 3.13.3 | `dart format --output=none --set-exit-if-changed lib test`：337 个文件中 75 个会变化，退出 1。`lib` 为 51/207，`test` 为 24/130。在这 75 个中，只有 2 个文件同时位于原工作区改动列表：[local_store.dart](<E:/Github Local/fluguo/lib/local_store.dart>)、[app.dart](<E:/Github Local/fluguo/lib/ui/app.dart>)；不能由此推断具体是哪次修改引入了格式差异。 |
| 其他 Dart 目录 | `scripts`：3/3 格式一致；`packages`：32 个中 18 个会变化，均在本地覆盖的 `media_kit_video`。覆盖包不计入主应用 75 个，不建议为了格式扩大与上游的差异。 |
| Dart 静态分析 | `lib`：0 error、0 warning、16 info（9 条构造参数初始化、3 条控制流缺大括号、3 条空感知集合元素、1 条公共 API 使用私有类型）；`test`：无诊断。CI 当前用的 `--fatal-warnings` 两目录均通过；`--fatal-infos` 下仅 `lib` 不通过。`scripts` 另有 14 条 info，主要为命令行输出和相对导入。 |
| Go 格式 / vet，Go 1.25.6 windows/amd64 | `gofmt -l ./native` 列出 8/196 个 Go 文件。`gofmt -l` 有输出仍可能返回 0，门禁应检查输出是否为空。`go vet ./core` 通过；模块级 vet 和两版 race 因本机缺少 cgo 所需的 GCC 未完成，race 实际执行 0 项。 |
| Go 普通回归 | 标准、全源版的 `core` 每版各 301 通过、1 失败、2 跳过（按顶层测试计）。两版是同一个分类回退契约失败；`bridge` 未编译通过，不能把核心包结果当作整模块通过。 |
| Flutter 标准版 | 按项目参数禁用远程图片，递归运行。进度停在 **267 通过、21 失败**，连续数分钟没有新输出后主动停止。不是最终总数。已观察到下载合并 9、下载管理 9、自动导出 1、日志 1、玻璃对话框 1 项失败。 |
| Flutter 全站源版 | 递归运行并启用 `--fail-fast`：**104 通过、1 个断言失败**后结束。首个失败是[日志格式断言](<E:/Github Local/fluguo/test/diary_service_test.dart:36>)：实际多出 `warning` 字段；另有在途桌面滚轮用例标为 `did not complete`，不计作第二个已证实的断言失败。 |
| 本轮改动专项 | 后台播放、键盘翻页、首页顶栏占位、弹幕叠层、弹幕设置这 5 个测试文件，在标准/全站源版各 **16/16 通过**。下文的临时审查探针另算，未加入仓库，也不算进这 16 项。 |
| 脚本与基础检查 | Python 的 `scripts` 测试 34 通过、1 跳过（未指定真实 Gradle）；Android 媒体契约 2/2 通过，是源码/XML 检查而非 Android 运行验收。生成一致性、两版站源能力检查、离线直播线路、本地文件存储检查及 Worker 的 `node --check` 均通过。`git diff --check` 无空白错误。 |

## 二、最值得改的地方

| 优先级 / 证据 | 问题与影响 | 建议与验收 |
| --- | --- | --- |
| 高 · 现有回归复现 | **同一集重新下载后，自动导出可能漏掉新任务。** [下载列表比较](<E:/Github Local/fluguo/lib/download_overview.dart:115>)比较 `id`、`revision` 等，但忽略 `created`；[导出器身份](<E:/Github Local/fluguo/lib/download_auto_export.dart:70>)却包含三者。仅创建时间不同的新对象会被去重，列表继续暴露旧对象。[回归](<E:/Github Local/fluguo/test/download_auto_export_test.dart:14>)期望两次导出 `[1, 2]`，实际只有 `[1]`。 | 统一列表和导出器的任务身份。旧导出未结束时用新任务替换同一集，验收两次按序导出，旧任务不得删除新待办；完全相同的轮询仍不得引发通知。不要靠增大等待时间修复。 |
| 高 · widget 场景复现，源码定位 | **电视短剧首页有续看记录、当前列表为空时分类栏出现布局异常。** 外层在列表为空时插入[分类栏](<E:/Github Local/fluguo/lib/ui/explore/explore_page.dart:305>)；续看卡存在时内层并不走空态，又在[滚动区域](<E:/Github Local/fluguo/lib/ui/explore/explore_page.dart:359>)插入同一个带 `GlobalKey` 的分类栏。1280×720 临时用例触发 Flutter 的语义布局断言；日志首错是 `_needsLayout`，不是对发布版崩溃的证明。 | 让电视布局在每一帧只有一个位置负责分类栏。测试预存有效续看记录，覆盖加载中、返回空列表、返回非空列表三阶段；每阶段只有一个分类栏、无布局/语义异常，遥控器焦点可达且不会跳失。 |
| 高 · widget 实测 | **手机底栏没有给大字体留足高度。** 真实 `AppShell` 在 320×640、线性 2 倍字号下，默认 5 个导航项各出现 **4 逻辑像素的底部溢出**。原因是[底栏项](<E:/Github Local/fluguo/lib/ui/shell/app_shell.dart:1168>)将图标、间距、可缩放标签装在固定 52 高的列里；[页面底部占位](<E:/Github Local/fluguo/lib/ui/app_scope.dart:25>)也依赖固定尺寸。 | 按实际标签行高计算栏高，选择指示器、滚动显隐和内容底部占位共用这个值，不压缩系统字体。320/390 宽、1/2/3 倍字号下应无溢出，最后一行内容不被遮住，所有标签保留点击及读屏语义。 |
| 中 · 请求计数实测 | **仅后台听音时仍请求不可见的弹幕。** [播放状态](<E:/Github Local/fluguo/lib/playback_session.dart:1829>)把“画面可见”和“允许后台播放”合成 `_foreground`；[弹幕同步](<E:/Github Local/fluguo/lib/playback_session.dart:493>)使用后者作为可见性。120 秒假媒体：前台首屏请求 1 次，隐藏后推进到第 31、61、91 秒，音频仍播放，新增分页起点 `[30000, 60000, 90000]` 毫秒。 | 将音频许可与弹幕可见性分离，并在可见性变化时立即同步，不等下一次进度事件。验收：同场景后台新增请求为 0，返回前台按当前位置恢复；单独覆盖画中画、系统暂停、睡眠计时与切集。未测实际流量或电池收益。 |
| 中 · 磁盘实验实测 | **详情元数据没变也会整库重写。** [保存函数](<E:/Github Local/fluguo/native/core/app_catalog_cache.go:316>)命中 ID 就标记 `changed`，随后持有 `engine.mu` [序列化、同步并替换整个文件](<E:/Github Local/fluguo/native/core/app_catalog_cache.go:282>)。Go 临时 overlay 调用真实元数据入口，预置 5,000 条完整记录；连续 10 次读取同一条，两轮实验各 **10 次改写**，文件内容逐字节相同。每轮逻辑写入 `988,945 × 10 = 9,889,450 B`，不是设备物理写入量。 | 比较合并前后可持久化的内容；无变化且无待重试写入时跳过落盘。相同样本目标为 0 次改写；真实变化仍须原子保存、重启可读，且不能吞掉上次写失败后的重试。先做这个小改动，不必先更换数据库。 |

### 第二梯队：值得验证，不作为实测收益

- **桌面键盘。** [全局早期按键处理器](<E:/Github Local/fluguo/lib/ui/app.dart:234>)在非电视模式直接消费 Tab，普通控件的 Enter/Space 也会被消费，PageDown 专项通过并不意味着键盘可完成选片。建议先明确桌面产品策略，再用真实应用根节点测“Tab 到海报 → 打开菜单 → Enter 执行 → 焦点返回”；不要同时改变播放器快捷键和电视遥控行为。
- **直播顶栏。** [顶栏](<E:/Github Local/fluguo/lib/ui/live/live_player_page.dart:840>)高 60，标题固定占 40，留给主播/画质的只有 20；[现有大小屏用例](<E:/Github Local/fluguo/test/live_controls_layout_test.dart:7>)测的是底部控制栏。建议补 320 宽、2/3 倍字号、有主播名的顶栏布局测试，再按文字实测行高改动。不将其与已复现的手机底栏溢出混为一项。
- **暂不重写播放器或玻璃材质。** [横屏播放进度行](<E:/Github Local/fluguo/lib/ui/player/player_surface.dart:132>)已隔离高频回报，正常进度不再触发整页刷新；[短剧封面](<E:/Github Local/fluguo/lib/ui/widgets/cover_image.dart:180>)已有有限解码档位。若调整直播封面，先测桌面连续缩放导致的缓存键数量：[直播封面](<E:/Github Local/fluguo/lib/ui/live/live_room_cover.dart:41>)目前按实际像素取整。没有 profile 数据前，不把组件数量或文件大小当作卡顿证据。

## 三、格式和回归如何治理

1. **先让生成器和 formatter 给出相同结果。** [站源生成器](<E:/Github Local/fluguo/scripts/generate_source_capabilities.py:90>)按完整文本做 `--check`。在临时副本上验证：原始产物检查成功；只格式化生成的 Dart 或 Go 文件后，检查分别因对应文件不同而失败。应先调整生成步骤，或明确只对这两个生成文件采用例外；不能直接手改生成产物再开门禁。现有 CI 在安装 Flutter 前先做生成检查，若生成器依赖 SDK，必须一起协调执行顺序。
2. **纯格式变更独立提交。** 先处理主应用和自有 Go 源码，复跑生成一致性与 formatter，确认第二次运行没有差异，再把 [Verify 格式步骤](<E:/Github Local/fluguo/.github/workflows/verify.yml:37>)从“仅报告”改为阻塞。Dart、Go 生成表均计入上面的数量。更新 CI 的过时注释（14 条 info，实为 16）和[开发文档的分析命令](<E:/Github Local/fluguo/DEVELOPMENT.md:52>)，将 `lib`、`test` 分开分析。上游覆盖包另行决定，不打包进此提交。
3. **区分业务回归与契约差异。** 下载合并的多条失败是期待 `a:34`、实际 `hongguo:a:34` 一类 ID 差异；先确认持久化协议，不为让测试通过而移除来源前缀。Go 的[分类回退断言](<E:/Github Local/fluguo/native/core/app_category_cache_test.go:141>)在两种离线输入下各重复 3 次均失败；[实现](<E:/Github Local/fluguo/native/core/app_categories.go:292>)与[文档](<E:/Github Local/fluguo/DEVELOPMENT.md:326>)一致：无有效旧分类时返回错误，而测试要求静默返回“全部”。应按已确认契约修断言，保留有旧分类、下次可重试的覆盖。下载管理失败按单用例串行复测；不能把 21 条失败一律解释为生产缺陷，也不能把历史红单变成跳过清单。
4. **最后量真机收益。** 在相同设备、刷新率和媒体下，改前改后各重复至少 3 次：冷启动、列表滚动、打开同一详情 10 次、播放与后台切换。记录 build/raster p95、超预算帧比例、RSS、后台弹幕请求数及缓存写入次数；60 Hz 预算约 16.7 ms，120 Hz 约 8.3 ms。[现有 HUD](<E:/Github Local/fluguo/lib/ui/widgets/perf_hud.dart:37>)按固定 60 Hz 统计，不能直接拿它的 jank 百分比判断 120 Hz。未执行四端打包、系统媒体面板实机测试、读屏实机测试或真机 profile；本报告不承诺 FPS、内存或耗电改善幅度。

### 复查入口（不回写业务源码）

```text
python -B scripts/generate_source_capabilities.py --check
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib
dart analyze --fatal-infos test
flutter test --no-pub --dart-define=DISABLE_REMOTE_IMAGES=true
flutter test --no-pub --dart-define=DISABLE_REMOTE_IMAGES=true --dart-define=ALL_SOURCES=true
gofmt -l ./native
```

Go 在 `native` 目录执行 `go vet ./...`、`go test -race ./...`，全站源版另加 `-ldflags="-X duanjuapp/native/core.buildAllSources=true"`；Windows 先配置 MinGW-w64，或在项目 Linux CI 上补齐。Dart/Flutter 复查应使用上面的固定版本及现有锁文件。本次保留了所有原有工作区文件，不包含修复提交。
