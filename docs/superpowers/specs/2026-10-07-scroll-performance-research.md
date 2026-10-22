# 滚动卡顿优化：调研与可落地清单

更新时间：2026-10-07
范围：书架 / 发现 / 本地库等**列表滚动**页面的掉帧
状态：**调研 + 代码核实已完成；尚未在真机上做 profile 定量**（见 §4 验证方法）

## 1. 先分诊：哪条线程超了

一帧 16.67ms（60Hz），120Hz 手机上只有 **8.33ms**；UI 线程（build/layout）与
Raster 线程（光栅化）各占一份预算，超了才掉帧 —— 两条线的修法完全不同：

| 现象 | 说明 | 该动的地方 |
| --- | --- | --- |
| UI 线程长条 | `itemBuilder` 里干了重活、嵌套太深、测量失控 | §3.2 / §3.3 |
| Raster 线程长条 | 模糊、阴影、裁剪、透明度、大图解码 | §3.1 / §3.2 |

> 出处：[Why your ListView is slow, and the four fixes that actually work](https://fluttercook.github.io/blog/flutter-lists-performance-builder/)（2026-08-28）
> 原文："**UI thread long** → build and layout are expensive… **Raster thread long** → painting is expensive. Shadows, blurs, opacity layers, saveLayer, large images."
> 我们的核实：这段话与官方 best-practices 的 *Control build() cost* / *Use saveLayer() thoughtfully* 两节一致；诊断命令见 §4。

## 2. 结论摘要（按我们代码里的证据排序）

| # | 在哪儿 | 问题 | 依据 |
| --- | --- | --- | --- |
| P0-1 | `lib/ui/glass_title_bar.dart:56`、`lib/ui/glass.dart:71`、`lib/features/shell/home_shell.dart:150,178` | **每一页的顶栏 + 外壳侧栏/底栏都是 `BackdropFilter` 毛玻璃（`enabled` 默认 true，blur 20–22）** —— 身后正是滚动内容，滚动时每帧都要重新模糊这片区域 | 官方 issue 两例（§3.1） |
| P0-2 | `lib/features/common/source_image.dart:48-56` | 封面走 `CachedNetworkImage` **没给 `memCacheWidth`** → 按原图分辨率解码（封面常 800×1200+），解码内存 = w×h×4 | 包源码支持该参数（§3.2） |
| P1-3 | `lib/features/library/library_page.dart:512` + `:831-833` | 书架外层是 `AppScrollView(children:)`（**eager** `ListView`），内层 `FeedView(shrinkWrap: true)` —— shrinkWrap 必须量完全部条目才能确定自身高度 | 官方 best-practices「Avoid constructors with a concrete List of children」（§3.3） |
| P1-4 | `lib/ui/app_scroll_view.dart`（`children:` 形态在 24 个页面使用） | 长列表首帧构建全部子项；本地库页还用 `for` 循环摊开卡片 | 同上 |
| P1-5 | `lib/features/local/local_library_page.dart:179`、`local_library_detail_page.dart:341`、`detail_page.dart:1498`、`anime_downloads_view.dart:96`、`novel_detail_page.dart:750` | `FadeSlideIn` 逐项入场动画：懒加载每滚进来一项就新起一个 AnimationController（`delayMs: 25*index`），快滑时几十个动画同时在跑 | §3.4 |
| P2-6 | `main.dart` | 没有调 `PaintingBinding.instance.imageCache` 上限，用 SDK 默认 **1000 张 / 100 MiB** | 本机 SDK 源码（§3.2） |
| P2-7 | 各固定行高列表（历史、下载） | 未用 `itemExtent` / `prototypeItem` / `itemExtentBuilder`（本机 SDK 已支持） | §3.3 |
| P2-8 | 图多的列表 | `cacheExtent` 在本机 SDK 已标废弃 → `scrollCacheExtent` 可调小预渲染区省内存 | 本机 SDK 源码（§3.3） |

> **用户当前设备上「只有 15 个收藏」**：P1-3 / P1-4 这类「建得多」的问题在十几条量级看不出来，
> 所以**先怀疑 P0（Raster 线）**；P1 是「收藏涨到几百条以后会突然变卡」的隐患。

## 3. 逐条：出处 / 原文 / 我们的核实

### 3.1 毛玻璃 `BackdropFilter`（P0-1）

> 出处：[flutter/flutter#191207 — \[Windows\]\[Impeller\] BackdropFilter blur has significantly higher raster cost than Skia…](https://github.com/flutter/flutter/issues/191207)（open，label: `e: impeller` / `platform-windows` / `from: performance template`）
> 原文："On Windows, with Impeller… **The raster performance on Impeller is significantly worse than how it is on Skia** for all tested cases except for **C** and **G**…"（复现样本：36 块 `BackdropFilter` 毛玻璃面板，blur sigma 15，滚动）

> 出处：[flutter/flutter#168788 — UI jank with Impeller on Android when using CustomScrollView](https://github.com/flutter/flutter/issues/168788)（open，label: `f: scrolling` / `e: impeller` / `found in release: 3.29, 3.32`）
> 原文："Noticeable UI jank and frame drops during fast scrolling. **Performance is visibly worse in profile mode compared to when Impeller is disabled (i.e., when using Skia)**."

> 出处：[flutter/flutter#126353 — \[Impeller\] Blur BackdropFilter performance degradation](https://github.com/flutter/flutter/issues/126353)（closed，`found in release: 3.10`）

**我们的核实**：
- 顶栏：`GlassTitleBar` 的 `flexibleSpace` 直接是 `GlassSurface(blur: 22)`（glass_title_bar.dart:56），
  而 `GlassSurface.enabled` **默认 true**（glass.dart:22），`enabled` 为真时走
  `BackdropFilter(ImageFilter.blur(sigmaX/Y: blur))`（glass.dart:71-72）。
- 外壳：`home_shell.dart:150`（侧栏）与 `:178`（底部导航栏）各一块 `GlassSurface` ——
  **它们压在滚动内容之上，横向 336px 宽的侧栏在截图里清晰可见**。
- 我们自己的注释其实已经点到了这个代价：glass.dart:9「只在身后有内容（图片 / 滚动列表 /
  变暗遮罩）时才用 enabled=true」—— 而书架/发现的身后**正是滚动列表**，条件成立，模糊是开着的。
- ⚠️ 未核实：我们 App 的 Android/Windows 构建到底跑在 Impeller 还是 Skia。
  本机 SDK 里 `flutter_tools` 只在显式指定时传 `--enable-impeller`（android_device.dart:658-665），
  其余走引擎默认；Manifest 与 runner 里我们没有相关开关。**用 §4.2 的 A/B 命令两分钟就能定**。

**候选改法**（按代价从小到大）：
1. **滚动中降级**：监听滚动状态，滚动期间把 `GlassSurface.enabled` 关掉（退成半透明纯色），
   停止滚动 150–300ms 后再打开。视觉几乎无感，省掉每帧 blur。
2. **外壳侧栏/底栏先去掉模糊**（纯半透明 + 主题色），顶栏保留 —— 侧栏面积最大，收益也最大。
3. 只对**静态背景图**做模糊（一次性画进背景层），不模糊滚动内容本身。

### 3.2 封面按原图解码 + ImageCache 默认上限（P0-2 / P2-6）

> 出处：[Flutter 官方 best practices](https://docs.flutter.dev/perf/best-practices)
> 原文（*Minimize use of opacity and clipping*）："**Clipping** doesn't call `saveLayer()`… but clipping is still costly, so use with caution."

> 出处：[fluttercook — Fix 4: size images to the cell](https://fluttercook.github.io/blog/flutter-lists-performance-builder/)
> 原文："Decoded image memory is width × height × 4 bytes, regardless of file size. Forty rows each decoding a 3000-pixel source is gigabytes of pixels for a screen showing 56-pixel thumbnails. **`cacheWidth` changes the decode, not just the display**."

> 出处：[技术栈 — Flutter 列表性能优化](https://jishuzhan.net/article/2104488362811600897)（2026-09-28，按 Flutter 3.47 重写）
> 原文："`ImageCache` 默认大概能放 100MB / 1000 张，注意这是**解码后的位图**，一张 2K 原图解码出来就是十几 MB，没几张就顶满了，之后就是不停踢旧图、重新解码…**在列表里 72dp 的缩略图，别让接口返回 2K 原图**。"

**我们的核实**：
- 代码：`SourceImage`（source_image.dart:48-56）给 `CachedNetworkImage` 传了
  `cacheManager` / `imageUrl` / `headers` / `fit` / `fadeInDuration` / 占位与失败态，
  **没有 `memCacheWidth` / `memCacheHeight` / `maxWidthDiskCache`**。
- 包能力：本机装的 `cached_network_image-3.4.1` 的 `cached_image_widget.dart:194,200,236,239`
  确实有 `memCacheWidth` / `maxWidthDiskCache` 参数（→ 改动是「加两个具名参数」级别）。
- SDK 默认值：本机 Flutter SDK `packages/flutter/lib/src/painting/image_cache.dart:18-19`
  `const int _kDefaultSize = 1000;` / `const int _kDefaultSizeBytes = 100 << 20; // 100 MiB`。
- 算术（**未实测，仅按公式推算**）：书架格子约 172dp 宽，2x 屏 ≈ 344px。
  原图 800×1200×4 ≈ **3.8 MB/张** → 100 MiB 只装得下 ~27 张；
  解码到 344×460×4 ≈ **0.63 MB/张** → 同预算能装 ~160 张，驱逐/重解码频率降约 6 倍。
- 连带：`ClipRRect` 每张封面一层（manga_cover.dart:85）。官方说裁剪「不是 saveLayer 但也不便宜」，
  建议**保持**（圆角是设计），但可以把 `Clip.antiAlias` 换成按需，避免额外抗锯齿开销。

**候选改法**：`SourceImage` 增加 `cacheWidth`（默认按调用方给的格子宽 × dpr，或退化成 400），
磁盘缓存同步限宽；`main.dart` 里把 `imageCache.maximumSizeBytes` 收到 64 MiB、
`maximumSize` 收到 300–500。

### 3.3 列表结构：eager children 与 shrinkWrap（P1-3 / P1-4 / P2-7 / P2-8）

> 出处：[Flutter 官方 best practices](https://docs.flutter.dev/perf/best-practices)
> 原文（*Pitfalls*）："Avoid using constructors with a concrete `List` of children (such as `Column()` or `ListView()`) **if most of the children are not visible on screen** to avoid the build cost."
> 原文（*Avoid intrinsics*）："For example, consider a large grid of `Card`s… the layout code performs a pass, asking **each** card in the grid (**not just the visible cards**) to return its intrinsic size… and re-visits all grid cells a second time."

> 出处：[技术栈 — Flutter 列表性能优化](https://jishuzhan.net/article/2104488362811600897)
> 原文："`ListView(children: [...])` 会把子项一次性全建出来…高度都一样的话，直接给个 `itemExtent`，滚动时就不用逐个测量每个子项到底多高，**这一步省得最多**。" 另注："`cacheExtent`，现在改叫 `scrollCacheExtent`"、"`itemExtentBuilder`（3.35 引入）"。

**我们的核实**：
- 书架：`library_page.dart:512` 是 `AppScrollView(`（`AppScrollView(children:)` == `ListView(children:)`，
  见 app_scroll_view.dart 头部注释），`:831-833` 的 `FeedView(shrinkWrap: true)` 就嵌在里面。
  `FeedView` 内部是 `CustomScrollView` + `SliverMasonryGrid.count`（masonry_feed.dart:70-77,102-111）。
- 用量：`git grep -c "AppScrollView" lib` 覆盖 24 个页面；其中本地库页
  （local_library_page.dart:179）是 `for` 循环摊开的卡片。
- SDK 事实（本机 3.44.5 源码，不是二手转述）：
  - `scroll_view.dart:119` `'Use scrollCacheExtent instead. '` 出现在 `cacheExtent` 上（已废弃），
    `:123` `this.scrollCacheExtent`，`:369` `final ScrollCacheExtent? scrollCacheExtent;`
  - `scroll_view.dart:1320` `this.itemExtentBuilder`（与 `itemExtent` / `prototypeItem` 互斥断言在 `:1340-1341`）。

**候选改法**：书架改成**单个 `CustomScrollView`**：历史横条 `SliverToBoxAdapter`、
类型筛选 `SliverPersistentHeader`、收藏区直接用 `SliverMasonryGrid`（去掉 `shrinkWrap`）。
本地库页等长列表把 `children:` 换成 `.builder`。固定行高的列表补 `itemExtent`。

### 3.4 逐项入场动画（P1-5）

> 出处：[fluttercook — Fix 2 / The keepAlive question](https://fluttercook.github.io/blog/flutter-lists-performance-builder/)
> 原文："**`RepaintBoundary` on items that animate.** If one row repaints — a progress bar, a shimmer, a like animation — without a boundary it can force the whole list layer to repaint."（反向推论：让**每一项**都animate，等于让整片可见区持续重绘）

> 出处：[技术栈 — Flutter 列表性能优化](https://jishuzhan.net/article/2104488362811600897)
> 原文："`ListView.builder` 默认 `addRepaintBoundaries: true`，也就是每个 item 外层**本来就带了一个 RepaintBoundary**… `RepaintBoundary` 真正该手动加的场景只有一个：**item 内部有一小块区域在持续高频重绘**。"

**我们的核实**：`FadeSlideIn` 是 `StatefulWidget` + `SingleTickerProviderStateMixin`
（animations.dart:95-117），在 6 处被**逐项**使用，其中书架所在的本地库页
（local_library_page.dart:179）与详情页（local_library_detail_page.dart:341）都带 `delayMs: 25*index`。
懒加载下每滚进一项就新建一个 `AnimationController` 播 300ms —— 快滑时是「几十个动画 +
各自重绘」；慢滑/短列表则基本无感。

**候选改法**：只让**首屏**（前 N 项）播入场动画；之后滚进来的项直接静态渲染
（例如 `FadeSlideIn` 加 `onlyFirstScreen` 或由列表传入 `animate: index < 8`）。

## 4. 验证方法（还没做的一步，必须先做）

### 4.1 先定位哪条线程超时（必做）

```powershell
# 真机 + profile 模式（debug 模式的数据没有参考价值：JIT + 断言）
flutter run --profile -d <deviceId>
# 打开 DevTools → Performance；在书架/发现页快速滚动；点开掉帧那一帧看 UI 还是 Raster 超
```

### 4.2 两分钟 A/B：是不是 Impeller

```powershell
flutter run --profile                      # A：引擎默认
flutter run --profile --no-enable-impeller # B：退回 Skia
```

同一页面、同一段滚动距离，对比流畅度：如果 B 明显更顺，那 P0-1（毛玻璃）就是首要
嫌疑（官方 issue 的结论与此一致）；如果 A/B 无差别，转去查 P0-2 与 P1-5。

### 4.3 改完怎么验

- 同一设备、同一段滚动、改前改后各录一次 DevTools 时间线，比较**Raster 平均帧耗时**
  与「>16.7ms 的帧数」（不要凭手感）。
- 图片那条可以直接看 **DevTools → Memory**：解码位图占用应从每张 ~3.8MB 降到 ~0.6MB。

## 6. 实测（本机自动化 harness，2026-10-07）

### 6.1 量法

Windows 桌面构建在这台机器上不可用（VS 缺 "Desktop development with C++" 负载），
所以用 Android 模拟器（`UE_pixel_6_API_36`，API 36）+ 仓库内的自动化 harness：

```powershell
flutter drive --driver=test_driver/integration_test.dart `
  --target=integration_test/scroll_profile_test.dart `
  --profile --no-dds -d emulator-5554 --dart-define=PROFILE_LABEL=<标签>
```

- **必须有 `--no-dds`**：`watchPerformance` 要自己连 VM Service 抓时间线，开了 DDS
  会连到过期地址（报 `Failed to connect to VM Service … try adding --no-dds`）。
- harness 用**真的 `LibraryPage`** + 真的 Scopes，只把数据换成合成的：60 个收藏
  （标题逐项加长，绕开跨源去重 —— `sameCoreKey` 是「等长 + 70% 字符重叠」算同一作品，
  只差一位数字的 60 个标题实测被折成 **2** 张卡）、12 条历史，封面走
  `https://picsum.photos/800/1200?random=<i>&run=<nonce>`（HTTPS —— 本 App 的
  `networkSecurityConfig` 默认禁明文，本机 HTTP 服务喂不了图）。
- 先扫一遍全长列表（9043px）把封面拉到磁盘缓存，再跑测段（手指拖动往复，
  每步一帧）—— 测的是「解码 + 渲染」，不是「下载」。
- **同一跑里带一个对照场景**：400 行纯文字列表。它是这台设备的「光栅地板」。

### 6.2 结果：模拟器（先导）

单位 ms；「超预算帧」是 raster 超过 16.67ms 的帧数（对照列是同一次跑里的地板）。

| 配置 | 书架 raster avg | p90 | 对照（地板） | 说明 |
| --- | --- | --- | --- | --- |
| 原始（baseline 两次） | 40.57 / 57.47 | 51.5 / 82.0 | 14.88 | UI 线程全程 0.8ms、0 帧超预算 → **纯 raster 瓶颈** |
| 关掉顶栏毛玻璃 | 42.90 | 54.6 | — | **无收益**（噪声内） |
| 封面 `memCacheWidth: 400` | 45.50 | 60.3 | — | 帧耗时无收益，但 **ImageCache 在位张数 27 → 60** |
| 临时删掉封面网点画笔 | 19.31 | 30.8 | 15.44 | **2–3 倍**：直指真凶 |
| 正式修法 | **16.67** | 29.2 | 15.28 | 压到地板线 |

同配置复跑漂移 ±20%（38 → 57ms），所以模拟器上只有跨过噪声带的差异能定论。

### 6.3 结果：真机（最终裁判）

同一 harness、同一台手机（`23013RK75C` / `mondrian`，Android 15 / API 35，Adreno GPU，
1440×3200），三次跑各自带同跑对照：

| 配置 | 书架 raster avg | p90 | 超预算帧 | 同跑对照（地板） |
| --- | --- | --- | --- | --- |
| **修复前** | **16.34** | 16.76 | **702 / 811（86.6%）** | 2.48 |
| **修复后** | **3.99** | 5.19 | **0 / 817** | 2.46 |
| 修复后 + 关掉顶栏毛玻璃 | 2.66 | 3.12 | 0 / 819 | 2.66 |

读数：

1. **真凶在真机上更狠**：修复前 p90 恰好 16.76ms —— 那是压着 16.7ms 预算的**恒定
   每帧税**，86.6% 的帧超预算，正是"滑起来一顿一顿"的来源。修复后 0 帧超预算，
   raster 降 **4.1×**；书架只比纯文字列表贵 1.5ms。
2. 对照场景三次跑几乎不动（2.46/2.48/2.66）→ **两跑可比**，A/B 不是靠运气。
3. **毛玻璃值 ~1.33ms/帧**（3.99 → 2.66），是修复后剩余开销里最大的一项，但
   修复后本来就远在预算内（连 120Hz 的 8.3ms 都够）→ **不做**"滚动时降级模糊"
   那套：零手感收益，只损失观感。低端机另说（本机是 Adreno + 1440p）。

### 6.4 真凶：封面占位层每帧都在画

`MangaCover` 原来把「渐变 + **网点** + 首字」的占位层**无脑垫在图片底下**：
`_HalftonePainter` 按 `gap = 7` 在整张卡上逐点 `drawCircle` —— 手机上 2 列的卡片
约 **1050 个绘制调用/张**，12 张可见卡 ≈ **1.2 万次/帧**，而且封面加载完之后这些
点**一个都看不见**（全被图片盖住），纯属白白过绘。

> 出处（为什么这类"看不见的绘制"最贵）：[Flutter 官方 best practices](https://docs.flutter.dev/perf/best-practices)
> 原文："Clipping doesn't call `saveLayer()`… but clipping is still costly"、"Excessive calls to `saveLayer()` can cause jank"——
> 官方那节的落点是"少画看不见的东西"；这条是**我们自己的实测**量出来的，不在任何一篇资料里。

修法（两处，都是"只在需要时画"）：
1. 占位层改成 `SourceImage` 的 `placeholder`/`fallback`，**加载完就从显示列表里消失**；
   没有封面 URL 的条目直接渲染占位层；Base64 封面那条用 `frameBuilder` 判首帧。
2. `_HalftonePainter` 由 N 次 `drawCircle` 改成**一次 `drawPoints`**（点阵样式等价：
   直径 2 + 圆头）。

### 6.5 还没验的

- **观感**：真机数字已经压到「0 帧超预算」，但手感还有一半来自触摸响应/动画曲线，
  这些不在本 harness 的测量范围内 —— 请用户上手确认一次。
- **弱机**：本机是 Adreno + 1440p。低端机上毛玻璃那 1.33ms、以及 `ClipRRect`、
  阴影这类每卡常量开销的相对占比会更大，届时再按 §3 的清单挑着做。
- `memCacheWidth` 只量了驻留（27 → 60），没在真机上复测帧耗时（修复后已无余量需求）。

## 7. 落地顺序建议（已按实测调整）

1. ~~P0-1 毛玻璃~~ → **真机实测 ~1.33ms/帧、修复后仍 0 帧超预算**：不做。真机 GPU 上
   它不是瓶颈，做「滚动时降级模糊」等于用观感换不到手感。
2. ~~P0-2 封面解码尺寸~~ → 帧耗时无收益，但**解码内存与缓存驻留**实打实：27 → 60 张
   常驻。建议作为**内存优化**单独做（`SourceImage` 加可传的 `cacheWidth` + 调整
   `imageCache` 上限），别当成帧率优化卖。
3. **P0-0（新，已修）封面占位层的每帧绘制** —— 真机 raster 16.34 → 3.99ms、
   86.6% 超预算帧 → **0**。改动小、零观感变化，已落到 `MangaCover` / `SourceImage`。
4. P1-5 逐项入场动画 / P1-3 列表结构：真机上 UI 线程只有 0.6ms，**当前都不是瓶颈**；
   收藏涨到几百上千条时再按 §3 做（那时瓶径会从 raster 转到建/排版）。
5. P2 微调（`itemExtent` / `scrollCacheExtent` / 复核 `ClipRRect`）：留给弱机与大数据量。

---

## 附录 A · 检索清单（阶段 1 记录）

### A.1 引擎体检（2026-10-07 实测，`free_search_test`）

| 引擎 | 状态 |
| --- | --- |
| deepseek-official / parallel / keenable / bing / anysearch | ✅ 可用（站内检索用 deepseek-official + parallel：bing/keenable 忽略 `site:`） |
| exa | ❌ HTTP 429（transient） |
| tavily | ❌ `daily_cap_reached`（当日额度耗尽） |
| firecrawl | ❌ HTTP 403（IP 判定可疑，无 key） |
| ddg / ddg-lite / searxng | ❌ connection error / all instances aborted |
| baidu / kimi / doubao / aliyun / perplexity / you / serpbase / serply | ❌ 未配置 key |

### A.2 检索角度与命中

| 角度 | 查询 | 主要命中 |
| --- | --- | --- |
| 站内中文实践 | `site:zhihu.com Flutter 列表滑动卡顿 性能优化`（deepseek-official+parallel+anysearch） | 携程酒店实践、RepaintBoundary、ListView 流畅度翻倍、隐藏的 Flutter 模式 等 8 篇 |
| 站内第二角度 | `site:zhihu.com Flutter 掉帧 卡顿 排查 优化 实践` | DevTools Performance 面板实战、树莓派优化、新手避坑 |
| 英文机制 | `Flutter scroll jank performance optimization best practices raster thread` | 官方 best-practices、华为「页面滑动卡顿」、redjadet/flutter_bloc_app 的 finding_jank_cause |
| 官方一手 | `Flutter performance best practices official docs` | docs.flutter.dev/perf/{best-practices,rendering-performance,metrics,shader}、flutter/website 源码 |
| 图片解码 | `Flutter 图片解码 cacheWidth ImageCache 列表滚动卡顿 优化` | 鸿蒙 cacheWidth+precacheImage、juejin 列表图片内存优化、flutter/flutter#48536 "Defer image decoding when scrolling fast" |
| 反例/踩坑 | `Flutter 瀑布流 网格 滚动 卡顿 优化 RepaintBoundary 无效 反而更卡` | 技术栈《Flutter 列表性能优化》、腾讯云桌面端卡顿排查、flutter/flutter#191249 |
| 渲染器 | `Flutter Impeller BackdropFilter performance cost scrolling jank blur` | flutter#191207 / #126353 / #161297 / #168788 |
| 同类仓库 | GitHub API `flutter performance/jank/listview performance in:name,description` | bamlab/flashlight（性能审计）、littleGnAl/glance（jank 监测）、lesnitsky/fps_jank_flash_widget、yrom/flutter_method_channel_ex |

### A.3 读到全文的来源（阶段 2）

1. [Flutter 官方 Performance best practices](https://docs.flutter.dev/perf/best-practices)（`.md` 直取，全文）
2. [技术栈 · Flutter 列表性能优化](https://jishuzhan.net/article/2104488362811600897)（2026-09-28，全文）
3. [FlutterCook · Why your ListView is slow, and the four fixes that actually work](https://fluttercook.github.io/blog/flutter-lists-performance-builder/)（2026-08-28，全文）
4. flutter/flutter issue [#191207](https://github.com/flutter/flutter/issues/191207)、[#168788](https://github.com/flutter/flutter/issues/168788)、[#126353](https://github.com/flutter/flutter/issues/126353)（GitHub API 取正文）

### A.4 空白项 / 未采用

- **知乎正文没拿到**：`zhuanlan.zhihu.com/p/1983340701744919762`（RepaintBoundary 那篇）走
  `/tardis/zm/art/` 返回 HTTP 200 但正文是 858–1165 字节的「荒原」空壳页 ——
  该文未被分发给外部搜索引擎，按技能约定**不再换渠道号重试**，改用可直抓的
  jishuzhan / fluttercook / 官方文档覆盖同一结论。
- 携程酒店实践（`zhuanlan.zhihu.com/p/580914068`）同理未取到全文，其结论（图片尺寸、
  列表复用、首屏渲染）已由上表第 2、3 篇覆盖。
- 未找到「Flutter 桌面 Windows 滚动卡顿」的**一手**官方文档：只有 issue #191207 这一份
  带复现步骤的官方 tracker 记录，故 §3.1 的 Windows 结论标注为该 issue 的范围。
