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

调试真果鉴（全站源版）：`build_native.py` 加 `--all-sources`，再 `flutter run --dart-define=ALL_SOURCES=true`；iOS 对应 `build_ios.py --core-only --all-sources`，macOS 用 `build_native.py --platform darwin --all-sources`。版本是编译期开关，Dart 常量和 Go 编译参数必须一致，应用启动时会校验，避免混装原生库。

## 出包

~~~sh
python3 scripts/build_android.py                 # 红果鉴
python3 scripts/build_android.py --all-sources   # 真果鉴
python3 scripts/build_android.py --abi arm64-v8a
python scripts/build_windows.py [--all-sources]
python3 scripts/build_ios.py [--all-sources]
python3 scripts/build_macos.py [--all-sources]
python3 scripts/build_ios.py --core-only [--simulator]
python3 scripts/build_ios.py --export-options /path/to/ExportOptions.plist
~~~

产物在 `dist/android`、`dist/windows`、`dist/ios`、`dist/macos`，红果鉴以 `hongguojian-` 开头，真果鉴以 `zhenguojian-` 开头。macOS 出 arm64 + x86_64 通用 dmg；dmg 的安装窗口（背景图、图标位置、隐藏工具栏）由 `dmgbuild` 写入 `.DS_Store`，打包机需要 `pip install dmgbuild Pillow`，没装时会退回普通镜像并提示。默认 ad-hoc 签名，从网络下载的 dmg 在其他 Mac 上首次打开会被 Gatekeeper 拦一次（右键「打开」，或执行 `xattr -dr com.apple.quarantine /Applications/红果鉴.app`）。有 Developer ID 时用 `package_release.py --platform macos --identity "Developer ID Application: ..."` 重新打包并公证，才能免掉这一步。本机 Android 签名使用 `android/key.properties`（不入库）。

其他脚本：`generate_brand_assets.py` 从 `brand_icon.svg` 生成各平台图标；`clear_app_data.py`、`clear_catalog_cache.py` 清理 Windows 上的应用数据和剧库缓存。

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

直播在 Dart 侧实现：`lib/live_models.dart` 是轻量数据契约，`live_bilibili.dart`、`live_douyu.dart`、`live_huya.dart` 是平台适配，`live_feed.dart` 是列表状态。加平台实现 `LivePlatform` 并登记 `livePlatforms`，不要引入 pure_live 的完整播放器或 GetX 栈。

哔哩哔哩只用三个匿名接口：`room/v1/Area/getList`（一级分区）、`room/v1/Area/getRoomList`（按 `parent_area_id` 分区列表，`0` 是热门）、`xlive/web-room/v2/index/getRoomPlayInfo`（线路）。**不要**改成需要 WBI 签名的 `xlive/web-interface/v1/second/getList`：匿名请求会回 `-352` 风控，而 `getRoomList` 同样按一级分区排序、还不用签名。播放时 `Media(url, httpHeaders:)` 必须带 `Referer` 和 `User-Agent`，否则 CDN 回 403。

斗鱼使用平台下发的 getEncryption 描述符和 getH5PlayV1，设备编号在描述符、签名和 Cookie 中保持一致；虎牙从房间页解析流信息并按 fm 模板签名，不延长服务器 wsTime。各平台画质映射到语义选项，返回的实际档位与请求不一致时不能伪称切换成功。

直播子页必须使用 `ui/live/live_navigation.dart` 的本 Tab 导航栈，不能使用手机端会压入根 Navigator 的通用 `openPage`。收藏通过 LocalStore/LocalSnapshot 的用户级 `liveFavorites` 保存，备份只包含平台和主播展示数据，不含临时 URL、签名或 Cookie。

应用外壳通过当前 Tab 的 `NavigatorPopHandler` 分发系统返回；子路由存在时，外层 PopScope 不得再执行切回短剧的根页面返回逻辑。子页因全屏/画中画拒绝 pop，也必须消费本次返回，避免一次事件重复出栈。

### guoapp 增量源验证

- 新增短剧适配集中在 `native/core/provider_imported.go`，仅登记饭果、爽果；现有 provider（尤其红果）不重写。新增源沿用 `ALL_SOURCES` / `buildAllSources` 开关。
- 在 `native` 下运行 `VERIFY_IMPORTED_SOURCES=1 go test ./core -run '^TestImported' -count=1 -v`（PowerShell 用 `$env:VERIFY_IMPORTED_SOURCES='1'`）。验证目录、详情、分集及有限媒体前缀，HLS 继续请求分片，不请求封面。
- 爽果使用实际分类及翻页路由，搜索端有安全验证，因此仅匹配精选目录，不伪造全站搜索。伍果样本 CDN 404、河果样本媒体字节经过编码，未作为可直接播放源登记；其他未完成播放链路验证的候选也不登记。
- `lib/live_guoapp.dart` 只接入秀果面板的映客分类；每次解析重新获取临时 FLV，空列表尝试备用地址。电视及其他未经验证分类不开放。

### 直播线路与交互

- `LiveStream.lines` 是当前画质下的平台候选线路，`lineId` 是当前实际线路。`LivePlatform.resolveLine` 重新取流后再选线，斗鱼用 CDN 标识重签；不要把低画质地址混进当前画质的线路列表，也不要持久化带签名 URL。
- `live_player_gestures.dart` 统一单击菜单、双击播放及小窗还原，原生播放器页负责全屏时隐藏菜单和 4 秒收起计时。收藏与直播共享 `live_room_card.dart`，仅收藏叠平台标记和管理选择状态。
- `dart scripts/check_live_lines.dart` 检查解析、去重、画质隔离与签名；加 `--network` 会请求三平台目录及默认/备用线路媒体头，不请求封面，不输出签名 URL。需要正常解析项目依赖。

## 本地分文件存储与窗口

- 正式启动走 `LocalStore.open`，数据在应用支持目录 `store/`：`users.json` 保存身份；`profiles/<id>/<类别>.json` 保存观看记录、追剧、直播收藏、待确认剧集、播放偏好等；`settings/` 保存原快照的全局字段。少量独立外观开关继续由 SharedPreferences 保存。
- 成功迁移旧 `localSnapshot.v1`、散键和独立用户键后才删除旧键。每类文件写 `.tmp` 后换名并留 `.bak`，跨类别变更先写 `transaction.json`、完成后删除；中断启动先重放。没有身份文件但有旧记录时不能创建默认管理员。
- 非身份类损坏先恢复上一版，两版无效只忽略该类；权限/磁盘错误上抛并保留文件。用户文件两版无效时锁定访问。恢复导出保留原文，备份格式兼容旧版本；增强与目录排序/筛选旧字段不再保存。
- `dart scripts/check_local_file_store.dart <临时目录>` 可不启动 Flutter 引擎验证真实磁盘的类别隔离、历史单独写入、上一版恢复、事务重放和身份保护；`test/local_file_store_test.dart` 另测正式迁移入口及备份兼容。
- `desktop_window_state.dart` 在 `store/window.json` 单独保存普通窗口，350 毫秒防抖，排除最大化、最小化、全屏和 PiP。显示器 ID 无效回到主屏居中；纯几何用例在 `desktop_window_state_test.dart`，插件与多显示器行为仍需实机验证。

## 发布

工作流 `.github/workflows/build.yml` 在推送到 `main` 时自动运行，也可以在 Actions 里手动运行 **Build app packages**。

1. 同时提升 `pubspec.yaml` 的版本号与构建号。
2. 在 `CHANGELOG.md` 新增同名一节（标题如 `## 1.0.1+101`），工作流会把它写入 Release 说明；未验证的改动标为开发快照。
3. 推送到 `main`，等 **Build app packages** 跑完。

工作流按 `pubspec.yaml` 的版本算出 tag `app-v{version}`（`+` 替换为 `-`）。随后各平台各构建红果鉴、真果鉴两版：

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

应用显示名：Android 在 `android/app/build.gradle.kts`，Windows 在 `windows/runner/app_branding.cmake`，iOS 由 Xcode「Thin Binary」构建阶段按 `DART_DEFINES` 写入，macOS 由 `scripts/package_release.py` 打包时改 `CFBundleDisplayName` / `CFBundleName` / `CFBundleIdentifier` 后重新签名。iOS 的 `CFBundleDisplayName` 用英文 `HongGuoJian` / `ZhenGuoJian` 以通过侧载工具的名称校验，中文名写在 `zh-Hans.lproj/InfoPlist.strings`。macOS 关闭了 App Sandbox，以便本地播放代理和自选下载目录正常工作；系统代理由 `MainFlutterWindow.swift` 的 `duanju/device` 通道读取。
