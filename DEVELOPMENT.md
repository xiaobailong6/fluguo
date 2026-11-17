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

### Android插件仓库解析

- Android出包使用 `scripts/build_android.py`。它在 `flutter build apk` 期间通过 `scripts/android_gradle.py`，将 `android/gradle/plugin-repositories.init.gradle` 临时放入Gradle用户目录的 `init.d`；该钩子在所有build（包括Flutter SDK的独立Gradle included build）读取settings前补齐官方插件仓库，退出时删除，不改写Flutter SDK或用户已有init脚本。
- `android/settings.gradle.kts` 的 `pluginManagement.repositories` 只作用于主build，不能修复SDK独立build仅从Plugin Portal查找Kotlin BOM/stdlib/API的问题。日志若在 `dev.flutter.flutter-plugin-loader` 阶段报 `org.jetbrains.kotlin:*` 缺失且搜索地址仅有 `plugins.gradle.org`，先核对独立build的插件仓库，不盲目降级Kotlin/AGP或修改APP代码。
- 保留自定义 `GRADLE_USER_HOME` 和缓存；相对路径在构建期间归一化为绝对路径，退出恢复原值。直接运行 `flutter build`/`flutter run` 不经过此包装；若手动执行Gradle，可用 `--init-script <项目绝对路径>/android/gradle/plugin-repositories.init.gradle` 显式加载同一配置。
- 离线脚本回归：`python -B scripts/test_android_gradle.py -v`。真实插件解析回归：准备JDK17和项目Gradle9.3.1，将 `FLUGUO_TEST_GRADLE` 设为Gradle可执行文件绝对路径后运行同一命令；可用 `FLUGUO_TEST_GRADLE_HOME` 指向临时/专用缓存目录。该集成测试仅验证included build的插件解析，不代表APK编译、签名或安装通过。

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

## 性能基线与 HUD

`lib/ui/widgets/perf_hud.dart` 是一个编译期开关的运行时面板，用来在真机上量帧耗时，而不是凭感觉判断「顺不顺」：

~~~sh
flutter run --profile --dart-define=PERF_HUD=true
~~~

面板固定在右下角，显示最近 180 帧的 fps、p50/p95 帧耗时、超出 16.7ms 预算的帧占比与常驻内存；点一下展开 build/raster 分项，长按清零。未定义 `PERF_HUD` 时 `PerfHud` 直接返回 child，不注册回调、不绘制、不产生计时开销，所以可以长期留在代码里。

采基线时固定同一台设备、同一网络、同一片源和同一操作序列（例如：冷启动 → 短剧列表滑到第 3 屏 → 进详情 → 播放 60 秒 → 返回），改动前后各跑一遍，记录 p95 与 jank 百分比。没有这两组数字就不要宣称性能收益，也不要把「看起来更顺」当成结论；请求耗时看 `DiaryService` 日记，与帧耗时分开记录。

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
- 剧场首帧由 `TheaterVideoPresentation`/`StablePreviewSurface` 保护：只接受同一videoParams事件中的成对dw/dh（含旋转），显式设置contain比例；open完成且纹理ID/有效矩形比例同步后，完成一帧布局再撤黑罩。Video/Texture必须始终挂载，禁止用Offstage或等待显画后才挂载，不能靠固定延时隐藏变形；stop/换剧重置展示代次，重复参数不通知。Video自带后台暂停/恢复关闭，由TheaterPreview可见性统一控制。
- 剧场入口玻璃参数按GlassTier缓存至多三份，避免状态刷新重建同一滤镜；打开全集失败使用统一AppNotice，不另用SnackBar，失败可重试且恢复预览。
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
- 所有共用交互动效使用 `ui/app_motion.dart`：按压120ms、状态200ms、入场340ms、退场260ms、导航360ms、滚动浮栏400ms、首页大卡片入场400ms/退场260ms；进入用 `curve`（emphasizedDecelerate）、退出用 `exitCurve`（emphasizedAccelerate），对称过渡用 `navigationCurve`（standard）。时长一律经 `AppMotion.of(context, …)` 取值：`disableAnimations` 或 `accessibleNavigation` 开启时归零，电视形态压到 `televisionMax`（200ms）以内；高对比度和电视沿用不透明材质。不要再按旧值（100/160/240/160/260/300）或统一 `easeOutCubic` 编码。
- `GlassFeedback` 只负责压感/边缘反馈，不注册点击和拖动识别器；由原按钮处理点击/禁用/焦点，滚动或取消后清除压感。不可包住整个面板或导航栏使整块内容缩放，不叠加到已有压感的同一控件。
- 底栏只绘制一个 `GlassSelectionTrack`，目标切换立即执行原导航，动画可以中途转向，不排队、不重建页面。下拉/分类弹层共用 `GlassPopupRoute`/`GlassAnchoredPopup`，保留Navigator层级、选择返回值、遮罩关闭和底部面板拖动。
- 通知只保留一个根Overlay入口；替换重置时限，退场先IgnorePointer再移除，销毁释放计时器/控制器。不可为高光动画降低通知4.5:1对比度，禁止循环扫光、持续呼吸或全局鼠标跟随。
- 长错误分三层：载体只放短状态（如海报上的「合并失败」），全文进按需展开的面板（可滚动、可选中），气泡只发一条单行提示指向面板。不要把长文本塞进单行气泡或固定尺寸卡片。
- `test/glass_motion_test.dart`、`test/glass_popup_motion_test.dart`、`test/app_notice_test.dart` 验证中间帧、快速反向/替换、RTL、安全区、减少动态效果、点击/滚动及生命周期；新增同类UI必须复用这些规则并补回归。
- 滚动显隐共用 `ScrollChromeController`/`ScrollChromeVisibility`，累计同向距离而非逐帧速度，隐藏保留子树以完成退出/反向动画，同时隔离输入、焦点和语义；不能用隐藏条件直接移除顶底栏。回顶由各Tab根页面实际Scrollable提供，使用前检查mounted，不让隐藏Tab、子路由或横向列表覆盖目标。
- 主动回顶统一 `smoothScrollToTop`：按滚动距离使用450–850ms easeInOutCubic，不用普通模式jumpTo、定时器分步跳转或完成后修改Tab。`disableAnimations`才即时回顶；仅accessibleNavigation不取消用户明确点击的滚动过渡。Explore回顶同时立即展开顶栏，原生滚动活动允许手势、重复请求和销毁取消；`test/smooth_scroll_test.dart`验证中间帧/长距离/辅助设置/中断/销毁。
- `TabPageTransition` 只动画当前页的绘制，不移动/重建Navigator，切出立即关闭Ticker和焦点；方向按用户菜单顺序及RTL确定，快速切换不排队。`test/shell_scroll_motion_test.dart` 验证真实按钮回顶、顶底栏中间帧/反向/减少动态效果、页面实例和滚动保留、子路由隔离及直播吸顶。

## 发布

### 每次更新的版本迭代要求

- 每次完成功能更新、问题修复或性能/UI优化，都必须同时递增 `pubspec.yaml` 的显示版本号和 `+` 后的构建号，不能沿用上一轮更新的版本；同一轮需求包含多处改动时统一递增一次，后续独立更新继续递增。
- 常规小更新递增补丁号，构建号始终单调递增、不随主/次版本重置。例如本轮 `1.0.9+109` → `1.0.10+110`，下一轮小更新为 `1.0.11+111`。
- 同时在 `CHANGELOG.md` 顶部增加与完整版本号一致的章节，记录本轮改动、实际验证结果及未验证范围；完成检查时核对版本号与日志标题一致。
- 版本迭代不修改应用标识、版别偏移或历史数据目录；各平台仍由现有构建脚本读取统一版本。

工作流 `.github/workflows/build.yml` 在推送到 `main` 时自动运行，只做打包；校验不在打包链路里重复执行。`.github/workflows/verify.yml` 独立运行，PR 自动触发，也可在 Actions 里手动运行 **Verify**。

1. 同时提升 `pubspec.yaml` 的版本号与构建号。
2. 在 `CHANGELOG.md` 新增同名一节（标题如 `## 1.0.1+101`），工作流会把它写入 Release 说明；未验证的改动标为开发快照。
3. 推送到 `main`，等 **Build app packages** 跑完。
Android 与 Windows 作业都在编译前跑静态分析，分 `lib`、`test` 两步：`flutter analyze --no-fatal-infos --no-fatal-warnings lib`，再以同样参数扫 `test`。只扫本应用，`source/`、`live/` 是遗留工程不参与；error 级问题直接失败，infos/warnings 不阻塞出包。注意 `dart analyze` 不支持 `--no-fatal-infos` 取反且只收一个目录，别改回去。`ffmpeg_kit_flutter_new_min_gpl` 需保持 2.6.6 以上，否则插件会应用 Kotlin Gradle Plugin，出现 KGP 警告并在启用内置 Kotlin 后构建失败。

工作流按 `pubspec.yaml` 的版本算出 tag `app-v{version}`（`+` 替换为 `-`）。随后各平台各构建 FlGuo 标准版、全站源版：

| 产物 | 内容 |
| --- | --- |
| `*-android` | arm64-v8a APK，使用发布证书签名并通过指纹校验 |
| `*-windows` | Windows x64 ZIP |

Verify 与打包互不阻塞。Verify 自身执行 Dart 静态分析、两个版别的全量 Flutter 测试、Go vet 和两个版别的 Go race 测试，任何一步失败即为红；`test/known_red.txt` 仅保留历史失败说明，不再排除文件。打包作业仍保留编译前的 `flutter analyze`（只拦 error），这是为了避免花几分钟编译后才在 kernel 快照阶段报错。iOS（`*-ios-unsigned`）和 macOS（`*-macos`）任务仍以 `if: false` 关闭。

最后一个 `release` 作业要等 Android、Windows 都成功才会跑：下载全部产物，用 `CHANGELOG.md` 里同名一节作说明，创建 tag 和 Release 并上传 APK / ZIP。任一平台失败就不发布，不会留下半截 Release。同版本重跑不会失败，已有 Release 会覆盖说明、并用 `--clobber` 覆盖同名附件。发布前请确认同一提交的 Verify 已通过（PR 或手动）。

Android 签名只用仓库 Secrets：`ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，另需仓库变量 `ANDROID_CERT_SHA256`（证书 SHA-256，冒号和大小写不限），缺任意一项都会失败。CI 通过环境变量把签名传给 Gradle。

## 检查更新

接收端是 Cloudflare Worker `guoapp-update`（`worker/`，D1 数据库 `guoapp-stats`，只存 `meta` 表），地址在编译期由环境变量 `UPDATE_SERVER_URL` 经 `scripts/app_build.py` 注入 Go（CI 取仓库变量 `UPDATE_SERVER_URL`），没设时检查更新不发请求，fork 和本地构建默认不会连到这里。Go 核心（`native/core/app_update.go`）的 `checkUpdate` 请求 `GET /v1/latest`，只读不写。Worker 每小时从 GitHub 读取最新 Release 写入 `meta` 表。改 Worker 后在 `worker/` 下运行 `npx wrangler deploy`。

应用不收集匿名使用统计：Worker 只保留 `GET /v1/latest`，`POST /v1/ping` 与 `pings` 表已删除，客户端的上报入口也一并去掉。

在 `worker/` 下查询（`--remote` 查线上库）：

~~~sh
npx wrangler d1 execute guoapp-stats --remote --command "SELECT key, value FROM meta"
~~~

应用显示名统一为 FlGuo：Android 在 `android/app/build.gradle.kts`，Windows 在 `windows/runner/app_branding.cmake`，iOS 的 Info.plist 和 Xcode「Thin Binary」构建阶段（含 `zh-Hans.lproj/InfoPlist.strings`）均写入 FlGuo。macOS 的 Info.plist、原生菜单及窗口标题使用 FlGuo；`scripts/package_release.py` 按版别命名 `.app`，写入显示名并保留历史 bundle identifier 后重新签名，内部构建目标仍为 `duanju_app.app`。macOS 关闭了 App Sandbox，以便本地播放代理和自选下载目录正常工作；系统代理由 `MainFlutterWindow.swift` 的 `duanju/device` 通道读取。

### 1.0.85 网络与持久化回归

- 直播文本请求由 `requestLiveResponse` 统一限制：获取 request、响应头及响应体共享 30 秒总预算；成功正文最多 8 MiB、错误正文最多 64 KiB，超时/超限主动 abort。持续滴流不能续期，晚到的 request 也中断。平台 HTTP 错误保留状态码。
- 秀果从两个服务的 `json.txt` 中读取 `pingtai.address` 动态发现分类，不再固定请求映客。仅接受同目录 JSON 文本地址、有效 FLV 房间，排除空分类及明显共用拦截地址；最多六路并发，主镜像保留备用预算，总发现 30 秒、缓存两分钟。播放前重新取地址，不持久化签名；保留旧映客 ID 兼容。预算内未完成的分类可能暂不显示，FLV 后缀筛选不等于媒体实播验证。
- 黄果网络内层不再设置 45 秒整体传输时限；响应头仍有 20 秒限制，普通 API 保留外层总超时，下载保留 30 秒无数据取消。动态 HLS 媒体列表不缓存正文；ENDLIST 点播与主列表保留预加载优化。
- 野果仅在已知域名 TCP 建连失败后使用既有 DoH、公网 IP 校验及 TTL 缓存回退；保留原 URL/Host/SNI/证书验证，不写死 IP，不对 HTTP 403 等业务失败重试 DNS，代理路径不绕开。
- 观看批次的排序、保留期过滤、模型转换及内层 JSON 编码由 isolate 执行；大批收藏/备份安装延迟内层编码，小设置仍走轻量路径。写队列、用户 epoch、失败重试和文件事务格式保持。性能收益须在真机 profile 模式测量，不能用代码改动代替帧耗时证据。
- 黄果视频站源设置新增同样式浏览器入口，供用户在正常网页中手动完成站方验证。浏览器会话与应用独立，打开网页不能视为应用已通过验证；不导入验证 Cookie、不实现自动绕过防护。应用持续 403 时需站方支持或官方接口。
- 本机无编译环境时只做差异与配置检查，不下载安装 SDK。新增 Dart/Go 回归由 Verify 执行，编译、race、真机 UI 和长时播放未运行前必须标注未验证。

1.0.86：黄果卡片右侧「校验」使用 `LaunchMode.inAppBrowserView`，调用前检查能力。Android 声明 Custom Tabs 服务查询；不支持此模式的平台显示提示，不自动外跳。此模式在 Android/iOS 由系统浏览器组件承载，Windows/macOS 的现有 url_launcher 实现不能作为内嵌 WebView 使用。浏览器会话仍不与 Go 原生请求共享。

1.0.87 复核：直播 abort 的 `request.done` 错误必须消费；黄果响应体仅在阻塞读取期间计时（30 秒），不限制总传输时长，也不把播放器暂停消费判为网络停滞。秀果续签在同一总预算内重试备用镜像。HLS 诊断稳定缓存样本包含 ENDLIST；DNS TTL 测试需禁用连接复用确认实际重复拨号。上述新增回归仍待有工具链的 CI 执行。

1.0.89：下载删除入口的「普通文件」校验只作用于本功能自己的两个后缀（`.normalizing`/备份），成品路径交给 `removeFiles` 的单次 `os.Remove`：空目录可删、非空或被占用返回可重试错误。禁止再把成品路径要求成普通文件——那会让被目录/占用卡住的记录永久无法删除（三个历史 Go 失败用例即此因）。目录链符号链接校验仍在 `normalizationTarget`。

### 1.0.90 增量移植与验收

- 不整体同步 `source/`：保留现有版别、站源 ID、直播/剧场、玻璃组件、播放交接、请求池和存储事务。红果只为新版播放路径使用 v5，目录/评论签名仍独立；来源与许可证见 `THIRD_PARTY_NOTICES.md`。
- `media_kit_video` 固定 2.0.1，使用 `packages/media_kit_video` 的本地 override；非 Windows 平台实现未改。重新构建前运行 `flutter pub get --enforce-lockfile`，不能依赖旧 `.dart_tool/package_config.json`。
- 原生初始化增加可选 `cache` 路径；未迁移时不传继续使用原路径，已迁移时不传会读取 `native-cache-layout.json` 的已提交路径。正常应用传系统缓存目录，便携版传 `userdata/cache`。仅 `catalogs.json`、`rankings.json`、`covers-v1` 属于此缓存布局；账号、下载、用户配置和红果设备身份留在数据目录。
- `hongguo-devices.json` 只保存设备身份，不保存分页游标；游标仍与剧库同文件提交，并携带设备身份摘要。恢复时摘要不匹配则丢弃红果可重建分页缓存，不影响其他站源、收藏、观看记录和下载。首次迁移先落设备身份、复制去身份的剧库，再写 `native-cache-layout.json` 完成标记；任何提交前失败继续使用旧目录且不删除原件。成功后旧剧库保留为 `catalogs.pre-cache-v1.json`，不自动回灌。跨盘或占用导致封面/榜单无法移动时只记诊断并保留原文件。
- 已完成迁移后，缺失/损坏的设备状态或不可用缓存目录不能静默生成新身份；应修复权限/恢复文件再重启。缓存可以重建，设备文件和迁移标记不能按缓存清理。`scripts/clear_catalog_cache.py` 在没有拆分标记但存在旧剧库时拒绝删除，标记存在时还检查设备状态文件再定位缓存；历史恢复副本不由该脚本删除。
- 定向 Go 回归：在 `native` 下运行 `go test ./core -run 'Hongguo|NativeCache|NativeHLS|NativeDownload|MediaBackoff|DownloadMigration' -count=1`，再运行标准版/全站源版 `go test -race ./...`。新增用例均为合成离线数据，不开启真实站源探测变量。
- 定向 Flutter 回归：`flutter test --dart-define=DISABLE_REMOTE_IMAGES=true test/danmaku_overlay_test.dart test/danmaku_window_test.dart test/danmaku_controller_test.dart test/portable_data_test.dart test/playback_session_test.dart test/playback_sleep_test.dart`。后续两版全量测试与 analyze 按既有 Verify 执行，不更改打包依赖关系。
- Python 回归：`python -B scripts/test_package_release.py -v`、`python -B scripts/test_cache_directory.py -v`。这只验证命令与路径逻辑；Windows 多次播放退出/缩放、macOS 成品签名权限、红果播放切集下载、旧数据迁移与系统清缓存仍须实机验收。

### 1.0.91 站源能力与网络策略

- 能力与网络策略单一配置为 `config/source_capabilities.json`；修改后运行 `python -B scripts/generate_source_capabilities.py`，提交 `lib/source_capabilities.g.dart` 与 `native/core/source_capabilities_generated.go`。生成文件保持生成器布局，不手工编辑；Verify 使用 `--check` 拦截配置漂移。
- 标准版仍只有红果、饭果、爽果；全站源版共有 20 个站源定义。MissAV/Hanime1 属限制级且默认关闭，保留管理员开关和访客授权，不新增导航或改变 UI 样式。已有版别、播放会话、下载恢复及用户数据协议保持。
- `BrowserFingerprint` 只给声明的精确主机及该站点显式配置地址使用，不按任意子域/媒体 CDN 扩散。不能以 403 为由自动改用普通客户端、导入 Cookie 或取消 TLS 校验；继续保留零整体超时、20 秒响应头计时和 30 秒单次阻塞读取保护。
- `DNSHosts` 只覆盖经审查的具体普通 HTTPS 站源域名；浏览器指纹客户端不进入此回退。仅 NXDOMAIN 或拨号到回环/未指定 IP 才重试；有代理、代理解析失败、不可重放请求体、取消、证书错误或普通网络超时不重试。最多四个经现有公网 IP 校验的候选地址，维持原请求时限、Host/SNI 与签名。野果已有专用拨号恢复不替换。
- 新源参考公开模块 v1.0.1 并校验索引哈希。MissAV packed 脚本只做有界字面量解包，不执行 JavaScript；Hanime1 保持请求/返回视频 ID 和 query 一致校验。站点页、缩略图与媒体未联网验证；Hanime1 上游注明日本 IP 无法访问，运行时不尝试绕过区域/访问限制。
- 离线检查：`python -B scripts/test_source_capabilities.py -v`；`dart scripts/check_source_capabilities.dart`；`dart -DALL_SOURCES=true scripts/check_source_capabilities.dart`。Go 定向：在 `native` 下运行 `go test ./core -run 'SourceDNS|SourceBrowser|SourceCapabilities|NewSources|Missav|Hanime1|NewWeb' -count=1`，再执行两版全量 race。Flutter：带 `DISABLE_REMOTE_IMAGES=true` 执行 `source_capabilities_test.dart`、`local_store_access_test.dart`、`source_catalog_test.dart`、播放和剧场回归，两个版别都执行。

### 1.0.92 缓存、分季与局部动画验收

- `storage` 原 `bytes/files/free/directory` 仍表示下载；新增 `cacheBytes/cacheFiles/cacheFree/cacheDirectory/cacheWarning`。缓存占用仅统计可安全清理白名单，不等于整个数据目录大小：`catalogs.json`、`rankings.json`、`covers-v1/<64hex>.img`、`covers-v1/compatible-v1/<64hex>-<mtime微秒>-<原文件字节数>.jpg`。不清理解码临时文件、未知文件、目录、账号、设备、下载和迁移备份。
- `clearCache` 无外部路径参数，Dart 校验管理员/用户代次、阻止重复点击并等待封面转换/裁剪；Go 等待目录类租约，校验布局/设备/下载路径，拒绝链接/reparse point，以 Go 1.24 `os.Root` 目录句柄限定删除范围。即使部分删除失败，也失效旧内存/图片/列表结果并报告错误，不把半成功当成功。清理后要确认原红果设备 ID 未变、下载仍正常、目录可重新加载。
- `seasons` 与 detail 共用授权边界；只有红果声明此能力。官方列表必须包含自身、ID 精确保留为整数/字符串（不经过 float64），最多 200 季，30 秒预算，缺元数据最多两次补查。关系缓存最多 128 项/30 分钟；禁止同名推断或全量逐季请求。详情切季复用现有选择面板；季末自动切换遵守自动连播、前台/暂停/睡眠/用户权限状态，并区分剧场原作品和新季身份。
- `PlaybackVideoDiagnostics` 仅在 `DiaryService.traceEnabled` 时读取 `hwdec-current/current-vo/video-codec/container-fps`，日志还包含像素格式及画面尺寸。检查实际硬解不能只看期望的 `hwdec` 设置；日志字段严格过滤，不记录播放 URL、请求头或解密参数。
- 桌面置顶只对已初始化 window_manager 的 Windows/macOS 开放，独立偏好 `desktop_window_always_on_top` 默认 false；PiP 临时强制置顶不能覆写用户偏好。实机覆盖快速切换、退出 PiP、进入/退出全屏及插件失败。滚轮只响应桌面鼠标垂直滚动，短剧和直播视频区每次 ±5；控件/子列表/后台/锁屏不应误调音量，竖屏剧场原有滚轮切集保持。
- `LocalContentTransition` 只驱动当前内容树的轻移/淡入，不保留退出页；避免双滚动控制器、重复焦点或播放器。范围为发现分类、详情集数组和加载状态，保持既有 UI 样式、全局转场、导航栈、返回手势和海报菜单。实机覆盖快速反向切换、隐藏 Tab、RTL、减少动画、TV 遥控焦点、滚动位置及大字体布局；性能收益须实测，不能仅以代码宣称。
- 定向 Flutter：带 `--dart-define=DISABLE_REMOTE_IMAGES=true` 执行 `cache_maintenance_bridge_test.dart`、`cover_decoder_exit_test.dart`、`storage_cache_view_test.dart`、`official_seasons_test.dart`、`playback_seasons_test.dart`、`playback_video_diagnostics_test.dart`、`window_on_top_test.dart`、`picture_in_picture_transition_test.dart`、`desktop_volume_scroll_test.dart`、`local_content_transition_test.dart`，再执行播放/睡眠/剧场/详情回归与两版全量测试。
- 定向 Go：在 `native` 下运行 `go test ./core -run 'HongguoRegister|NativeCache|NativeSeasons|HongguoSeason' -count=1`，再执行两版全量 race；Windows 还需执行 junction 用例。所有新增 fixture 为离线合成数据，不开启真实站源探测变量。
- 已执行静态检查：全 `lib`/`test` Dart analyze 无 error/warning，16 条既有 info；35 个变更 Dart 文件格式、19 个 Go 文件 WASM parser/gofmt、56 个变更 Go/Dart 文件语法及 `git diff --check` 通过。能力生成一致性、两版纯 Dart 能力断言、20 项 Python 回归通过，1 项真实 Gradle 集成未配置跳过。上述检查不替代 Go 类型检查、编译或 race。
- 定向执行使用已有 Dart 3.13.3 前端编译器 `frontend_server_aot.dart.snapshot`（`--target=flutter --sdk-root=<现有 common/flutter_patched_sdk> --packages=.dart_tool/package_config.json -DDISABLE_REMOTE_IMAGES=true`），再以已有 Windows `flutter_tester.exe --disable-vm-service --non-interactive --use-test-fonts` 执行产出的 dill；设置 `FLUTTER_TEST=true`，界面 shader 使用现有 `--flutter-assets-dir=<项目>/build/unit_test_assets`。未调用会尝试下载元数据的 Flutter 启动脚本，未安装新 SDK。
- 完整通过 10 组/60 项：缓存桥接 5、原桥接 9、窗口置顶 8、滚轮 7、PiP 退出竞态 1、存储页 3、局部动画 5、官方分季 7、解码诊断 6、睡眠播放 9。平台模拟值在测试体 finally 恢复；直接执行器缺 shader 的睡眠用例已补传既有资源后重跑通过。
- 另 6 组/61 项断言输出全部通过，但执行器在成功输出后未正常退出，70 秒后被测试包装器结束：封面原生退出 2、自动续季 21、发现页 9、详情 4、播放会话 22、合并播放 3。此类结果仅记录断言完成，不记作完整运行通过；须在 CI 标准 `flutter test` 下核验收尾与两版全量回归。
- 剩余验收：本机无 Go SDK，未运行 Go 测试/race；标准 Flutter 全量运行、各平台构建、真实站源播放、设备注册、缓存占用与 Windows/macOS 窗口交互未验收。不使用语法检查或假播放器断言替代这些结果。

### 1.0.93 第一批稳定性移植

- 红果仅调整 multi_video_model 的 `biz_param.device_level=1`（模块 v1.0.3），普通/兼容编码重试均覆盖；签名、fallback、权限及版别保持。新增参数用例仍需在有 Go SDK 的环境执行 `go test ./core -run 'Hongguo.*(V5|Media)' -count=1`，再跑两版全量 race。此修复依赖服务端返回兼容线路，不表示客户端支持 H.266。
- Android Surface 更新仅在有效且未被替换的 Surface、播放中、有效时长/位置时 seek；不改 `vo` 初始化顺序。备用播放器临近片尾 45 秒内才预开，后台清理、暂停一分钟回收；备用 open/stop 共用队列，回收后阻止缓冲事件重新预开。手动继续或新集恢复正常预加载。
- 长暂停恢复及 seek watchdog 使用独立用户操作代次和已有媒体代次；同线路重开进入主操作队列，不重新 resolve 或释放正在使用的计划。暂停、后台、睡眠、用户/权限变更、切集、交接及退出均使旧监测失效。原生错误/完成事件可能早于 open Future 完成，必须暂存并在退出队列后核验再处理，不能漏掉自动续季/本集结束停止。恢复失败继续原有有界换线/刷新机制。
- `PlayerStatsLabel` 每次只允许一个原生读速请求，后台、非当前路由、暂停、缓冲、禁用时不读；恢复后等待进展或有界延迟。解码诊断在详细日志开启、有效前台会话稳定播放后读取，按画面参数去重，并拒绝失效样本。显示样式、设置项不变。
- `knownCover` 是授权内存提示，不做同步 I/O；owner/epoch/source/revision 与维护屏障均匹配才返回。widget 复用原解码档位与 Image，但身份或清缓存开始时换 FutureBuilder 代次撤下旧图。强制重试淘汰同图旧请求，文件缺失仍经 async exists 回退加载；测试使用合成像素和 fake dispatcher。
- Windows 保留 ANGLE 与现有 libmpv。先创建 OpenGL context 再注册 GPU 纹理；失败时在其 GL context 上释放、清理 manager 后进入软件后端，保留 generation/descriptor/pending-unregister 和析构屏障。render 失败不通知 Flutter，新错误每实例最多记录一次。`python -B scripts/test_windows_video_fallback.py -v` 是结构回归，不是 C++ 编译或驱动实测。
- 已执行：27 项 Python 回归通过、1 项 Gradle 集成跳过；能力生成一致性及两版纯 Dart 断言通过；全 `lib`/`test` analyze 无 error/warning，保留 16 条既有 info；Android 插件分析无 error/warning（两条原注释 info）。变更 Go/Dart 与 Android/C++ 语法检查、Go WASM 格式、`git diff --check` 通过。第三方 Android 文件保留原排版，不整体格式化。
- 直接执行器沿用上一节本地工具和合成 fixture。完整通过：缓存封面直显 13、缓存尺寸 3、封面调度 1、缓存清理桥接 5、原桥接 9、播放器统计 2、解码诊断 7、睡眠播放 9，共 8 组/49 项。播放会话 22、自动续季 21、恢复/备用播放器 15 共 3 组/58 项断言全部通过，但测试进程在完成后未退出，包装器按 25 秒收尾超时处理，不能记为完整运行通过。标准 Flutter 两版全量测试仍交 CI。
- 未执行：Go 编译/测试/race、Windows 原生编译、Android/Windows 实机验收。重点验收 Android 长暂停/后台/横竖屏 Surface 重建、连续 seek/切集、后台备用解码器释放；Windows 硬件初始化失败、软件回退、快速缩放/退出及错误日志；红果取流与下载；清缓存、切用户时海报不闪回。未安装 SDK、请求真实站源或发布。

### 1.0.94 播放器选季、偏蓝修正与屏幕锁

- `PlaybackSession.loadSeasons/playSeason` 只接受包含当前作品的同源官方关联，不按标题或传入任意 Drama 猜测。手动选季先保存原季，目标详情身份/集数校验后才提交，以 `resumeEpisodeIndex` 和目标 WatchEntry 恢复；目标已看完的集不回灌旧时间。暂停状态保持，自动续季仍从首集开始。选集/下载选择按 drama ID 失效，竖屏页码在新季布局后对齐。
- 切季涉及已有主播放器队列、用户/媒体/交互代次、前台与睡眠检查；详情失败保留旧季，后续取流失败走已有播放器错误处理。手动切季与自动跨季不能把目标季首集交回原作品剧场预览。复测“原季末尾 → 目标季有历史 → 返回”“切季期间暂停/退出/切用户/睡眠到期”“同名非关联作品不可选”。
- `TelevisionDecoder.hardwareSwapUv` 为新增枚举名称，默认仍 optimized；Android 配置为 `hwdec=mediacodec-copy`、`vf=lavfi=[swapuv]`，其他 Android 选项明确清除 vf。非 Android 恢复该偏好时按兼容硬解处理，不施加颜色滤镜。入口沿用设置里的 ValueTile，只在 Android 提供；实际效果必须使用存在 UV 顺序异常的设备验证，正常设备不可默认开启。
- `PlayerScreenLock` 保留同一播放器子树，锁定时排除其焦点/语义并吸收输入，取消已开始的指针手势；系统返回只显示解锁入口。锁屏与倍速锁是不同状态，锁屏结束倍速但不停止播放。移动竖屏及触控全屏提供入口；桌面/TV不新增。解锁按钮位于左右安全区，3 秒后隐藏，触摸/按键/返回唤回。
- `AppDevice` 串行方向命令并淘汰过期 hold；Android 保存原 requestedOrientation 与原方向监听器，用 SCREEN_ORIENTATION_LOCKED 固定实际方向，显式新策略废弃旧快照。PiP、页面/引擎销毁提供释放兜底。iOS 用新增 `playerInterfaceOrientation` 读取当前 UIWindowScene 界面方向（含反向横屏），读取期间已解锁则不再应用旧结果，旧包无通道时退回横竖方向。多窗口、大屏/OEM 系统可能忽略应用方向请求，不能以 mock 断言替代实机。
- 定向 Flutter：`playback_manual_season_test.dart`、`player_season_choice_test.dart`、`playback_decoder_test.dart`、`playback_preferences_test.dart`、`player_screen_lock_test.dart`、`player_orientation_lock_test.dart`；继续运行原 `playback_seasons_test.dart`、`playback_sleep_test.dart`、`playback_session_test.dart`、`playback_resume_recovery_test.dart`、`playback_layout_test.dart`、`playback_glass_test.dart`。均使用 fake 仓库/播放器和 mock 平台通道，禁用远端图片。
- 本轮静态检查：全 lib/test analyze 无 error/warning，保留 16 条既有 info；能力生成一致性、两版纯 Dart 能力断言、差异空白检查通过。Python 能力测试 3 项、Android 构建包装 6 项通过，1 项真实 Gradle 集成跳过；未运行 Go、Kotlin、Swift 编译，也未执行原生平台构建。
- 必做实机：Android/iOS 正反横屏锁定、快速锁解、后台/前台、自动和手动画中画、退出后恢复手机/平板方向；锁定中的快进/亮度/音量/翻页/返回不穿透，仍正常自动连播；有色彩异常设备开启/关闭偏蓝修正；跨季续播及电视遥控重试入口。未访问真实站源/海报/媒体，未提交或发布。
- 本轮直接测试执行器完整通过 7 组/29 项：解码配置 3、偏好兼容 6、选季控件 3、屏幕锁 3、播放布局 3、玻璃面板 2、睡眠播放 9。另 5 组/79 项断言全部通过但进程收尾超时：手动选季 15、方向锁队列 6、自动续季 21、播放会话 22、暂停/seek恢复 15；不计为完整运行通过，须标准 CI `flutter test` 核验。已修复电视选季首次加载失败后的遥控重试焦点不可达问题并补键盘重试测试。全工作区 27 个变更应用/测试 Dart 文件格式检查及 29 个变更 Go/Dart 文件语法检查通过（含上一批未提交改动）；未把 Kotlin/Swift 当作已编译。
