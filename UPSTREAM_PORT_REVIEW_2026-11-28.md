# 上游增量移植评估（2026-11-28）

本轮结论：优先吸收小窗与空页修复，再做桌面输入、新季提醒等增量功能。保留本地播放会话、原生站源、窗口管理和界面风格，按功能适配，不整体替换上游文件。

后续已按用户指定实施七项：小窗切集显隐、追剧/历史空页滚动、Windows FFmpeg 退出保护、官方新季提醒、窗口最大化恢复、已观看标题弱化、发现页横幅开关。下文第 1～7 节保留的是实施前评估，不能将其中“尚未实现”当作当前状态。实际变更与验证见 DEVELOPMENT.md 的「上游七项增量移植」记录。

- 窗口恢复扩展现有 window.json，不引入第二套窗口管理；Windows 读取原生普通窗口位置，保留最大化前的大小。
- 官方新季提醒使用现有 Go 分季接口、独立 24 小时检查和失败退避。旧标题候选保留兼容，但不触发官方提醒；首次检查不提示已有季，已读记录不会因短暂缺项重置。
- 标题弱化表示当前用户有观看记录；横幅开关默认开启，关闭后首条推荐回到网格，支持两种本地存储和备份。
- 原有预缓存直接复用播放器路径保留；未整体同步 source/，未改用户提供的参考目录。

## 1. 对比基线

- 本项目：`e03973a479b3e9695c8afd64c6e772b7bb0d3a2b`（DC179）。
- 上一次已核对的上游：`6d4516e691d64f91992f6dc04fdd498b383e46ef`。
- 本次通过 `git ls-remote upstream refs/heads/main` 和 fetch 核实的上游：`ffc2b6d6cbcd95c149d898499e19cd9750bc875d`，提交时间 **2026-11-28 00:40:10 +08:00**。
- 该区间有 **44 条提交（含合并提交）**，涉及 123 个文件；上游版本为 `2.0.5+117`。
- `source/` 当前是本仓库内的参考目录，不是独立 Git 工作树。在其中执行 `git log` 得到的是本项目历史，不能当作上游提交历史。
- 抽查 `source/` 的 CHANGELOG、playback_session、desktop_player_bindings、follow_updater、Windows flutter_window，共 5 个关键文件，Git blob 均与上述最新上游一致。不是对整个目录逐文件一致性的声明。
- 原有 `source/` 更新全部保留。本轮 fetch 只更新远程跟踪引用，没有合并、切分支或覆盖源码。

## 2. 优先修复与优化

### A1. 小窗切集时控制栏误弹出、初始生命周期判断

**推荐第一批，适配成本低。** 对应 `17e3df4`、`e58918c`，以及 `40b7009` 中的可见性补修。

- 本地 [mini_player.dart](<E:/Github Local/fluguo/lib/ui/player/mini_player.dart:132>) 使用 `_hover || !playing || _seekValue != null` 决定控制栏显隐。切集、打开媒体时播放器暂时不处于 playing，也会使控制栏出现。
- 上游 [mini_player.dart](<E:/Github Local/fluguo/source/lib/ui/player/mini_player.dart:154>) 改用 `session.paused`，以用户的暂停意图判断。适合借鉴，不需要改变媒体打开和切集时序。
- 上游还把 `playerVisible(null)` 视为可见；本地尚未包含。可覆盖尚未收到生命周期状态时，进入/恢复小窗不应被误判为后台的情况。
- 本地已有 `_playIntent`、`paused` 和复杂的暂停/取消流程；落地时应逐项核对通知是否完整，不能直接覆盖上游整个 PlaybackSession。
- 验收：预缓存命中和未命中切集均不自动弹出控制栏；手动暂停、鼠标进入、拖动进度仍能显示；生命周期为空及退出小窗不意外暂停。

以上是源码确认的触发条件，本轮未在 Windows 实际播放中复现。

### A2. 追剧/历史空页的额外滚动与底栏收起

**推荐第一批，适配成本低。** 对应 `f4eeb3e`。

- 本地 [追剧页](<E:/Github Local/fluguo/lib/ui/follow/follow_page.dart:534>) 和 [历史页](<E:/Github Local/fluguo/lib/ui/history/history_page.dart:576>) 的空态 `SliverFillRemaining` 后，仍会追加底部 `SliverPadding`。
- 上游将这段留白放进非空分支，避免空态填满屏幕后再增加可滚动距离。
- 本地底栏控制已有滚动范围钳制，但额外 padding 本身产生的是有效滚动距离，仍值得修正。
- 适配时保留本地 `bottomBarInset`、编辑工具栏和多源筛选；验证真正空库、筛选无结果、编辑状态、内容未满一屏。无需整体移植上游列表。

### A3. Windows FFmpeg 运行库在退出时提前卸载

**推荐作为第一批稳定性候选，需 Windows 运行验收。** 对应 `b2b129e` / PR #265。

- 上游 [OnDestroy](<E:/Github Local/fluguo/source/windows/runner/flutter_window.cpp:459>) 在销毁 Flutter 控制器前，以 `GET_MODULE_HANDLE_EX_FLAG_PIN` 固定已载入的 `libffmpegkit.dll`，防止退出期间提前卸载。
- 本地 [OnDestroy](<E:/Github Local/fluguo/windows/runner/flutter_window.cpp:448>) 没有此处理，且 [打包清单](<E:/Github Local/fluguo/scripts/package_release.py:189>) 同样包含该运行库，具备适用基础。
- 这是进程退出阶段的库生命周期保护，不是停止 FFmpeg 任务或释放所有媒体资源的替代品。
- 本轮没有本地退出崩溃堆栈，不能断言本项目已发生同一崩溃。应先补窄范围保护，再验证播放后退出、转换/合并后退出、小窗退出及正常进程结束。

### A4. Windows 记住最大化状态

**值得补齐，适配成本中。** 对应 `b2b129e`、`001c4e2`。

- 本项目已经通过 [DesktopWindowState](<E:/Github Local/fluguo/lib/desktop_window_state.dart:13>) 保存普通窗口位置和尺寸，包含多屏校验、限频、串行写入与退出落盘。
- 现有 `_capture` 在窗口最大化/最小化时直接返回；保存格式没有 maximized 字段，启动也只恢复普通边界。
- 上游借助 [WindowFrame](<E:/Github Local/fluguo/source/windows/runner/flutter_window.cpp:338>) 保存普通窗口边界和最大化状态，并区分全屏/小窗之前的窗口信息。
- 应扩展本地 `window.json` 读写和恢复流程，兼容旧格式；不要再引入第二套 `window_frame.dart` 与 SharedPreferences 存储。
- 验收：最大化退出重开、最大化后最小化退出、全屏/小窗退出、移除副屏、DPI 改变；保留本地窗口置顶和贴边恢复逻辑。

### A5. 解码诊断逐属性容错

**可小范围借鉴，优先级低于播放行为修复。** 对应 `b916485`。

- 本地已有 [PlaybackVideoDiagnostics](<E:/Github Local/fluguo/lib/playback_video_diagnostics.dart:10>)，具备 trace 开关、白名单、脱敏及过期查询失效，不需要重复引入整套诊断设施。
- 但本地以 `Future.wait` 统一读取属性，其中一个属性读取失败会丢弃本次全部结果。
- 上游逐项记录不可用/失败，并增加请求的 `hwdec` 与实际的 `hwdec-current` 对照，能帮助识别硬解配置未生效或回落。
- 建议只吸收逐属性容错和配置/实际值对照；保留现有采样、权限和日志开关，不直接输出任意 mpv 日志文本，也不必同步上游日志容量变化。

## 3. 值得增加的功能

| 功能 | 上游提交与入口 | 本地缺口 / 适配建议 | 成本 |
| --- | --- | --- | --- |
| 桌面播放器自定义键鼠 | `d3cda04`、`107c196`、`5933c15`、`ffc2b6d`；[绑定模型](<E:/Github Local/fluguo/source/lib/desktop_player_bindings.dart:6>)、[输入控制器](<E:/Github Local/fluguo/source/lib/ui/player/player_input.dart:17>) | 每个动作两个绑定槽，键盘/滚轮/中键/侧键统一去重，支持恢复默认和滚轮切集防连跳。本地仍以固定键位为主，推荐第二批优先做 | 中 |
| Esc 与鼠标后退侧键返回 | `53450ba`；[上游返回分发](<E:/Github Local/fluguo/source/lib/ui/app.dart:190>) | 本地 Esc 依赖焦点所在 Navigator，没有通用鼠标侧键返回。可补无焦点、嵌套导航回退；与自定义侧键统一事件消费，避免切集与返回同时触发 | 中 |
| 官方新一季上线提醒 | `b2b183b`；[上游更新器](<E:/Github Local/fluguo/source/lib/follow_updater.dart:67>)、[提醒模型](<E:/Github Local/fluguo/source/lib/follow_state.dart:71>) | 本地会切季、能连播下一季，但已完结追剧会被更新器跳过，`hasUpdates` 只看集数。应独立检查官方季列表，首轮只建基线，之后才提示新季 | 中 |
| 已观看标题弱化显示 | `2b9ffbd`；[上游卡片](<E:/Github Local/fluguo/source/lib/ui/widgets/drama_tile.dart:151>) | 本地发现/搜索卡片尚未接入 watched 标记；建议做可选显示，复用当前主题。上游定义是“有观看记录”，不等同“整剧看完” | 低 |
| 发现页横幅开关 | `5ddaed2`；[上游 ExploreFeed](<E:/Github Local/fluguo/source/lib/explore_feed.dart:58>) | 控制继续观看/今日推荐卡片。补偏好与备份，同时验证本地分类各自滚动位置、顶部占位和骨架页，避免重新出现顶部大空白 | 低至中 |
| Android 手机播放页返回主页 | `edd74fe`、`23d7971`；[上游按钮](<E:/Github Local/fluguo/source/lib/ui/player/player_home_button.dart:6>) | 本地无对应统一入口。可以新增，但 root popUntil 不一定符合本地 Tab 子导航、详情回退和剧场播放器接管，应走本地导航规则 | 中 |
| 宽屏详情独立滚动、长选集分组收纳 | `c70e022`；[上游详情页](<E:/Github Local/fluguo/source/lib/ui/detail/detail_page.dart:669>) | 可提取左右独立滚动及分组过多时横滚/选择入口；保留本地布局外观、跟手翻页和电视焦点。无需以接入完整听书功能为前提 | 中 |

桌面输入适配有几处必须保留的现有行为：

- 本地右方向键按住有倍速行为，松手走自己的快进/结束倍速逻辑；不能直接被上游的重复快进覆盖。
- 竖屏剧场的滚轮会驱动翻页和邻集准备，不能简单统一成直接 `play(index)`。
- 短剧、直播、电视遥控器、屏幕锁、输入框和选集列表各有输入边界。建议先支持桌面短剧，明确直播动作映射后再扩展。
- 新的输入层只调用既有播放命令，不改变预缓存与播放器交接。

新季提醒适配有几处与上游架构不同：

- 使用本地 [原生官方分季接口](<E:/Github Local/fluguo/native/core/app_seasons.go>)，不依赖 JS 模块或按标题猜同系列。
- 上游使用独立的 24 小时新季检查及失败退避；本地已有前台限制、每轮数量上限和用户代次校验，应继续保留。
- 本地保留了旧系列候选缓存和 [批量元数据更新](<E:/Github Local/fluguo/lib/metadata_refresh.dart>)，需要兼容既有 `seriesSeasons` 和备份，不能照搬删除 `hongguo_series.dart` 的整套改动。
- 测试首轮静默、完结旧季发现新季、尚未上线的新季、已观看/已收藏新季、接口失败、换用户和权限变化。

## 4. 已有能力，不重复移植

| 上游内容 | 本地实际状态 | 结论 |
| --- | --- | --- |
| 后台播放、系统媒体控制 | 已有 Android/Windows 等平台接入及本地播放意图管理 | 不能列为本轮新增能力 |
| 关闭后台播放时贴边暂停仍应生效（#249） | [MediaControls](<E:/Github Local/fluguo/lib/media_controls.dart:143>) 已区分本地状态和系统发布；另有贴边暂停租约与意图代次 | 保留本地实现，仅补上面 A1 的可见性边界 |
| 老旧显卡缺 Vulkan 入口（`bea8923`） | [本地 CMake](<E:/Github Local/fluguo/packages/media_kit_libs_windows_video/windows/CMakeLists.txt:106>) 已随 ANGLE 分发同包的 `vulkan-1.dll` | 无需重复下载/增加第二份 DLL；若实包仍报错，检查打包产物 |
| 记住普通窗口位置、尺寸 | 已有 DesktopWindowState | 只补最大化状态 |
| Android 直通硬解、偏蓝着色器 | 已完成本地适配，主/邻集/第三播放器共用创建时配置 | 不覆盖既有输出配置 |
| 回环取流监听恢复 | 已移植并补充本地会话、取消与租约边界 | 不以整文件同步覆盖 |
| 官方选季、手动续播、季末连播 | 已有实现及专门测试 | 新缺口是主动新季提醒 |
| 常驻 FFI 池、弹幕合并与表情、站源代理、跟手分页 | 已在此前版本适配或另行优化 | 不重复计入本次移植收益 |

## 5. 建议单独立项或暂缓

| 项目 | 原因 |
| --- | --- |
| iOS 系统画中画与 VideoToolbox 原始帧（`d637100`、`5af093a` 等） | 需要自定义 libmpv、Swift 纹理与 PiP、构建脚本配套，详见 [上游说明](<E:/Github Local/fluguo/source/native/ios_mpv/README.md>)。需要 Apple 构建和 iPhone/iPad 验收，不能只复制一个开关 |
| iOS 工具链和安全区（`59cf658`、`dbef511`） | 水平安全区修正可以独立评估；工具链升级应单独验证，不必与 Android/Windows 功能捆绑 |
| Linux / AppImage（`8493adf`） | 是完整平台扩展，涉及 FFI、媒体插件、窗口能力、FFmpeg 依赖与发布。上游包不能替代本地全站源/直播/下载链路的 Linux 验收 |
| 模块更新提示、镜像、局域网模块安装、红果静默云更新 | 本地主要是 Go 原生站源，上游是 JS 模块。云更新还依赖自有更新服务与签名公钥，详见 [module_cloud_update.go](<E:/Github Local/fluguo/source/native/core/module_cloud_update.go:22>)。不能把上游安装入口直接接到本地 provider |
| 老板键 | 可选桌面功能，但当前并未接入。它与自定义键鼠可以拆开；需要原生热键注册及与本地暂停/恢复、贴边处理共存 |
| 完整听书/音频播放页 | 本次有布局增量，但音频页本身早于本轮基线。需要媒体类型模型、站源、下载/选集/小窗/电视整条链路，适合作为产品功能独立做 |
| Windows D3D11 后端、DLNA 投屏 | 均是之前已有的上游功能，不是本轮新增。D3D11 会替换本地 ANGLE/软件回退与纹理生命周期补丁；投屏需要发现、转发和远程播放状态管理，均不适合顺带全量同步 |
| 平板首页搜索框改为按钮（`2aa6a28`） | 是交互取舍，本地已有宽屏搜索和最近搜索；没有必要为了跟随上游替换现有入口 |

## 6. 对预缓存和切集体验的结论

上游当前 [备用播放器预开](<E:/Github Local/fluguo/source/lib/playback_session.dart:1110>) 也使用 `open(..., play: false)`，与本地刚修复的方向一致。不能把“上游当前仍在静音预播并推进进度”作为本次判断。

本地 [邻集准备](<E:/Github Local/fluguo/lib/playback_session.dart:2013>) 预开后暂停在开头，[交接路径](<E:/Github Local/fluguo/lib/playback_session.dart:1706>) 对正常预缓存直接复用；只有异常 playing/completed 或位置超过 150ms 才回零。该流程另有三槽预算、取消、历史续播和剧场接管保护。

因此本次没有必要用上游 PlaybackSession 替换本地实现。小窗显示修复、键鼠输入、新季提醒都可以保持这条快速交接路径。预缓存尚未准备完成或媒体/设备输出异常时仍可能等待，源码对比不能证明所有设备绝对零间隔。

## 7. 建议实施顺序与验证

1. **第一批稳定性**：A1 小窗显隐与初始可见性、A2 空页留白；A3 FFmpeg 退出保护配合 Windows 运行验证。范围小，不必更换解码后端。
2. **第二批桌面体验**：自定义键鼠、Esc/侧键返回、最大化状态恢复。保留窗口数据格式兼容和本地输入习惯。
3. **第三批追剧与显示选项**：官方新季提醒、已观看提示、横幅开关；宽屏详情优化按使用需求加入。
4. iOS、Linux、模块架构、投屏与完整音频链路分别评估，不与以上小改动绑定。

以上为最初评估阶段的比较依据。后续实施已增加 Flutter 与 Go 回归；本机 Windows 构建尝试未完成，未做真机运行验收。最终结果以 DEVELOPMENT.md 的实施记录为准。
