# 剧场：本地推荐与短视频首集预览流

## 已批准并实现的产品选择

- 独立“剧场”Tab，位于“短剧”之后；手机五项底栏、平板/桌面侧栏、电视顶部导航顺序一致。
- 进入剧场直接展示竖向 PageView 推荐流，自动播放当前剧详情中的第一集，从 0 开始；不按正式历史续播、不自动跳第二集。上滑下一部推荐，下滑上一部。首集结束留在当前项并提示看全集。
- 只有底部整宽“看全集 · 共N集”横条 push 完整 PlaybackPage（全部 episodes，index=0，可从首集当前秒数继续）；不进入 DetailPage、不替换来源或 Tab。来源 Navigator 保留推荐项、批次与预览位置，完整播放写入历史期间不重排被覆盖的剧场批次。
- 推荐在本地计算，不复刻红果账号级算法，不上传本地历史，也不向站源接口传入用户兴趣画像。

## 推荐策略

1. 从当前用户短剧历史中取最近 30 部不同剧（source + id），直播历史不参与。
2. category/tags 去空白、转小写并按剧去重；14 天半衰期，集数进度最多增加 30% 权重。“短剧/真人剧/漫剧/AI 剧”等泛标签只计 0.1 倍。
3. 每批最多 12 项，以加权随机无放回抽样分配约 70% 匹配、30% 探索（12 项时为 8 + 4）；某池不足从另一池补齐。无兴趣记录使用默认推荐并说明原因。
4. 过滤未开启/无权限来源、已看完最后一集、不感兴趣及最近 24 小时曝光；同源 id 合并去重。只按明确身份去重，不猜测不同站源的同名剧是同一部。
5. 曝光采取保守批次口径：交给页面的整批均算曝光，而非逐像素可见性检测。候选用尽时显示空状态，不解除已看完/曝光过滤来强塞内容。

## 有界候选与请求

- 最多使用当前允许且已开启来源中的前 3 个，每个来源最多 4 次读取：`repository.cached`、`categories`、默认目录/红果现有 `recommendations(find_drama)`、最多一个匹配分类的 `catalog`。
- 每次候选返回最多取 200 项，不分页遍历全站、不补全候选详情。红果只使用现有接口，无新增服务端 API。只有当前可见预览项会读取详情和第一集媒体地址。
- 剧场请求槽最多 2 个，跨刷新/用户切换代次共享；旧代次结果丢弃且不再派生后续请求。不调用仓库全局 cancel 方法，以免中断其他已创建 Tab 的读取。
- 仓库请求自身结束前仍占据请求槽；不以 UI 超时释放槽而造成后台请求超额。底层网络超时沿用仓库实现。
- 目录部分失败仍保留可用候选；刷新、换一批、空列表重试可用。预览详情/解码失败使用消毒后的固定错误提示并可独立重试。

## 用户隔离与隐私

- `theater.hidden.<profileId>`：最多 500 个不感兴趣身份。
- `theater.exposed.<profileId>`：最近 24 小时、最多 300 个身份和时间戳。
- SharedPreferences 只写身份/时间戳，不保存媒体地址、播放凭据或观看历史副本。内存中使用现有 Drama 展示元数据。
- 写入串行化；排队执行前及异步步骤之间检查 profileEpoch/权限代次，旧用户回包不写入新用户键。
- 用户/锁定/允许来源集合改变立即清空列表和候选池并重新加载。普通五秒进度保存不触发网络请求；题材、历史身份或完成状态变化只重算内存候选。

## 预览隔离与资源约束

- `TheaterPreview` 是独立纯控制器，不使用 PlaybackSession、预加载器或正式历史保存。仅复用现有 repository.detail / resolve / release 与来源权限。
- 详情/resolve 共用一个在途逻辑槽，期间只保留最后选择意图。旧请求实际结束前不释放槽；快滑不排队请求所有经过项。每个 await 后检查 generation、权限与可见性；迟到 plan 释放其 session，不进行媒体 open。
- 所有 stop / open / play / dispose 在同一媒体串行链执行；open 使用 play:false，完成后再次验证代次才能 play，因此过期 open 不会突然出声。没有定时 delay 规避竞态，也不调用仓库全局 cancel 干扰其他 Tab。
- 生产默认 `MediaKitPreviewBackend`，每个剧场仅惰性创建一个 media_kit Player；VideoController 在第一次 open 前创建。相邻 PageView 项只有文本元数据，不创建 Player/视频层；视频 contain、黑底与轻量 scrim，不叠玻璃模糊。
- TickerMode.valuesOf / getValuesNotifier、ModalRoute.isCurrent、WidgetsBinding lifecycle 联合控制可见性；Tab 隐藏、路由覆盖、后台、锁定与用户/权限切换立即使代次失效并停止播放。允许在返回同一项时恢复内存位置，不持久化媒体 URL。
- 完整播放先 await 预览 stop/释放媒体 session，再创建完整 PlaybackHandle；PlaybackPage 自己 dispose handle。返回后仍用唯一预览 backend 重新解析首集恢复位置；不与完整播放叠播。
- 测试显式注入 PreviewBackend / PreviewBackendScope 和 onOpenFull，无编译开关将生产默认改为静音。真实原生解码、音频设备和站源可用性必须另外实机验收。

## UI 与验收

手机内容为 bottomBarInset 留空，并消费预览翻页的 ScrollNotification，避免 shell 将翻页误当目录滚动隐藏底栏；底栏可随时切 Tab 停音。标题、简短推荐原因和不感兴趣叠加在下方，刷新/换批在顶部。电视入口焦点可向上回顶导航，上下键在推荐剧之间切换；320 像素宽、2 倍字体及四种 formFactor 有布局回归。

`test/theater_test.dart` 保留推荐策略、用户隔离、并发 2 槽候选加载测试，并新增：首集零起播/不写历史/不连播，快滑最后意图，迟到详情/resolve/open 与 dispose，权限撤销，失败/空集重试，单视频层，完整播放 push 前停音、传全部集和当前位置、返回批次稳定，TickerMode/lifecycle 停音，TV 按键与手机底栏仍可点击。定向测试使用 `flutter test --no-pub --dart-define=DISABLE_REMOTE_IMAGES=true test/theater_test.dart`。

实机 profile 滑动帧耗时、内存峰值、真实站源首集解析/加密媒体兼容性与推荐质量未测；这些不是假 backend 测试可替代的效果验证。不同来源类别名称不统一，仍只做精确归一化匹配，不使用外部 AI 或臆造语义映射。
