# 液态玻璃与性能排查（2026-11-10）

本轮聚焦 `lib/ui/widgets/glass/` 与 `lib/ui/theme/glass_style.dart`：先修掉工作区里
一个会让整个工程编不过的半成品改动，再把「液态玻璃」的观感往真实材质推一档，
并清掉一批每帧都会发生的分配。

> **验证状态：本机没有 Dart / Flutter 工具链**（`dart`、`flutter` 均不在 PATH，
> 全盘也搜不到 `dart.exe`；`.dart_tool/package_config.json` 指向的
> `E:/DeepSeek Harness/.dsh-toolchain/flutter` 不存在）。
> 因此本轮改动**没有经过编译和测试验证**，全部结论来自逐行阅读，并额外做了一轮
> 独立的对抗式复查。合并前请在具备工具链的机器上跑一次
> `dart analyze --fatal-infos lib test` 与 `flutter test`。

---

## 一、修复：工作区里编不过的半成品改动

`git status` 里有三份未提交的玻璃改动，其中 `glass_popup_transition.dart`
停在一次「弹层由缩放改纯位移」重构的中间状态：

1. **`glass_popup_transition.dart`** —— 调用点处 `child: GlassPopupTransition(`
   被写了两遍，同时又给已经删掉 `alignment` 字段的构造器传了 `alignment:`，
   并在参数里引用了已被删除的局部变量 `originX`。工程无法编译。
   已按原意收敛成「只做位移、不做缩放」的单层调用。
2. **`choice_panel.dart:128`** —— 电视形态的侧边弹层同样在传已删除的
   `alignment:`，一并删除；方向上它本来就靠 `offset: Offset(4, 0)` 表达。
3. **`test/glass_popup_motion_test.dart`** —— 该测试仍断言弹层里存在缩放矩阵
   （`storage[0] != 1`）。重构既然有意去掉缩放，这条断言只会
   `Bad state: No element`。已改为断言新契约。

**保留**：`glass_style.dart` 里那份未提交的改动（背景提饱和矩阵、缓存淘汰策略
由清空改单条淘汰、`ColorScheme` 只取 5 个字段做缓存键）是本轮改动的基础，
原样保留，没有回退。

---

## 二、液态玻璃：这轮到底改了什么

原来是四层：背景模糊＋染色、顶部内高光、底缘折射带、1px 渐变描边。
问题是**只看得出「有亮边」，看不出「有厚度」**：四条边亮度分布是对称的，
读起来仍像一张半透明贴纸。这轮补了两件事。

### 1. 环绕内壁的微光（新增第 4 层）

贴着描边内侧再描一圈渐变描边，左上最亮、向右下线性衰减到全透明
（`glass_surface.dart` 中的 `gradients.glow`）。

这一层是「液态玻璃」和「半透明灰卡片」真正的分界：描边只给出一条轮廓，
而内壁微光让四条边**不再同样亮**，玻璃因此同时读得出厚度和光源方向。
它的方向与投影 `Offset(0, 8)` 一致，都在说「光从左上打过来」。

实现上刻意保持廉价：纯矢量描边，**不新增任何 `saveLayer`**。
玻璃件的图层预算只留给 `BackdropFilter` 那一层。

`innerGlow` 由 `rimHighlight` 派生，所以播放器面板（零模糊半透明白）和
关闭玻璃后的不透明档都自动拿到合适强度，不用各自再配一份。

**一处刻意的例外**：`sheen` 被调用方清零时 `innerGlow` 一起熄灭。
通知浮层（`app_notice.dart`）就是不叠任何白色高光、好让算出来的最小对比度
不被额外混色破坏的，这圈微光正好压在它算过的底色边缘上，必须跟着关。

### 2. 高光带与底缘折射带加像素封顶

两者原本都按容器高度取比例（高光 36%、底缘 22%）。比例在卡片上没问题，
一到高容器上就穿帮：

- 高光在 36% 处戛然而止，横向拉出一条**看得见的接缝**（高侧栏、竖屏面板都会踩到）；
- 底缘带盖住整个下三分之一，把半透明玻璃涂成一块**脏灰**，透视感被一起吃掉了。

现在比例之外再加绝对值封顶（`GlassStyle.sheenBand` / `edgeBand`，上限 44 / 34 px）。
矮的胶囊和卡片走原比例、外观不变，只有高容器受影响。

---

## 三、性能

| 项 | 之前 | 现在 |
| --- | --- | --- |
| 渐变 Shader | 按尺寸缓存在 painter **实例**上 | 缓存移到全局表，键为 `(GlassStyle, Size)` |
| `Paint` 对象 | 每次 `paint()` 新建 3 个 | 填充 / 描边各复用一个静态实例 |
| 高容器上的额外覆盖面积 | 高光的 36% ＋ 底缘的 22% | 各封顶到 44 / 34 px |

第一条是本轮最实在的一处。painter 每次重建都会换一个新实例，**实例级缓存
在滚动和动画里几乎总是落空**，`createShader` 连同它内部的临时
`LinearGradient` 于是每帧重造一遍；列表里一批玻璃件就是一批垃圾。
改挂全局表后重建照样命中，表仍然有界（48 条，超限丢最旧的一条，不清空，
避免在用的玻璃件同时换到新 Shader）。

> 遗留：`app_notice.dart:69` 每次 `AppNotice.of()` 都新建一个 `GlassStyle`，
> 这个实例做键必然不命中。它只在浮层弹出时构造一次、不进帧循环，
> 所以没动；真要修就把它接进 `GlassStyleResolver` 的缓存。

### 顺带确认没问题的几处

- `GlassStyleResolver._schemeKey` 取的 5 个字段（`brightness` / `surface` /
  `primary` / `surfaceContainer` / `outlineVariant`）**恰好覆盖** `_build` 与
  `_opaque` 读到的全部字段，不存在缓存串色。
- `_GlassRimPainter` 每帧换实例，但 `shouldRepaint` 只比实例身份，
  而样式来自全局缓存实例，所以滚动时**不会触发多余重绘**。设计是对的。
- `GlassSurface` 的抽屉顺序（模糊层在 `RepaintBoundary` 之外、染色 `Material`
  在 `BackdropFilter` 之内，配合 `BlendMode.src`）是对的，没动。

---

## 四、顺带修掉的既有缺陷

**`test/glass_motion_test.dart:244` 断言永久失败。**

```dart
expect(AppMotion.enter, const Duration(milliseconds: 240));  // 旧
```

`AppMotion.enter` 实际是 **480 ms**（`lib/ui/app_motion.dart:7`）。
这是把 `enter` 从 240 改成 480 时漏掉的陈旧字面量，该条 `testWidgets`
在 main 上一直红着。CI 的 `checks` 作业对这些步骤都挂了
`continue-on-error: true`（见 `.github/workflows/build.yml:36-44`），
所以红了也不拦出包，一直没人看见。已对齐为 480。

> 建议单独决定 `continue-on-error` 的去留：`dart analyze` 与 `flutter test`
> 目前都不拦发布，真正拦住发布的只有编译本身（上一轮 Android 作业就是因为
> `settings_sections.dart` 的 `late final` ＋ `const` 构造器编译失败才断的，
> 那处在新提交里已经修好了）。

---

## 五、UI 与代码建议（未改，供决策）

1. **`group_card.dart:16` 的阴影**：`GroupCard` 用 `blur: false`（不透明卡片）
   却留着 `showShadow: true` 默认值，于是每个设置分组都要画两道模糊阴影。
   工程里其它静态卡片（`live_page.dart:300`、`:538`、`theater_page.dart:499`）
   都显式关掉了。若设置页的悬浮感不是刻意设计，这里补 `showShadow: false`
   既统一观感又省两趟模糊。
2. **`glass_selection_track.dart:83`**：`BoxDecoration` 同时给了 `color` 和
   `gradient`，`gradient` 会覆盖 `color`，那句 `secondaryContainer` 是死代码
   （渐变第二档本来就是它）。纯清洁问题。
3. **`GlassSurface` 的 `borderRadius` 与 `interactive` 组合不一致**（潜在，当前无触发）：
   `shape` 取 `borderRadius ?? BorderRadius.circular(radius)`，但交互反馈走的是
   `GlassFeedback(radius: radius)`。传了逐角圆角时，压感描边会用均匀圆角。
   已确认当前**没有任何调用点**同时传 `borderRadius` 和 `interactive: true`，
   所以只是隐患；将来做底边不圆的面板时会立刻踩到。
4. **弹层动效**：`GlassPopupTransition` 现在只做位移＋淡入。位移不做缩放是对的
   （缩放会让模糊层在过渡中重采样，和背后滚动内容互相闪烁）。若还想要
   「从锚点长出来」的方向感，用 `Transform.translate` 的不同初值表达，
   **不要**退回缩放。
5. **`GlassFeedback`** 用 `TweenAnimationBuilder` 包 `AnimatedScale`，一次按压
   有两套独立动画（高光一套、缩放一套），时长虽然取自同一组 `AppMotion` 常量，
   但两条曲线各跑各的，快速连点会轻微不同步。要收干净就合成一条
   `AnimationController` 同时驱动二者。

---

## 六、改动文件

| 文件 | 性质 |
| --- | --- |
| `lib/ui/widgets/glass/glass_popup_transition.dart` | 修编译错误 |
| `lib/ui/widgets/choice_panel.dart` | 删已失效参数 |
| `lib/ui/theme/glass_style.dart` | 新增 `innerGlow`、`sheenBand` / `edgeBand` |
| `lib/ui/widgets/glass/glass_surface.dart` | 重写 `_GlassRimPainter`，新增 `_GlassGradients` |
| `test/glass_popup_motion_test.dart` | 断言改「不缩放、纯位移」 |
| `test/glass_motion_test.dart` | 修永久失败的字面量 |

未触碰 `live/`、`source/`、`native/`、`worker/`、`packages/` 与平台目录。
