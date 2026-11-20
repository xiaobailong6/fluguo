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
dart analyze --fatal-infos lib
dart analyze --fatal-infos test
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

面板固定在右下角，显示 fps、最近 180 帧的 p50/p95 帧耗时、超预算帧占比与常驻内存。帧预算按当前显示器刷新率计算（60 Hz 约 16.7 ms，120 Hz 约 8.3 ms），没有有效读数时回退到 60 Hz；预算变化时重置采样窗口。点按展开 build/raster 与预算，长按清零。未定义 `PERF_HUD` 时不注册计时回调。

采基线时固定设备、刷新率、网络、片源及操作序列（例如：冷启动 → 短剧列表滑到第 3 屏 → 进详情 → 播放 60 秒 → 后台听音 → 返回），改动前后各重复至少 3 次，比较 build/raster p95、超预算帧比例及 RSS；请求数、剧库写入次数与帧耗时分开记录。没有真机数据时不要宣称帧率或耗电收益。

### 1.0.104 性能优化约束

- 下载普通进度由单一后台 checkpoint 写入者合并处理，先记尝试时间，失败也限频；锁内冻结深拷贝，锁外排序、JSON 和 fsync，最后按 indexEpoch 短锁 rename。暂停/删除/转换等耐久事务仍同步提交，并使旧 checkpoint 失效。snapshotSince 缓存不可变 JSON/指纹，所有可见状态变更失效，读取不失效。
- 转换和标准化保留每任务 processing/converting 占用，锁外哈希/大目录清理后检查任务身份；正常 rename 验证同一文件对象后复用本次摘要，重启/未知结果恢复仍完整哈希。迁移用 moving 冻结路径，锁外等待 worker、复制和清理，路径提交仍同步，冲突导出/合并/转换拒绝。
- 目录持久化保持进入/返回持有 engine.mu 的内部契约，但排队等待及深快照编码/落盘会释放核心锁；分类已落盘 revision 由串行提交器统一维护，清缓存等待已有租约并清理该状态，不能另用旧 revision 回滚。目录游标与数据仍原子保存。
- cachedSearch 是可选协议能力。新核心在 Go 中按原多词 AND 语义过滤再返回，未宣告能力时 Dart 使用旧 cached 接口并显式过滤；权限 epoch 与清缓存屏障不变。SourceCatalog 维护分类计数，类别集合/远端顺序未变时复用不可变分类列表。
- 稳定 HLS 列表每片释放只减租约；发布/回收时标记 retired 和不可达资源，仅旧代次最后一个租约释放才做全表 GC。仍保留最近三代、KEY/MAP 和在途子列表，容量失败保持原子性。
- 元数据刷新仅合并写队列末尾同用户批次，其他写操作是屏障；字段比较替代整库 JSON 比较，分组写时复制，只编码脏分类。详情发布有明确持久化责任，系列候选每批预解析一次，保留集数峰值和首次已读基线。
- 下载 UI 分离结构和行进度通知，原业务监听仍收到全部事件；仅活跃页签派生，可见行读取最新 job，单剧页只聚合目标剧。归档未改变时复用分组/排序，切页仍退出选择模式，完成/失败/权限变化不延迟。
- FLV reader 为每个 tag 保存完整自有缓冲区，takePacket 仅修改头部时间戳并单次转移，encode 仍返回独立副本。输出只合并已到达的完整 tag，64KiB/32包/约4ms 任一阈值或即将等网络时 flush；保留背压及超时。历史采样索引只缩小候选，最后仍逐字节确认，不能用哈希相等认定帧相同。
- 直播 watchdog 更新最后推进时间而不逐事件重建 Timer；隐藏播控/后台/非当前路由停止缓存测速，纯时钟按分钟边界更新。同次斗鱼解析复用有效描述符，过期重取、被拒绝只额外刷新一次，不跨次缓存签名材料。
- 合成基准：`dart run scripts/bench_live_flv.dart`；在 native 下 `go test ./core -run '^$' -bench 'BenchmarkNative(Download|CachedSearch|StreamStable)' -benchmem`。测试中的操作计数验证无变化不复制/编码、进度不重建整页、稳定 HLS 不扫描；这些结果不代表真机 FPS、电量或真实 CDN 延迟。

## 架构

Flutter 界面 + Go 原生核心。站源请求、解析、签名、缓存、下载调度和播放代理都在 Go 里完成，Dart 只负责界面、播放器和本地用户数据。

- **FFI**：`native/bridge` 以 `-buildmode=c-shared` 只导出 `DuanjuRequest(json) -> json` 与 `DuanjuFree`。`lib/core_bridge.dart` 的 `NativeRepository` 经 `native_request_pool.dart` 编码/调度，`native_worker.dart` 的常驻 isolate 执行 FFI、解码 JSON 并配对释放 C 指针；Go 的 `app_protocol.go` 负责信封与错误码，`app_runtime.go` 按 action 分派。启动先查询无副作用的 `protocol`，验证版别、协议兼容范围与必要能力，再执行 `initialize`。新增能力两端都要改。Android 与 Windows 动态加载（`libduanju_core.so` / `duanju_core.dll`）；iOS 与 macOS 使用 `-buildmode=c-archive` 静态库（`ios/DuanjuCore`、`macos/DuanjuCore`）链进主程序，Dart 侧用 `DynamicLibrary.process()` 查符号。
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

斗鱼使用平台下发的 getEncryption 描述符和 getH5PlayV1，设备编号在描述符、签名和 Cookie 中保持一致；虎牙从房间页解析流信息并按 fm 模板签名，不延长服务器 wsTime。全局默认画质仍使用语义偏好；虎牙房间内用 `-(iBitRate + 1)` 标识真实码率（原画为 -1），按真实码率去重，匿名过滤 4K/HDR，缺失档位返回实际回退结果，不伪称切换成功。

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
- 直播专用 mpv 属性为 `cache-pause=no`、`force-seekable=no`，直连与本机中继一致，保留缓存且不改变短剧/点播策略。键盘作用域覆盖视频与播控，支持 Space/Esc/F11、F 全屏和 M 静音恢复原音量；弹窗、输入框、锁屏优先，电视方向键保留唤出菜单语义。
- `live_recovery.dart` 合并错误、EOF 与 20 秒无播放推进恢复：1/2/4 秒退避最多三次，30 秒持续正常推进才重置预算；短于卡顿阈值的定时续期若没有实际进度，也归入同一失败预算，不能靠重新 open 无限延期。自动续期期间的手动画质/线路选择保存为最新请求并使旧操作失效。第一次刷新原线路，后续尝试备用 CDN；用户暂停/后台/销毁取消调度。播放意图独立于实际 playing，恢复不能因断流而变成暂停，也不能覆盖主动暂停。
- `live_flv_relay.dart` / `live_flv_format.dart` 对带 `renewAfter` 的 HTTP(S) `.flv` 建立带随机秘密路径的 IPv4 回环端点；经典 AVC 与可选 AAC 才尝试关键帧续接，最多旧/新两条上游连接，预取与 tag 有界，输出有背压。续期不重开播放器；编码配置变化、不支持格式或中继失败退回直接播放及有限恢复。暂停/隐藏/换源/退出关闭中继，迟到响应不复活会话；不修改服务器签名或有效期，不落盘临时 URL/headers。
- 新增 `live_recovery_test.dart`、`live_player_recovery_test.dart`、`live_keyboard_test.dart`、`live_huya_quality_test.dart` 和 `live_flv_*_test.dart`，使用假播放器/合成 FLV/本地 HTTP 服务验证，不等同于真实 CDN 长播、原生解码或真机性能验收。
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
Verify 的 Dart 作业按 `dart format --output=none --set-exit-if-changed lib test` 阻塞格式，并以 `dart analyze --fatal-infos lib`、`dart analyze --fatal-infos test` 两步执行分析（`dart analyze` 只收一个目录）；Go 作业在 `native` 下检查 `gofmt -l .` 输出非空即失败，再跑 `go vet ./...` 与两版 race。生成文件 `lib/source_capabilities.g.dart`、`native/core/source_capabilities_generated.go` 由生成器按格式化宽度输出，`--check` 必须与 formatter 结果一致，不能手改生成物。

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

### 1.0.95 上游交互动效融合（保持现有样式）

- 基线 `d36b94d`，上游核对至 `5a7a116530fcf4242bfc6da08209585e267629cb`，增量提交和源码取舍详见 `UPSTREAM_SOURCE_ANALYSIS.md`。未覆盖 `source/`、`live/`，未修改主题、全局转场、预测返回、Tab 导航、海报菜单、播放会话、依赖锁或数据格式。版本为 `1.0.95+195`。
- `StateIcon` 只动画当前图标，不替换外层按钮、焦点或语义；`ControlPresence` 退场开始即排除点击/焦点/读屏，淡出结束才 offstage。播放器菜单复用 `LocalContentTransition` 的首次入场和 8dp 垂直位移，不缩放玻璃；屏幕锁入口位置不变。
- 搜索动效以已提交查询和首屏状态为身份，不由建议输入/分页触发；直播使用 `SliverFadeTransition` 包住现有内容分组，不包浮动顶栏，不改滚动几何。所有新增动效遵守现有 `AppMotion` 时长、RTL、电视限制、减少动画和隐藏 TickerMode，隐藏后不补播过期切换。
- 静态检查：全 `lib`/`test` 分析无 error/warning，保留 16 条既有 info；21 个变更 Dart 文件格式检查、21 个变更文件语法解析及 `git diff --check` 通过。
- 实际执行：使用现有 Flutter 前端编译器与 `flutter_tester` 直接运行，设置 `DISABLE_REMOTE_IMAGES=true`。11 组 / 65 项完整通过：`control_motion` 7、`local_content_transition` 6、`sliver_content_transition` 7、`search_content_motion` 4、`live_page` 10、`player_screen_lock` 3、`live_controls_layout` 4、`poster_follow` 6、`glass_motion` 9、`glass_popup_motion` 6、`live_shell_back` 3。执行器同时检查退出码与“All tests passed!”标记，不能仅凭进程退出码判断。
- 旧测试夹具修正：海报操作等待四秒提示条退场；玻璃选择器断言对齐原有 12dp 边距，并为播放器面板补 AppScope；批量收藏在 `runAsync` 中完成，浮栏反向测试先等待首次入场。未通过修改生产界面来迁就断言。
- 额外回归仍有 **3 个既有失败**：`shell_scroll_motion` 为 7 通过 / 2 失败（减少动画快速切 Tab 的 RenderAnimatedSize 布局断言、浮栏中途反向透明度不连续）；`theater_back_navigation` 为 14 通过 / 1 失败（仅剧场可见时 UI 返回未出现退出提示）。将 `d36b94d` 应用源码导出至临时目录、使用同一套最终测试夹具隔离编译运行后，三者均以相同断言复现；不能将这两组标为通过，本轮未扩大修改导航实现。
- 未执行：标准 Flutter 全量/双版别测试、Go 测试/race、原生平台构建、Android/iOS/Windows/TV 实机或帧率验收。现有 CI 仍递归运行全部测试，未新增跳过。独立复核因无法读取基线 diff 未开展，不计作已完成审查；已直接检查本轮差异并完成上述回归。
- 实机重点：快速切换图标/弹层、TV 遥控焦点、锁按钮退场后不穿透、搜索键盘焦点与分页滚动、直播浮动顶栏和返回分区、减少动画与后台恢复。未安装 SDK、访问真实站源/海报/媒体、提交、推送或发布。上游新增弹幕表情/合并与锁按钮换位不在本轮移植范围。

### 1.0.96 Windows 全屏、分类缓存、交互修正与弹幕合并/表情

- 基线 `f43c98c`（DC148），上游核对至 `6364ecc`，红果模块核对至 `dc5ae49`（1.0.4）。未覆盖 `source/`、`live/`，未改主题、玻璃材质、颜色、字体、圆角与页面布局，未引入听书链路、D3D11 后端或锁按钮换位。版本为 `1.0.96+196`。
- `windows/runner/flutter_window.cpp` 以 `WINDOWPLACEMENT` 取代矩形快照：进入全屏前清除 `WS_MAXIMIZE` 并记录 placement，退出用 `SetWindowPlacement` 恢复最大化或普通窗口；DWM 过渡先读原值再临时禁用、离开时恢复，失败保留待重试状态。先做快照与显示器校验再改状态，任一 `SetWindowPos`/`SetWindowPlacement`/样式写入失败都回滚并返回 `PlatformException`，画中画与全屏通过 `fullscreen_before_mini_` 互锁，`OnDestroy` 恢复过渡与置顶层级不变。
- 分类缓存新增按原生站源的 `categoryRevisions`：仅完整成功获取后写入新修订，磁盘落盘失败回滚修订而不虚报；网络或解析失败时若有可用旧分类则静默降级，否则仍向上层返回错误；`force` 继续绕过缓存，DSD 内部缓存随修订失效。红果改用“基础 genre 齐全 + 至少一个 tag”判断完整性，不再用条数多于基础分类来推断。清缓存同时清空修订，缓存读取租约与既有安全校验不变。
- `scroll_chrome.dart` 的隐式动画改用固定 `AppMotion.curve`，反向时进度连续；`AppMotion` 早已注明同类隐式动画不应随方向换曲线。`explore_page.dart` 在减少动画时省略 `AnimatedSize` 直接采用最终尺寸，避免零时长动画在隐藏 sliver 布局中同步触发 `markNeedsLayout`；正常模式时长、曲线与视觉不变。`app_shell.dart#_armExit` 在登记帧末检查后主动 `ensureVisualUpdate()`，静止画面下 UI 返回也会执行。
- 弹幕合并为纯派生：`DanmakuController._mergeItems` 在 ID 去重、屏蔽词过滤、时间排序之后按组首时间固定窗口合并，`count>1` 时在排期文本末尾追加 `×N`，不新增请求、不改锚点、不移动原始条目时间，关闭或改窗口只重排显示。表情在 `lib/danmaku_emoji.dart` 以白名单词典解析，`DanmakuEmojiLayout` 用同一 `TextScaler` 测宽与绘制，图片边长取 `max(缩放假名, 原文宽度)` 因而异步加载或失败都不会突破既有碰撞保护；资源缺失时回退原文，`paintImage` 传入现有不透明度。排期仍在原 `_DanmakuOverlay` 内复用单 ticker、可见窗口游标与测量缓存。
- 会话侧只新增 `_emoji` 变化检测调用 `DanmakuController.refreshStyle()`；未向会话广播，避免存档通知被放大成会话级重建（该写法曾使 `playback_session` 的预开集用例失败，已改正并复跑）。
- 静态检查：全 `lib`/`test` 分析无 error/warning，保留 16 条既有 info；变更 Dart 文件格式、21 个变更 Go/Dart 文件语法解析、`git diff --check` 通过。Python：打包 5、能力 3、缓存目录 6、生成一致性 1、Windows 全屏结构 7 项通过。
- 实际执行（现有前端编译器 + `flutter_tester`，`DISABLE_REMOTE_IMAGES=true`，同时校验退出码与 “All tests passed!”）：`danmaku_merge` 5、`danmaku_emoji` 6、`settings_danmaku_options` 2、`danmaku_controller` 13、`danmaku_overlay` 9、`danmaku_window` 4、`playback_preferences` 6、`playback_sleep` 9、`playback_session` 22、`shell_scroll_motion` 9、`theater_back_navigation` 15。
- 仍无法在此环境验收：`explore_hero_motion` 与 `ui_performance` 在本机挂起（`explore_hero_motion` 用 `d36b94d` 基线单独运行同样挂起，属既有环境问题，未标为通过）；Go 编译/测试/race、Windows 原生编译、Android/iOS/Windows/TV 实机与帧率验收均未执行。
- 实机重点：最大化→全屏→画中画→返回→退出全屏的层级与任务栏、DWM 动画恢复、多显示器；分类修订后重启只刷新对应站源、失败保留旧分类；快速滚动浮栏反向、减少动画下切 Tab、仅剧场可见时两次返回；弹幕合并跨窗口/回拖计数与屏蔽、表情缺图降级与透明度、字号缩放下的测宽碰撞。未访问真实站源/海报/媒体，未提交或推送。

### 1.0.98 下载导出入口与性能/UI 修复

- 「设置 → 下载 → 下载完成后自动导出」为一级开关，沿用已有 `autoExport` 偏好，默认关闭。Android 开启时检查权限、必要时申请；拒绝或授权期间用户已切换均不启用。其他平台显示不可用说明，不伪装支持系统相册导出。导出目标仍为 `Movies/剧名/第xx集.mp4`；只登记开启后新进入处理流程的任务，不追溯历史下载。删除 App 内副本是单独的可选开关，默认关闭。
- 下载列表与导出器共同按 `id + created + revision` 判断文件版本。待办保存后立即检查已完成快照；旧导出完成/失败不会覆盖同 ID 新任务的待办。用户关闭或撤权后不再启动新导出，正在执行的复制无法撤回，后续删除仍需重新校验。
- 后台播放许可与弹幕可见性分离：不可见时不拉弹幕，恢复时直接加载当前位置。剧场进入全集在 suspend/steal 捕获现场后取续播位置；未观看的预开集切换不生成旧集历史。
- 手机导航行高与页面占位共用实际文本测量；电视分类栏保留单一挂载位置；直播顶部随文本伸展，减少动画时不使用零时长 AnimatedSize。直播缩略图按 128/192/256/384/512/768/1024/1200 档解码。
- 桌面普通焦点按键不再被根组件吞掉；海报菜单退场期间的透明 Overlay 拦截穿透，完全离场后还原当前页面上的原焦点。根页系统返回不再被内层空栈占锁；500 毫秒重复返回防护与 Flutter 输入采样时钟一致。
- Go 详情缓存比较合并后的完整值，只在变化或之前写盘失败时持久化，保留原子写和游标隔离。相同 5,000 条样本重复读取 10 次，两轮均为 0 次重写（审查前每轮 10 次、9,889,450 逻辑字节）。不把该结果解读为真机 FPS/电量提升。
- widget 测试经注入的 `runWatchBatch` 调度器执行同一历史编码函数，避免 FakeAsync 等待真实 isolate 挂住；正式构造默认仍为 `Isolate.run`，真实存储/后台编码测试单独覆盖。通用历史 fixture 使用当前时间，不因固定日期超过 30 天而失效。
- 生成器和 formatter 已对齐。Verify 的主应用格式及 `--fatal-infos` 是阻塞检查；Go 以 `gofmt -l` 输出是否为空判断。未批量格式化 `source/`、`live/`、本地第三方覆盖包；依赖锁文件未变。原未提交的平台媒体控制修改保留。
- 实机待验收：Android 下载完成后在系统视频目录生成文件、拒绝/重新授权、同集重下载与可选删除；多屏与原生全屏/PiP；读屏、电视遥控及刷新率下的 profile 基线。未执行四端发布构建、安装或发布。
- 最终验证环境为恢复的官方 Flutter 3.47.4 / Dart 3.13.3、Go 1.25.6。`flutter test --no-pub --dart-define=DISABLE_REMOTE_IMAGES=true`（本地并发 5）与加 `--dart-define=ALL_SOURCES=true` 各 966 通过、0 失败、2 个符号链接权限用例跳过；整个进程均正常结束，退出码 0。导航专项另有 28 项通过，未通过跳过历史文件缩减套件。
- `dart format --output=none --set-exit-if-changed lib test scripts`：350 文件、0 差异；三个目录各自 `dart analyze --fatal-infos` 无诊断。`gofmt -l native`：196 文件、0 输出；生成一致性、两版能力检查、真实临时目录存储检查、离线直播线路及 Worker 语法通过。Python scripts 36 通过 / 1 Gradle 集成跳过，Android 契约 2 通过。
- Go 两版 `go test -count=1 ./core` 各 303 通过 / 0 失败 / 5 顶层跳过；包含子测试计 540 通过 / 11 跳过。跳过来源为 3 个 FFmpeg 解码、7 个符号链接相关测试/子测试、1 个实站 opt-in。`go vet ./core` 通过，模块级 bridge 与 race 构建仍缺 GCC，不能将核心包结果当作整模块或竞态检查通过。

### 1.0.99 五项边界修复与回归

- 自动导出：登记时的 `delete` 与当前 `deleteAfterAutoExport` 共同决定清理，`exportDownload.shouldDelete` 在系统复制成功后、真正删除前再次检查。关闭清理属于正常保留，不抛导出失败；任务版本、权限、用户与合并占用的原有检查仍保留。覆盖复制前关闭、复制中关闭、登记保留后再开启、始终允许删除四种真实导出通道流程。
- 播放意图：加载/重开/续季窗口接受最后的 play/pause，但不播放尚未替换的旧媒体。普通 open 完成且 rate 设置后再次核验 ticket、前后台许可、意图和实际 playing，补上 open 参数已冻结后收到的 play。新增四个平台标记的通道回归，平台标记测试不等于原生平台运行验证。
- 预览接管：`player.state.completed` 的 adopted plan 交给正常 `play` 释放并重开，按入口给定位置恢复。正式测试要求已结束现场从零实际播放、仅 resolve/open 一次、释放旧计划；未结束现场保持原位置且零重开。
- 中断恢复：Android `interruptionId`、iOS `interruptionID` 在中断开始时递增，pause/play 传同一编号；普通命令不带编号。Dart 仅登记有效播放意图产生的中断，编号匹配才恢复；明确操作先取消旧编号，并由 `cancelResume` 通知当前原生 owner。睡眠到期、关闭后台播放、切用户/权限失效会取消；屏幕锁定时消费并拒绝恢复，解锁后重复回调也不生效。测试覆盖重复暂停、UI 两次切换、错误编号、重新加载、原已暂停、加载中恢复及旧会话回调。
- Windows：`MediaArtworkState<Target>` 是生产代码使用的平台无关 C++17 helper。请求 token 使用共享对象身份，防止路径 ABA；Update、Complete、Clear、Close 同锁执行，避免先校验后写入的竞态。Completed 只持有共享状态和 token，Close 先释放当前 updater；异步注册在 Update 解锁后执行，防止同步完成回调自锁。标题、倍速和时间线更新保留。
- 封面检查：运行 `python -B scripts/test_media_artwork.py -v`。9 项结构检查不依赖工具链；另 1 项编译运行检查会使用 `CXX` 或 PATH 上的 C++17 编译器，执行 8 组乱序/ABA、清空/换 owner、空路径/同路径刷新、销毁、异常及互斥竞态测试。产物进入 `PI_SCRATCH_DIR` 或系统临时目录，缺编译器明确跳过，不计原生通过。Verify 新增媒体步骤并设置 `CXX=g++`，缺编译器会失败；该 CI 配置尚未远程运行，helper 通过也不能替代 WinRT/SMTC 验收。
- Flutter 最终验证：`flutter test --no-pub --dart-define=DISABLE_REMOTE_IMAGES=true` 与额外 `--dart-define=ALL_SOURCES=true` 顺序全量执行，本地并发 5、单用例超时 45 秒；各 997 通过 / 0 失败 / 2 符号链接权限跳过，最终事件 `success=true`，退出码均为 0。新增正式回归 31 项。定向首批 139 项通过，补充边界后的播放相关三份测试 58 项通过；这些均包含在最终全量中，不叠加计数。
- 原审查的导出 2、四平台加载命令 4、结束预览 1 共 7 个场景复测通过。旧预览探针原本使用会抛 `UnimplementedError` 的抽象取流夹具；本轮补充有效取流返回并改为 5 秒有界等待 ready，仍要求 position=0、playing=true；正式回归另检查 completed=false、open/resolve 次数与旧计划释放，未放宽行为断言。
- 静态与离线检查：351 个 Dart 文件格式零差异，`dart analyze --fatal-infos` 分别分析 lib/test/scripts 均无诊断。`python -B -m unittest discover -s scripts -p 'test_*.py' -v` 共 45 通过 / 2 跳过；`python -B android/tests/test_media_contract.py -v` 4 通过。生成一致性、双版能力、本地存储、离线直播线路及 Verify YAML 检查通过。本轮没有修改 Go，未将上一版 Go 结果冒充本轮原生媒体验证。
- 范围检查：按修复前 918 个主工程文件 SHA-256 快照比较，保留已有未提交改动；本轮仅修改五项修复、回归、CI 和版本记录涉及文件，没有删除既有文件。第三方包及依赖锁文件保持不变，未改 `source/`、`live/` 或历史参考工程。
- 待验收：本机缺 C++/Android/Apple 完整工具链，C++ helper 尚未编译运行，四端原生构建及真实系统媒体行为未验证。真机重点为复制期间关闭删除、加载时快速 pause/play、单集播完再进入全集、音频中断后明确暂停/切用户/睡眠停止，以及 Windows 快速切媒体/退出时封面不回填。未提交、推送、打包或发布。

#### 1.0.99 Windows 构建追修：VS 2026 / STL1011

- GitHub 提交 `2198331` 的 Windows 全站源构建日志显示 runner 镜像为 `windows-2025-vs2026`、MSVC 14.51.36231；失败点在 `experimental/coroutine` 的 `STL1011 / C2338`，目标为 `runner/FlGuo.vcxproj`。依赖更新提示及 Dart 分析不是这次构建失败原因。
- 共享 `APPLY_STANDARD_SETTINGS` 仍为插件要求 C++17；在 `windows/runner/CMakeLists.txt` 单独增加 `target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)`。`media_controls.cpp`、`flutter_window.cpp`、`main.cpp` 都直接或间接包含 C++/WinRT 头，需要整个 runner 统一启用标准协程；不只对单一源文件设标志，不全局提升插件标准，不添加弃用屏蔽宏或旧 `/await`。
- 配置回归加入已接入 Verify 的 `scripts/test_media_artwork.py`：修复前 1 项失败，修复后专项 10 项通过 / 1 编译运行项跳过；scripts 全套 46 项通过 / 2 跳过（缺 C++ 编译器、真实 Gradle 集成未配置）。本次只改构建配置、配置回归及说明，未改 Dart/Go 业务、第三方包、锁文件或版本号；未重跑此前双版 Flutter 全量。
- 本地没有 MSVC，未完成修复后的 Windows 原生编译，也未触发远程 CI。提交修复后需让 GitHub 在新提交上重新运行标准版、全站源版 Windows 构建；直接重跑旧提交仍使用旧配置。未提交、推送或发布。

### 1.0.100 第一批上游增量适配

- 上游固定核对至 `51f39b58bce6b4c9d464e382e86e5f79aa2e9d2b`，本轮手工增量适配 `1c3008d`（平板键盘）、`5a17a6f` 的从头重试部分、`5556f1c`（顶栏最近搜索）、`3b16654`（PAC 诊断）。没有整提交 cherry-pick；保留已有 Windows C++20 修改、现有主题/玻璃/导航/站源实现，不改第三方包和依赖锁文件。
- 键盘修复：`AppShell._wide` 用 body 内 Builder 获取外层 Scaffold 已去除键盘 inset 的上下文。原探针 800px 视口、320px 键盘得到 160px 内容高度，修复后为 480px。正式测试在 pad/window 两种形态检查 320/450/0px 键盘切换、内容高度及侧栏满高；大键盘同时暴露的侧栏溢出用内部滚动解决，外框尺寸/间距不变。
- 从头重试：`PlaybackSession.retryFromStart()` 直接复用正常 `play(_index)`；不修改原 retry 的当前位置续播行为。错误页仅在 currentPosition>0 且非 loginRequired 时提供按钮。覆盖当前集和零起点、原 retry 保留进度、用户代次/销毁保护，以及普通/零进度/登录/本地错误四种实际按钮状态。
- 最近搜索：`RecentSearchField` 复用 SearchField，OverlayPortal 随锚点、视口、键盘和 RTL 计算有限面板范围；使用 GlassSurface 的 panel 材质，最多展示已有存储提供的 20 条记录。焦点组保留 Tab/Enter 选择，TextFieldTapRegion 让点选/长按/右键不被输入框失焦提前吞掉；Esc、外部点击、TickerMode 隐藏、路由覆盖、顶栏收起及 controller 替换均撤销弹层。外部 controller 仍由调用方持有。
- ExplorePage 对历史单独监听 store，只重建顶栏，不扩大 ExploreFeed 的数据通知范围。按用户 epoch/来源/锁定状态设置搜索子树身份；提交和删除回调再次检查 epoch、锁定和当前来源，旧回调不得操作新用户。删除失败使用已有通知提示；窄窗口仍保留原搜索按钮入口。
- `LocalStore.forgetSearch` 的列表计算移入现有写队列，避免连续删除各自拿旧快照覆盖。正式回归在旧实现下复现删甲乙后甲复活，修复后剩余顺序和重启结果正确；排队期间切用户仍拒绝旧操作。
- PAC：先解析系统脚本，成功（包括 DIRECT 的 nil,nil）立即返回，失败只增加诊断后继续原静态代理/环境变量/直连路径；没有新增直连策略。错误原文的 SHA-256 作为去重键，不在缓存内保留原文，五分钟同错限频、最多 64 条并淘汰最早项；并发去重、记录回调和可选测试时钟锁外执行。复用已有 URL 和配置秘密脱敏，事件为 `proxy.pac_failed` warning；测试使用每个 router 的可选解析器/时钟，不替换全局函数、不访问真实代理。
- Flutter 验证：3.47.4 / Dart 3.13.3，标准版及 `ALL_SOURCES=true` 全量各 1018 通过 / 0 失败 / 2 权限跳过，终态 success=true、退出码0；新增21项正式回归，定向147项包含在全量内不重复计数。357文件格式零差异，lib/test/scripts 分别 `dart analyze --fatal-infos` 无诊断。Python scripts 46通过 / 2跳过（C++编译器缺失、Gradle集成未配置），生成一致性通过。
- Go 验证：1.25.6 windows/amd64、CGO_ENABLED=0、离线模块缓存。标准/全站源核心各315个顶层测试通过、5跳过；含子测试各567通过、11跳过。跳过来自FFmpeg、符号链接权限及未启用实站联网。PAC专项12项（含子测试27项）通过，并发/限频相关100次重复共400项通过。gofmt、`go vet ./core` 通过；两版 `GOOS=windows CGO_ENABLED=0 go test -c` 均成功编译核心测试可执行文件，不能替代 Flutter Windows runner/WinRT 构建。不能把无race的并发测试当作竞态检测通过。
- 仍待原生及实机验收：本机缺MSVC/完整移动平台工具链、C编译器，Flutter四端发布构建、C++/WinRT、实际Windows PAC、iPad/Android软键盘与真机焦点操作未验收；Go race缺C工具链，旧版Windows构建问题仍需在包含C++20修复的新提交上重跑CI。未提交、推送或发布。
- 最终范围核对：922个修复前主工程文件指纹中仅本轮涉及的14个既有文件改变，另新增7个实现/测试文件，没有文件丢失。原Windows C++20修复、媒体构建回归、用户日志、第三方包和锁文件保持原样；本轮路径的差异检查通过。全工作区 `git diff --check` 仍报告用户原日志 `logs/logs.txt` 中已有的尾随空格，未擅自清理日志。

### 1.0.101 媒体边界、搜索与交互优化

- 媒体读取：播放请求仍不设置总时限；`idleReadTransport` 在实际 RoundTrip 边界补 30 秒阻塞 Read 保护，覆盖普通传输及凭证刷新读取的错误正文。已有浏览器保护复用而非双计时；每次读取结束撤销计时，消费者暂停不计为网络停滞，Close/release 继续取消上游。计时器活动状态串行校验，旧回调不能误取消下次读取。
- HLS 索引：`app_stream_assets.go` 管资源代次/租约，`app_stream_playlist.go` 管解析与 URL 改写。单会话最多 8192 资源、32 播放列表、128 代次、32768 引用；保留最近三代及在途代次，KEY/MAP 与分片一起保留。列表整批预算再提交，超限明确失败且旧索引不变，不截断 VOD/EVENT。入口可达性清理过期子列表，释放会话清空索引，迟到预取不能回填。
- 结构化错误：`app_failure.dart` 保留 code/retryAt；原 `core_bridge.dart` 导出保持引用兼容。目录部分失败可携带 warningDetails，DramaFeed 保留错误类型。搜索/短剧首屏和页脚复用 FailureRecovery：普通错误重试、网络设置、登录、站源设置；权限拒绝和版本不兼容不盲目重试。限流到时只恢复按钮，不自动请求；登录后重试前再次校验用户代次/权限。
- 搜索：仅支持在线搜索的单个站源并行读本地目录匹配和发远端搜索，不增加源站请求。缓存先到可先显示并标记「本地匹配」，远端成功后替换，分页只追加；远端先完成、查询切换、用户/权限改变或销毁后，旧缓存和旧响应不得覆盖。慢缓存不阻塞远端，缓存失败不覆盖网络结果。未扩展为聚合搜索，也不人为逐项延迟结果。
- 协议：当前 protocolVersion=1、minCompatibleVersion=1，必要能力为 structuredErrors/catalogWarningDetails。纯协议查询不初始化数据目录或下载服务；同版别旧库、缺字段、缺能力和不兼容范围均拒绝启动，未来兼容版本可通过。应用与原生库必须一起重新构建，不能复用旧 DLL/SO。
- 测试分层：新增纯错误/协议/列表测试、真实 widget 搜索/设置/锁按钮回归及 `scripts/check_native_abi.py`。Verify 两版编译 c-shared 后用 ctypes 实调 DuanjuRequest/DuanjuFree，检查握手、错误码及重复分配/释放；此检查不访问站源，不替代完整平台或播放器实机验收。
- UI：五项播放设置文案简化，保留设置逻辑、风险/权限和生效时机。手机/平板触屏横屏全屏的锁定入口移到左右中部，使用与解锁共用的 48dp 控件和安全区计算；随原菜单隐藏，隐藏后隔离点击/焦点/语义。竖屏、桌面、电视与直播入口不变，锁定不暂停视频。
- 本轮仅局部拆出 FFI worker、错误/协议、HLS 索引/改写及共用锁按钮；不改播放器会话、本地存储格式、第三方包或依赖锁文件。未打包、提交、推送或发布。
- 单次复核补齐两个边界：串行缓存抛错后再次检查销毁/代次才允许联网；红果部分搜索成功通过内存 Failure 保留原始超时、网络或限流原因，再转换为 warningDetails。新增用例覆盖销毁/新刷新、以及真实 nativeCatalog 的三类部分失败，不从中文文案猜测错误类型。
- 验证环境：复用现有 Flutter 3.47.4 / Dart 3.13.3、Go 1.25.6；没有下载 SDK。Flutter 启动脚本不正常返回时，直接以 SDK 的 Dart 执行已解析依赖的 `flutter_tools.dart --no-version-check --suppress-analytics test --no-pub`，仍使用标准 flutter test 调度与执行器，DISABLE_REMOTE_IMAGES=true、本地并发5。
- 全量基线：Flutter 标准/全站源各1054通过、0失败、2符号链接权限跳过，success=true且两进程退出0。复核修复后重跑7个受影响文件，两版各58通过、退出0；未将补测重复累加到全量数量。新增正式Flutter测试共38项，其中最后2项为复核补测。
- Go：两版核心全量各329个顶层通过、5跳过（含子测试各584通过、11跳过）；复核后的协议/红果搜索专项两版各4个顶层及3个子测试通过。媒体超时/容量/并发专项额外重复10次通过；最终 core vet 和全部Go格式检查通过。CGO_ENABLED=0 的测试不包括 C ABI 构建，不能将并发用例当作 race 通过。
- 其他检查：363个lib/test Dart文件格式零差异；lib/test/scripts严格分析无诊断；Python scripts 46通过/2跳过，Android媒体契约4通过；站源生成一致性、Verify YAML解析、ABI脚本语法与差异检查通过。
- 未验证：本机 C ABI build 在CGO关闭时不可构建，显式启用CGO后的race报 gcc不存在；新增ABI步骤未触发远程CI。四端原生包、真实网络故障/长时HLS、手机/平板旋转与锁按钮实机尚未验收。Gradle实集成与C++ helper因环境跳过。未打包、提交、推送或发布。

### 1.0.102 高优先级职责拆分（保持行为与 UI）

- `PlaybackProgressWriter` 从 `PlaybackSession` 拆出保存去重、记录组装、合并成品独立记录及存储失败提示。会话保留 saveProgress/saveWarning 入口、用户 epoch/起播许可校验、五秒计时器、退出保存和销毁后的通知保护；新模块不创建计时器或播放器、不新增写队列，不提前消费未完成写入的去重键。
- `LocalBackupCodec` 从 `LocalStore` 拆出备份校验及快照字段组装，只处理输入数据。用户列表仍使用原 _readProfiles；权限、8MiB导出限制、挂起进度刷盘、写入队列、管理员PIN恢复、独立外观键写入、系列候选迁移和最终通知均留在原处。校验规则、存储键、类型、默认值与旧备份兼容不变。
- `DownloadViewProjection` 从下载页拆出 jobs 身份缓存、来源筛选、合并任务/成品集合和编辑选择交集。仅缓存 jobs 的纯派生，权限和可变任务状态每次重算；页面保留原监听、用户切换清选择、菜单等待后的快照重取、批量操作保护和所有控件构建。
- 本轮直接实现并自行复核，未使用子智能体。以原提交为基线逐段比较；忽略空白/注释并映射依赖参数后，备份校验、字段组装、播放保存算法完全一致；下载页从内容构建到文件末尾的 UI/操作代码仅替换派生字段访问。未修改原有测试断言、Go、平台工程、第三方包、依赖锁文件和 CI。
- 新增27项正式回归：播放保存7项（含真实会话提示/退出保护）、备份15项、下载投影5项。改动前相关基线113项通过；改动后标准/全站源定向各143项通过。首次新增备份夹具的泛型Map构造错误已修正，未放宽断言。
- 最终验证：现有Flutter 3.47.4 / Dart 3.13.3，DISABLE_REMOTE_IMAGES=true，标准及ALL_SOURCES=true全量各1083通过、0失败、2符号链接权限跳过，终态success=true且退出码0；定向143项已包含在全量内，不重复计数。369个lib/test Dart文件格式零差异，lib/test/scripts分别严格分析无诊断；站源生成一致性、拆分等价核对及git diff --check通过。
- 剩余范围：本轮未改原生代码，没有重跑Go/race/C ABI；未执行四端构建、真机播放或截图对照，不把widget/源码等价检查宣称为实机像素验收。版本递增至1.0.102+202，未提交、推送或发布。

### 1.0.103 下一集分阶段预加载

- `PlaybackPreloadPolicy` 独立读取播放快照。已播放至少2秒且当前集缓冲到有效结尾（容差500ms）时，不等播放后段即可预取；本地当前集视为已缓冲。未完整缓冲时，至少播放5秒、距有效结尾按倍速计算不超过90秒且缓冲余量至少15秒才启动，已启动后低于5秒或发生buffering暂停预取。有效片尾沿用原片头/片尾重叠保护；未知时长不猜测完成。
- 数据预取与备用播放器分开：只有实际剩余观看时间不超过30秒才预开，且预取结果有效期必须覆盖预计切集时间。预取防抖200ms，保留两分钟保守TTL和凭证到期前5秒余量；过期按需刷新、失败退避30秒。只准备紧邻下一集，不递归预取后续多集。
- 切集可接管同剧/同集/同画质/同在线意图的在途预取，或短暂等待备用open，最多各自适用路径1.5秒；超时/失败回退原加载。已预开的有效且非buffering播放器沿用原同步交换路径，不重新resolve/open；备用仍buffering或open未完成时可转交有效计划与原生缓存给主播放器，旧备用停止但不释放被转交计划。错误或过期的备用计划不复用。
- 暂停不再新发起预取/预开，已缓存结果短期保留，原一分钟暂停回收保持。当前集卡顿先让路；后台（含听音）清理视频预取和备用，回前台按需恢复。用户/权限、画质、剧集/季切换、退出仍撤销旧任务；等待期间暂停/睡眠/更新跳集意图不能被旧任务覆盖。自然完成前的最后进度事件保留待接管任务。
- Go起播预算与playlist体积上限分离：最多8MiB，HLS最多4个分片或累计达到约16秒后停止，仍最多8请求、递归深度2、取数预算6秒。KEY/MAP计入请求和字节预算；不遵守Range的超预算正文不缓存。不是整集下载，不承诺每次预取满16秒；字节上限、分片长度和网络预算可能先耗尽。
- UI、设置含义和数据格式不变；「提前加载下一集」仍控制是否创建备用播放器，关闭时保留原轻量预取语义。本轮未加入聚合预取、多集下载、永久缓存或新的网络权限。
- 验收分层：策略纯测试、受控preloader任务与真实PlaybackSession假媒体回归、Go本地HTTP缓存/Range回归。未用假播放器结果宣称首帧耗时或真机瞬开；实机应固定片源/设备/网络对比切集首帧p50/p95、预取命中率、当前集卡顿、浪费流量与RSS。慢源/离线/过期仍允许正常等待和恢复。
- 实现复核补充：备用计划在open完成后继续监听错误，buffering/报错现场不直接交换；未就绪但有效的计划可以转交主播放器。失效open不得重新挂监听，退出取消监听；普通无预加载切集不执行额外await，保留原串行队列启动时序。完整回归曾暴露无条件await null使旧手势测试跨异步区等待，已修复并保留原手势断言，专项23项通过。
- 最终检查：Flutter3.47.4/Dart3.13.3、DISABLE_REMOTE_IMAGES=true、标准/全站源全量各1108通过、0失败、2符号链接权限跳过，success=true且退出0；首次全量挂起已停止，不算通过。新增25项Flutter回归（策略5、任务7、会话集成13），最终手势/会话专项23通过，均包含在全量内不重复累计。
- Go1.25.6离线核心双版各332个顶层通过、5跳过；新增预算/起播窗口2个顶层测试，含KEY/MAP、上游关闭后缓存播放及忽略Range的超大响应拒绝。core vet、全部Go格式通过；本机缺C工具链，本轮未运行race/C ABI，不能用普通并发测试替代。
- 373个lib/test Dart文件格式零差异，lib/test/scripts严格分析无诊断，站源生成一致性、差异检查通过。未改UI、平台工程、依赖、第三方包或CI；未打包、实站请求、真机测速、提交、推送或发布。使用新的8MiB/4分片预算需重新构建原生库。

## 前后相邻集缓存窗口

- `PlaybackEpisodeWindow` 只持有两个邻集，当前计划由 `PlaybackSession` 持有；窗口移动不刷新计划的原始有效期。完整身份包含用户代次、站源、剧集、章节内容、画质和在线意图。
- 仅一个预取器服务两侧，下一集优先。已取消但未结束的请求继续占槽，迟到结果释放，不并发堆积。
- 原播放器离开当前集后暂停并回零，原观看进度先保存；前后台准备不触发观看记录或自动连播。媒体操作、槽位操作和交接停声均有顺序/身份保护。
- 最多三套 Player/VideoController；后台、1 分钟暂停或内存压力回收邻集。内存压力冷却1分钟并降到两播放器模式。开启预开时仍以设备实际解码能力为限。
- native `app_stream_cache.go` 统一普通读取与预取正文：单会话8MiB，全局已缓存/在途预留24MiB。读者持有的淘汰块直到租约结束才退预算，取消写者实际释放前仍占预留。固定传输缓冲、Flutter/GPU/解码器及索引开销不包含在24MiB正文预算内。
- 这是有界起播/回看缓存，不是三集完整离线下载；命中范围优先本机读取，缺口回源。授权刷新或媒体验证器变化不得把旧片段混入新响应。
- 回归：`flutter test test/playback_episode_window_test.dart test/playback_preloader_test.dart test/playback_preload_integration_test.dart test/portrait_preload_surface_test.dart test/playback_video_ready_test.dart`；native 下 `go test ./core -run 'NativeStreamCache|NativePrefetch|NativePreload' -count=1`，然后完整 `go test ./core -count=1`。
- 实机验收仍需 Android 录屏验证首轮向前/向后、快速反向手势、不同方向视频、暂停seek后纹理，以及连续100集内存趋势；mock 测试只能证明所有权和组件复用。
- 本次验证：标准版播放/剧场/恢复相关171项通过，全站源窗口专项44项通过；最终 `go test ./core -count=1` 通过（76.841s），全站源缓存专项及 `go vet ./core` 通过，Dart定向分析无问题。race已尝试，缺GCC/cgo编译器未能运行。
- 真实红果 `2→3→2` 验证：第二集回读1MiB数据新增上游请求0，第三集预取8MiB，池占用9MiB；HTTP读租约结束后释放计数归零。CDN无ETag/Last-Modified时允许单次完整206区间快照复用，但新回源替换旧快照、禁止跨响应拼接。未打包或进行Android实机逐帧/长播内存测试。

## DC161 后切集退化排查

- 红测确认：目标预开等待期间旧播放器仍 playing；已就绪但 buffering 的邻集被丢弃并重开；两次普通输出超时使播放器池降至1；取消旧任务在接管截止前退出，新任务仍被二次200ms防抖挡住。修复后上述用例通过。
- 翻页露出邻页即暂停原集，撤回仅按最新意图恢复；临时切集暂停不取消目标预取。后台听音撤回等待恢复原集，用户暂停/睡眠/撤权保持优先。已有同集帧与可正式切入状态分离，回零等待期间不盖黑，但不提前当成零点就绪。
- `preparePlaybackVideo` 除纹理初始化还等待 Surface 绑定、本次文件 width/height、seeking=no 与接近目标的 video-pts。Android 重绑 vo 后暂停播放器也 seek 当前点以重绘，不通过 play 预热声音。该状态检查仍非 Surface/屏幕像素呈现 fence；没有实机证据不承诺零黑帧。
- 临时 TimeoutException 只禁用当前 entry 的再次预开，保留数据及池能力；真正初始化异常仍保留原降级保护。resetVideo 已包含输出等待，不再重复 prepareVideo。原生预取入口共享实际执行门闩，取消/超时不能提前释放真实占槽。
- 缓存红绿证据：8MiB正文以1KiB短读输入，原实现仅2MiB/2048块且尾部miss，修复后8MiB/128块、尾部离线hit；未知长度小playlist原预留4MiB并驱逐同量视频，修复后4KiB起步。容量扩容按新旧同时存活峰值预留，提交/取消/租约按allocated capacity退账，8/24MiB与2048块上限不变。
- 验证：最终标准版播放/页面/后台/睡眠/剧场相关191项通过，全站源窗口专项55项通过（用例集合有重叠，不累加）。包含等待seek时撤回/暂停、旧恢复任务越过新切集、暂停异常污染屏障等四个先红后绿场景。完整Go core通过（69.228s），全站源Stream/Preload/Prefetch专项通过，预取门闩重复10次通过，go vet通过。最终Dart定向分析无问题，格式与差异检查通过；本地media_kit_video文件头有既存doc info提示。
- 环境边界：无Android设备/ADB，未打包或做实际纹理/音频逐帧、长播内存验收。race尝试因cgo工具链不可用未完成；普通并发回归不等同于race通过。此次无新增实站吞吐测量，前述真实红果缓存验证属于上一轮，不作为本轮黑屏修复证据。
