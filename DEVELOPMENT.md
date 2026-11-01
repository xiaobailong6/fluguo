# 开发指南

## 环境

Flutter `3.47.4`、Dart `3.12+`、Go `1.24.1+`、Python `3.10+`。

- Android：JDK 17、SDK 36、NDK `28.2.13676358`
- Windows：Visual Studio C++ 桌面组件、MinGW-w64 x64
- iOS：macOS、完整 Xcode、CocoaPods
- macOS：完整 Xcode、CocoaPods，打 dmg 需 `pip install dmgbuild Pillow`；`xcode-select` 指向 Command Line Tools 时 `build_macos.py` 会自动改用 `/Applications/Xcode*.app`，也可以在系统层面执行 `sudo xcode-select -s`

构建脚本对子进程默认设置 `GOPROXY=https://goproxy.cn,direct`、`GOSUMDB=off`，同名环境变量可覆盖。

## 调试运行

Flutter 运行前必须先编译对应平台 / 架构的 Go 核心：

~~~sh
python3 scripts/build_native.py --platform android --abi arm64-v8a
flutter pub get --enforce-lockfile
flutter run
~~~

调试 FlGuo 全站源版：`build_native.py` 加 `--all-sources`，再 `flutter run --dart-define=ALL_SOURCES=true`；iOS 对应 `build_ios.py --core-only --all-sources`，macOS 用 `build_native.py --platform darwin --all-sources`。版本是编译期开关，Dart 常量和 Go 编译参数必须一致，应用启动时会校验，避免混装原生库。

## 出包

~~~sh
python3 scripts/build_android.py                 # FlGuo 标准版：红果、饭果、爽果
python3 scripts/build_android.py --all-sources   # FlGuo 全站源版
python3 scripts/build_android.py --abi arm64-v8a
python scripts/build_windows.py [--all-sources]
python3 scripts/build_ios.py [--all-sources]
python3 scripts/build_macos.py [--all-sources]
python3 scripts/build_ios.py --core-only [--simulator]
python3 scripts/build_ios.py --export-options /path/to/ExportOptions.plist
~~~

产物在 `dist/android`、`dist/windows`、`dist/ios`、`dist/macos`，标准版（红果、饭果、爽果）为 `FlGuo-<版本>-<平台/架构>`，全站源版为 `FlGuo-all-sources-<版本>-<平台/架构>`。Windows 构建输出为 `FlGuo.exe`，ZIP 内按版本保留 `FlGuo.exe` 或改名为 `FlGuo-all-sources.exe`。macOS 出 arm64 + x86_64 通用 dmg，内含 `FlGuo.app` 或 `FlGuo-all-sources.app`；dmg 的安装窗口由 `dmgbuild` 写入 `.DS_Store`，打包机需要 `pip install dmgbuild Pillow`。默认 ad-hoc 签名；有 Developer ID 时用 `package_release.py --platform macos --identity` 重新签名并公证。本机 Android 签名使用 `android/key.properties`（不入库）。

显示名称统一为 FlGuo，但 Android applicationId、iOS bundle identifier、macOS 打包后的 `com.duanju.hongguojian` / `com.duanju.zhenguojian` 保持不变。Windows 资源的 CompanyName/ProductName 仍保留旧值，因为系统插件用它们定位既有数据目录；FileDescription、窗口标题及 EXE/ZIP 文件名使用新品牌。数据目录、备份 app 字段及更新 API edition 标识均不随品牌更名。

其他脚本：`generate_brand_assets.py` 从 `scripts/brand_icon.png`（原 `duanshipin.png`，226×226）生成 Android/iOS/Windows/macOS 图标和 FlGuo 电视横幅，只需 Pillow。执行 `python scripts/generate_brand_assets.py`，可用 `--font` 指定横幅字体，`--output` 指定校验输出目录；iOS 图标白底不透明，Android 自适应前景留安全边距并生成单色遮罩，Windows ICO 含多个尺寸。源图是位图，放大到平台要求尺寸不等于提高原始细节。`clear_app_data.py`、`clear_catalog_cache.py` 清理 Windows 上的应用数据和剧库缓存。

## 检查与测试

~~~sh
dart format --output=none --set-exit-if-changed lib test
dart analyze --fatal-infos lib test
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true --dart-define=ALL_SOURCES=true
cd native
go test -race ./...
go test -race -ldflags="-X duanjuapp/native/core.buildAllSources=true" ./...
~~~

Flutter 测试一律带 `DISABLE_REMOTE_IMAGES=true`，避免加载站源图片。数据兼容、权限和核心逻辑使用单元测试；导航、手势和批量管理使用针对性 widget 回归，公共假仓库在 `test/support/`。测试编译失败不能记为测试通过。

- 播放UI回归：`test/episode_grid_layout_test.dart` 覆盖280/320/390/800宽、1–3倍字体、角标避让、拖选及字号变化后的当前集定位；`test/playback_seek_controller_test.dart` 覆盖拖动局部重建、目标回报、超时、新拖动与销毁清理。
- 历史/图片性能回归：`test/history_sort_cache_test.dart` 覆盖重复筛选不再读取排序、记录/权限/用户/过期边界失效及页面通知；`test/cover_decode_size_test.dart` 覆盖DPR分档和重试缓存清除。封面解码只用128/192/256/384/512/768/1024档，模糊背景128档，不按任意窗口像素生成缓存变体；未做真机profile测量时不能宣称帧率或内存收益。

## 架构

Flutter 界面 + Go 原生核心。站源请求、解析、签名、缓存、下载调度和播放代理都在 Go 里完成，Dart 只负责界面、播放器和本地用户数据。

- **FFI**：`native/bridge` 以 `-buildmode=c-shared` 只导出 `DuanjuRequest(json) -> json` 与 `DuanjuFree`。`lib/core_bridge.dart` 的 `NativeRepository` 把每次调用编码成 `{"action": ...}`，在 `Isolate.run` 中调用；Go 侧在 `native/core/app_runtime.go` 的 `NativeRequest` 里按 action 分派。新增能力两端都要改。Android 与 Windows 动态加载（`libduanju_core.so` / `duanju_core.dll`）；iOS 与 macOS 改成 `-buildmode=c-archive` 静态库（`ios/DuanjuCore`、`macos/DuanjuCore`）链进主程序，Dart 侧用 `DynamicLibrary.process()` 查符号，避免 dylib 的签名与库校验问题。
- **Go 核心**（`native/core`，单包）：`provider_*.go` 各站源，`app_*.go` 运行时与业务（目录缓存、下载、弹幕、存储、设置），`network_*.go` HTTP 客户端、DNS、CDN、限流。`app_stream.go` 在本机起播放代理，重写 HLS playlist、透传 Range，并处理带密钥的媒体。
- **Flutter**：界面在 `lib/ui/`（按页面分子目录，入口 `lib/main.dart` → `lib/ui/app.dart`），逻辑层平铺在 `lib/`，状态管理只用 ChangeNotifier。
- **播放与下载**：播放器用 [media_kit](https://github.com/media-kit/media-kit) / libmpv；每集下载完由 [FFmpegKit min-gpl](https://github.com/sk3llo/ffmpeg_kit_flutter)（含 GPL 媒体组件）转成单个 mp4，只换封装、不重新编码，不参与正常播放。
- **本地数据**：存储格式须兼容旧版。本地快照遇到未知键会整体报错，新增设置若要兼容旧版须存为快照外的独立键。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `lib/ui` | 界面：主题、导航壳、各页面、播放器、公共组件 |
| `lib` | 逻辑层：FFI、站源目录、播放、下载、本地存储与用户 |
| `native/core`、`native/bridge` | Go 站源核心、缓存、下载、播放代理及 C ABI |
| `android`、`windows`、`ios`、`macos` | 平台工程与资源 |
| `packages/media_kit_libs_windows_video` | 本地覆盖的 Windows 媒体依赖插件 |
| `scripts` | 构建、图标生成与数据清理脚本 |
| `test` | 逻辑层测试 |

## 站源开发约定

站源是 Go 原生 provider（`native/core/provider_*.go`），不是运行期加载的脚本。新增站源需接入：`provider_huangguo.go`（常量 / 白名单 / `canonicalProviderSource` / `GetHuangguoChapters`）、`provider_media.go`（baseURL / host 反查 / 播放分派）、`app_categories.go`、`app_cover_metadata.go`、`app_runtime.go`（Config 字段 + 目录 / 搜索 / 详情分派 + 空页放行），并在 `lib/models.dart` 登记 `SourceSite`。

Go RE2 正则**不支持 lookahead**。解析多线路播放列表时不能用 `(?=...)` 分段，否则会消耗下一段开头；应改用显式字符串截断（从容器标记之后查找下一段标记）。

## 直播

直播在 Dart 侧实现：`lib/live_models.dart` 是轻量数据契约，`live_bilibili.dart`、`live_douyu.dart`、`live_huya.dart`、`live_douyin.dart` 是平台适配，`live_feed.dart` 是列表状态。加平台实现 `LivePlatform` 并登记 `livePlatforms`，不要引入 pure_live 的完整播放器或 GetX 栈。

哔哩哔哩只用三个匿名接口：`room/v1/Area/getList`（一级分区）、`room/v1/Area/getRoomList`（按 `parent_area_id` 分区列表，`0` 是热门）、`xlive/web-room/v2/index/getRoomPlayInfo`（线路）。**不要**改成需要 WBI 签名的 `xlive/web-interface/v1/second/getList`：匿名请求会回 `-352` 风控，而 `getRoomList` 同样按一级分区排序、还不用签名。播放时 `Media(url, httpHeaders:)` 必须带 `Referer` 和 `User-Agent`，否则 CDN 回 403。

斗鱼使用平台下发的 getEncryption 描述符和 getH5PlayV1，设备编号在描述符、签名和 Cookie 中保持一致；虎牙从房间页解析流信息并按 fm 模板签名，不延长服务器 wsTime。各平台画质映射到语义选项，返回的实际档位与请求不一致时不能伪称切换成功。

直播播放使用 `ui/live/live_navigation.dart` 在入口所在的 Navigator 上 push：直播列表/收藏留在直播栈，最近观看/历史留在来源栈；不能为了播放切换 Tab 或 popUntil 清掉来源页。收藏通过 LocalStore/LocalSnapshot 的用户级 `liveFavorites` 保存，备份只包含平台和主播展示数据，不含临时 URL、签名或 Cookie。

应用外壳通过当前 Tab 的 `NavigatorPopHandler` 分发系统返回；子路由存在时，外层 PopScope 不得再执行切回短剧的根页面返回逻辑。子页因全屏/画中画拒绝 pop，也必须消费本次返回，避免一次事件重复出栈。

### guoapp 增量源验证

- 新增短剧适配集中在 `native/core/provider_imported.go`，饭果、爽果已包含在标准版；其余站源沿用 `ALL_SOURCES` / `buildAllSources` 开关。现有 provider（尤其红果）不重写。
- 在 `native` 下运行 `VERIFY_IMPORTED_SOURCES=1 go test ./core -run '^TestImported' -count=1 -v`（PowerShell 用 `$env:VERIFY_IMPORTED_SOURCES='1'`）。验证目录、详情、分集及有限媒体前缀，HLS 继续请求分片，不请求封面。
- 爽果使用实际分类及翻页路由，搜索端有安全验证，因此仅匹配精选目录，不伪造全站搜索。伍果样本 CDN 404、河果样本媒体字节经过编码，未作为可直接播放源登记；其他未完成播放链路验证的候选也不登记。
- `lib/live_guoapp.dart` 只接入秀果面板的映客分类，仅全站源版注册，标准版不显示；每次解析重新获取临时 FLV，空列表尝试备用地址。电视及其他未经验证分类不开放。

### 直播线路与交互

- `LiveStream.lines` 是当前画质下的平台候选线路，`lineId` 是当前实际线路。`LivePlatform.resolveLine` 重新取流后再选线，斗鱼用 CDN 标识重签；不要把低画质地址混进当前画质的线路列表，也不要持久化带签名 URL。
- `live_player_gestures.dart` 统一单击菜单、双击播放及小窗还原，原生播放器页负责全屏时隐藏菜单和 4 秒收起计时。收藏与直播共享 `live_room_card.dart`，仅收藏叠平台标记和管理选择状态。
- LivePlaybackControls 将线路/画质/PiP/全屏放入 mainAxisSize.min 的右侧Row，再用Expanded+Align.centerRight整体贴右；只有组内画质使用Flexible，避免与左侧Spacer平分空白导致线路漂到中央。全屏使用LiveControlPill深色半透明底、淡边、白字，长画质省略，不创建BackdropFilter。
- LiveScreenLock 在全屏左侧居中显示小锁，锁定用AbsorbPointer/ExcludeFocus/ExcludeSemantics隔离底层输入，小锁单独在上层保持可点击并接管焦点，确认键可解锁，其余键不传到导航。LivePlayerPage锁定时隐藏播控、取消收起计时，并在播放/选线/画质/PiP/全屏/返回处理函数额外校验_screenLocked；视频层与续签/后台暂停不销毁或停止。普通模式和小窗不显示锁，解锁恢复菜单及闲置收起。
- test/live_controls_layout_test.dart覆盖普通/全屏、320/1200宽、长短画质及2倍字体的贴右/无间隙/无溢出；test/live_screen_lock_test.dart覆盖触摸、画面双击、快捷键、返回逻辑键、确认解锁和禁用锁层后恢复输入。
- `dart scripts/check_live_lines.dart` 检查解析、去重、画质隔离与签名；加 `--network` 会请求三平台目录及默认/备用线路媒体头，不请求封面，不输出签名 URL。需要正常解析项目依赖。
- 直播浏览偏好单独保存在用户级 `liveBrowsePreferences.<profileId>`，记录最近平台和各平台一级分类 parentId。异步分类加载后按 ID 恢复，失效回首项；仅本机浏览偏好，不进入旧快照白名单或视频播放偏好。
- 抖音两版均注册；首页解析 `__pace_f` / `__next_f` 分类，分区 ID 使用 `id,type`，无子类提供平台全区入口。`DouyinClient` 合并匿名首页请求、内存保存 Cookie，兼容非标准 Secure 属性；签名针对原始编码 query 与一致 UA，不二次编码，不输出签名 URL。分类页每页 15 条，由 `LivePlatform.pageSize` 驱动末页判定。
- 抖音取流重新请求当前房间，按 SDK key 关联新旧画质结构，排除纯音频，同画质 FLV/HLS 才可作为线路。接口空响应/非零状态不能当正常空列表，匿名搜索受限时显示平台错误。本轮网络验证经系统代理完成，代理只注入临时探测脚本，生产代码未写死代理。
- 分区图片统一经 `LivePlatform.categoryPicture` 按需读取，其他平台默认不增加请求。抖音优先目录图片，否则 `DouyinCategoryPictures` 请求该 `id,type` 分区一条直播记录作动态背景；最多两路并发、32项待处理、64项缓存，成功缓存10分钟、空结果/失败1分钟。禁用远程图片时不请求，切换分区不展示上个分区旧图。临时联网脚本实测三个游戏分区图片状态与文件头通过。
- `lib/live_douyin_sign.dart` 适配 Pure Live 的 AGPL-3.0 签名实现，独立 SM3、无新增第三方运行依赖；分发须保留 `THIRD_PARTY_NOTICES.md` 与对应源代码/许可证义务。

### 剧场首集预览

- `TheaterPage` 使用竖向 `PageView` 切换推荐短剧；底部玻璃「看全集」与首集结束均可创建 `PlaybackHandle` 并压入现有 `PlaybackPage`。手动进入继续首集当前位置，首集结束则多集从 index=1/position=0 继续，单集从 index=0 开始；同一完成事件只触发一次，返回不重入。返回时保留原推荐批次及预览位置，避免正式观看记录更新立即重排来源页。
- TheaterFeed 使用所有允许来源的独立游标增量追加，红果recommendations.more和普通catalog均可翻页；loadingMore合并意图，共享两个请求槽。每次最多四轮/每轮两页，失败停下重试，空/重复页关闭游标。新候选按70/30兴趣匹配与探索抽样，只有分页耗尽才分级放宽曝光限制循环，不放宽权限/hidden/完成过滤。候选上限600，队列60，保留当前项/过去十项；UI按pick对象校正裁剪后的索引，纯追加不jump，极小片库重复项也重启首集预览。
- TheaterCandidateCache按用户保存最多48项/128KB元数据、两天过期，白名单只含卡片展示字段，不含Episode.raw、播放URL或Cookie。ExploreFeed复用已加载卡片预热，不新增请求；按profileEpoch/目录身份拒绝旧响应，后台写入不通知根UI。TheaterFeed同步读缓存并按权限/hidden/完成筛选，优先未曝光，缓存池已全曝光时可用合规旧项首屏兜底；首屏单页不force，后台更新不重排当前项。
- TheaterDetailCache仅在内存保存3部/10分钟详情；首集成功open/play后warmNext紧邻下一部，合并主请求与预读；最多一个next预读加主worker。暂停时同时清空缓存与页面detail引用，保留position，恢复重新取有效详情；旧在途请求仍占槽但不回填，不存临时媒体地址。
- _nearEnd与TheaterFeed.setActive共同响应foreground/TickerMode/route-current：隐藏使feed代次失效，旧请求结束不再派发后续缓存/分类/分页，恢复按需继续；不取消仓库共享请求。ExploreFeed目录/用户切换后的旧回包不刷新当前用户元数据或预热缓存。
- `TheaterPreview` 独立于 `PlaybackSession`，只解析第一集，不保存观看记录、不预取/自动播放第二集。网络请求采用单个工作通道与最新意图标记，媒体 stop/open/play 串行执行；旧请求可释放但不能启动声音。
- `MediaKitPreviewBackend` 只创建一个播放器，VideoController先于open；TheaterPreview创建backend后立即_notify挂载Video，然后才await open，防止首个open与渲染表面相互等待。open(play:false)后验证代次再播放，离开/锁定/撤权仍停止释放。
- 手机剧场不预留bottomBarInset，全集入口距系统安全区底边12、两侧28、最大宽420；局部玻璃使用22%透明黑底、淡边线，不复用主题灰白染色。剧名仅在左上，移除固定首集预览标题及推荐理由。
- 手机剧场不构建底栏，旧TheaterNavigationToggleNotification已失效，中央单击无导航行为。TheaterPage.onExit与系统返回共用shell分层返回：全集先pop，剧场回短剧保留栈/滚动并持返回锁到帧末；短剧隐藏时回首个非剧场可见项，仅剧场可见双返回退出。桌面/电视导航保留。
- PlaybackPage手机及竖向平板默认统一PortraitPlayerPage、contain黑底；WideVideoFullscreenButton仅对已知ratio>1的媒体显示，设_padFullscreen后切现有PlayerPage同一handle。退出先清全屏并releaseOrientation，恢复手机lockedPortrait等既有模式，不另建播放会话。
- navigationVisible为全局持久化配置，与navigationOrder按稳定名字组合；隐藏项不删除排序和Navigator状态。至少保留一个菜单，写队列内再次校验最后一项；坏值/空列表回退全开。Shell启动、当前项隐藏、返回和TV焦点只选可见菜单，保存进度不触发外壳重建；备份保留排序/显隐，旧备份缺字段回默认。
- `showDramaDetails` 为快照外的本机界面偏好，默认 true；播放设置可切换。Explore 卡片/主操作与 Search 结果按该值选 DetailPage 或 DirectPlaybackPage，明确「详情」操作不受影响。直接播放路由先读取详情，按现有 resumeEpisodeIndex 决定集数与位置，保留 VIP 确认，异步代次/权限检查和重试；只有详情就绪才创建现有 PlaybackHandle/PlaybackPage。


### 应用内通知与混合观看记录

- 即时反馈统一使用 `ui/widgets/app_notice.dart` 的 `showAppNotice(context, message)`；跨页面异步任务在 await 前捕获 `AppNotice.of(context)`，完成后调用句柄的 `show`。根 Overlay 只保留最新一条通知，销毁时取消计时器；确认、输入、任务进度对话框和系统下载通知不属于此接口。
- 气泡使用统一玻璃材质和独立的高覆盖染色，内容区不叠高光。文字按黑白背景下的最小对比度选择，必要时改为不透明底，保证至少 4.5:1；不能直接复用导航栏的透明度。
- 顶部气泡按文字排版宽度加图标/关闭按钮留白决定宽度，最大 560 且不超安全区；短文本不可强制铺满屏幕。
- 站源与直播平台标题行共用 `SourceHeader`，两类分类弹窗共用 `showChoicePanel`，修改尺寸、顶部留白与边框应在公共组件完成。
- `liveHistory` 是用户级展示记录，只保存平台、房间和观看时间；解析后的流地址、签名、Cookie 不进入记录或备份。最近观看合并短剧和直播，删除键带类型前缀；打开直播时在来源页所在的导航栈重新解析播放，返回后保留筛选、滚动和选择状态。
- 观看记录的内容类型使用下拉，来源/平台使用平铺标签；这两层条件不要合成同一级标签行。
- `history_retention.dart` 统一滚动30天规则。LocalStore 启动队列清理全部用户 history/liveHistory，展示和续播读取即时过滤；_commit 对新写入/导入的观看字段再次裁剪，过期数据不会因迟到保存或旧备份恢复。DuanjuApp 恢复前台及每小时调用日级检查，同自然日成功清理后不重复写盘，dispose 取消定时器。只删观看记录，不删收藏、追剧或下载文件，损坏原始值保留给恢复流程。

## 本地分文件存储与窗口

- 正式启动走 `LocalStore.open`，数据在应用支持目录 `store/`：`users.json` 保存身份；`profiles/<id>/<类别>.json` 保存观看记录、追剧、直播收藏、待确认剧集、播放偏好等；`settings/` 保存原快照的全局字段。少量独立外观开关继续由 SharedPreferences 保存。
- 成功迁移旧 `localSnapshot.v1`、散键和独立用户键后才删除旧键。每类文件写 `.tmp` 后换名并留 `.bak`，跨类别变更先写 `transaction.json`、完成后删除；中断启动先重放。没有身份文件但有旧记录时不能创建默认管理员。
- 非身份类损坏先恢复上一版，两版无效只忽略该类；权限/磁盘错误上抛并保留文件。用户文件两版无效时锁定访问。恢复导出保留原文，备份格式兼容旧版本；增强与目录排序/筛选旧字段不再保存。
- `dart scripts/check_local_file_store.dart <临时目录>` 可不启动 Flutter 引擎验证真实磁盘的类别隔离、历史单独写入、上一版恢复、事务重放和身份保护；`test/local_file_store_test.dart` 另测正式迁移入口及备份兼容。
- `desktop_window_state.dart` 在 `store/window.json` 单独保存普通窗口，350 毫秒防抖，排除最大化、最小化、全屏和 PiP。显示器 ID 无效回到主屏居中；纯几何用例在 `desktop_window_state_test.dart`，插件与多显示器行为仍需实机验证。

## 液态玻璃与动效统一约定

- 材质只从 `GlassStyleResolver` 取：`surface` 用于普通表面，`chrome` 用于顶底栏/侧栏，`panel` 用于菜单弹层，`playback` 用于深色无模糊播放控件。禁止同类组件各写一套染色/阴影；列表卡片和整高侧栏继续 `blur:false`，不在视频上增加背景采样。
- 所有共用交互动效使用 `ui/app_motion.dart`：按压100ms、状态160ms、入场240ms、退场160ms、导航260ms，统一easeOutCubic。`disableAnimations` 或 `accessibleNavigation` 开启时移除位移/缩放、使用零时长；高对比度和电视沿用不透明材质。
- `GlassFeedback` 只负责压感/边缘反馈，不注册点击和拖动识别器；由原按钮处理点击/禁用/焦点，滚动或取消后清除压感。不可包住整个面板或导航栏使整块内容缩放，不叠加到已有压感的同一控件。
- 底栏只绘制一个 `GlassSelectionTrack`，目标切换立即执行原导航，动画可以中途转向，不排队、不重建页面。下拉/分类弹层共用 `GlassPopupRoute`/`GlassAnchoredPopup`，保留Navigator层级、选择返回值、遮罩关闭和底部面板拖动。
- 通知只保留一个根Overlay入口；替换重置时限，退场先IgnorePointer再移除，销毁释放计时器/控制器。不可为高光动画降低通知4.5:1对比度，禁止循环扫光、持续呼吸或全局鼠标跟随。
- `test/glass_motion_test.dart`、`test/glass_popup_motion_test.dart`、`test/app_notice_test.dart` 验证中间帧、快速反向/替换、RTL、安全区、减少动态效果、点击/滚动及生命周期；新增同类UI必须复用这些规则并补回归。

## 发布

### 每次更新的版本迭代要求

- 每次完成功能更新、问题修复或性能/UI优化，都必须同时递增 `pubspec.yaml` 的显示版本号和 `+` 后的构建号，不能沿用上一轮更新的版本；同一轮需求包含多处改动时统一递增一次，后续独立更新继续递增。
- 常规小更新递增补丁号，构建号始终单调递增、不随主/次版本重置。例如本轮 `1.0.9+109` → `1.0.10+110`，下一轮小更新为 `1.0.11+111`。
- 同时在 `CHANGELOG.md` 顶部增加与完整版本号一致的章节，记录本轮改动、实际验证结果及未验证范围；完成检查时核对版本号与日志标题一致。
- 版本迭代不修改应用标识、版别偏移或历史数据目录；各平台仍由现有构建脚本读取统一版本。

工作流 `.github/workflows/build.yml` 在推送到 `main` 时自动运行，也可以在 Actions 里手动运行 **Build app packages**。

1. 同时提升 `pubspec.yaml` 的版本号与构建号。
2. 在 `CHANGELOG.md` 新增同名一节（标题如 `## 1.0.1+101`），工作流会把它写入 Release 说明；未验证的改动标为开发快照。
3. 推送到 `main`，等 **Build app packages** 跑完。

工作流按 `pubspec.yaml` 的版本算出 tag `app-v{version}`（`+` 替换为 `-`）。随后各平台各构建 FlGuo 标准版、全站源版：

| 产物 | 内容 |
| --- | --- |
| `*-android` | arm64-v8a APK，使用发布证书签名并通过指纹校验 |
| `*-windows` | Windows x64 ZIP |

格式、分析、测试不阻塞出包。iOS（`*-ios-unsigned`）和 macOS（`*-macos`）的任务定义与 `scripts/build_ios.py` / `scripts/build_macos.py` 都保留着，现在是 `if: false` 关闭，恢复时把 `if` 改回 true 即可。

最后一个 `release` 作业要等 Android、Windows 都成功才会跑：下载全部产物，用 `CHANGELOG.md` 里同名一节作说明，创建 tag 和 Release 并上传 APK / ZIP。任一平台失败就不发布，不会留下半截 Release。同版本重跑不会失败，已有 Release 会覆盖说明、并用 `--clobber` 覆盖同名附件。

Android 签名只用仓库 Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，另需仓库变量 `ANDROID_CERT_SHA256`（证书 SHA-256，冒号和大小写不限），缺任意一项都会失败。CI 通过环境变量把签名传给 Gradle。

## 检查更新

接收端是 Cloudflare Worker `guoapp-update`（`worker/`，D1 数据库 `guoapp-stats`，只存 `meta` 表），地址在编译期由环境变量 `UPDATE_SERVER_URL` 经 `scripts/app_build.py` 注入 Go（CI 取仓库变量 `UPDATE_SERVER_URL`），没设时检查更新不发请求，fork 和本地构建默认不会连到这里。Go 核心（`native/core/app_update.go`）的 `checkUpdate` 请求 `GET /v1/latest`，只读不写。Worker 每小时从 GitHub 读取最新 Release 写入 `meta` 表。改 Worker 后在 `worker/` 下运行 `npx wrangler deploy`。

应用不收集匿名使用统计：Worker 只保留 `GET /v1/latest`，`POST /v1/ping` 与 `pings` 表已删除，客户端的上报入口也一并去掉。

在 `worker/` 下查询（`--remote` 查线上库）：

~~~sh
npx wrangler d1 execute guoapp-stats --remote --command "SELECT key, value FROM meta"
~~~

应用显示名统一为 FlGuo：Android 在 `android/app/build.gradle.kts`，Windows 在 `windows/runner/app_branding.cmake`，iOS 的 Info.plist 和 Xcode「Thin Binary」构建阶段（含 `zh-Hans.lproj/InfoPlist.strings`）均写入 FlGuo。macOS 的 Info.plist、原生菜单及窗口标题使用 FlGuo；`scripts/package_release.py` 按版别命名 `.app`，写入显示名并保留历史 bundle identifier 后重新签名，内部构建目标仍为 `duanju_app.app`。macOS 关闭了 App Sandbox，以便本地播放代理和自选下载目录正常工作；系统代理由 `MainFlutterWindow.swift` 的 `duanju/device` 通道读取。
