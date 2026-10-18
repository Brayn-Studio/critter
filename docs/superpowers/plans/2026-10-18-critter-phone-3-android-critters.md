# Critter 手机端 · 计划 3：安卓上的小人 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把桌面版的形象和动画引擎搬到安卓上，在此基础上做三样东西：
- 横屏看板的 Critter 模式；
- 悬浮球，平时收起贴边，点一下竖排展开；
- 充电并且横放时自动打开看板。

另外补上首次引导、各家国产系统的保活引导，以及"发一句"。

**Architecture:**
- **`:core` 逐行移植 CritterCore 的纯逻辑**：形象模型和校验、渲染网格、`Motion/` 目录、`TickGrid`、`FlockModel`。Swift 代码就是参照实现，Swift 的测试就是验收标准。另外加一组"金样"：由 Swift 导出每一拍的 `ActorSnapshot`，Kotlin 逐拍比较。
- **`:app` 新写的部分**：Canvas 渲染器 `CritterView`（对应 `CritterSpriteLayer`、`SpriteAtlas`、`MotionClock`），悬浮窗控制器，看板触发器。
- **看板触发的判断是纯逻辑**，放在 `:core` 的 `BoardTrigger` 状态机里，用单元测试覆盖。

**Tech Stack:** 同计划 2，不新增依赖。

**Spec:** `docs/superpowers/specs/2026-10-18-critter-android-design.md`，重点是 §8.2、§8.4、§8.6、§8.7、§8.8、§9。

**前提**：计划 1 和计划 2 都已完成。

## Global Constraints

- 计划 2 的 Global Constraints 全部继续有效，包括包名、依赖范围、省电规则和文案。
- 内置形象只有一份源文件：构建时从仓库根目录的 `Skins/*/manifest.json` 复制进 assets，声音从 `Sounds/` 复制，不在 `android/` 下另存一份（spec §8.1）。
- 移植必须忠于原实现：常量、随机数序列（SplitMix64）、`jsRound` 的取整方式、逐拍行为都要和 Swift 一致。拿不准时以 Swift 源码为准，不能自己发明（spec §8.2）。
- 一拍固定 60 ms（`manifest.tickMs`）。时钟只在 `ticksUntilChange` 那一刻醒来；看不见时停下；没有变化时不重画（spec §8.2、§9）。
- 画图用最近邻缩放（`Paint.isFilterBitmap = false`）。不能每帧分配位图，位图要按形象、缩放倍数和色调缓存。
- 触摸阈值：拖动超过 3 dp 算拎起来；来回蹭的判断沿用 `RubDetector` 的参数，长度单位从 pt 换成 dp（spec §8.2）。
- 悬浮窗：
  - 类型 `TYPE_APPLICATION_OVERLAY`，大小 `WRAP_CONTENT`；
  - 标志 `FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL | FLAG_WATCH_OUTSIDE_TOUCH | FLAG_LAYOUT_NO_LIMITS`；
  - 不做全屏的透明窗口（spec §4.3）。
- 看板自动打开：充电、横放、静止，三者同时持续 3 秒才打开；拔电 10 秒后退出；竖起来 3 秒后退出；本次充电期间手动退出过就不再自动打开，直到下次插电；重力传感器只在充电时注册，用 `SENSOR_DELAY_NORMAL`，并设置批量上报（spec §8.6）。
- 系统"移除动画"打开时（动画时长缩放为 0），等同于桌面的"减少动态效果"（spec §8.2）。

## Review Focus

1. **Kotlin 的 `Double` 取整、`Long` 运算、随机数和 Swift 不一致**，导致第几百拍开始偏离。由 Task 3 的金样测试逐拍覆盖，至少要覆盖 2000 拍（让"睡着"发生）。
2. **悬浮球拖到屏幕边缘以外，或者手机旋转、分屏后悬浮球跑到屏幕外。** 每次布局变化都要把位置夹回屏幕内，然后再吸边。由 Task 6 的 `OverlayGeometry` 单元测试 `clampsAfterRotation` 覆盖。
3. **插着电的时候手机在桌上转来转去**，比如拿起来看一眼再放下。不能反复弹出、关闭看板。由 Task 8 的 `BoardTrigger` 测试 `brieflyPortraitDoesNotExit` 和 `manualExitSuppressesUntilReplug` 覆盖。
4. **会话数量从 0 变到 12。** 悬浮球收起状态的显示要正确，展开后可以滚动；看板 Critter 模式要缩小，或者把空闲的合并成一堆，不能有小人跑到屏幕外。由 Task 5 的 `BoardLayout` 和 Task 6 的 `OverlayGeometry` 测试覆盖。
5. **自定义皮肤的 manifest 坏了，或者 Mac 推来一个手机上没有的形象名。** 要退回 Clawd，不能崩。由 Task 1 的 `unknownOrInvalidSkinFallsBackToClawd` 覆盖。

---

## 文件结构

```
android/core/src/main/kotlin/local/critter/core/
  skin/Skin.kt              ← Sources/CritterCore/Skin.swift（模型、SkinValidator、SkinLoader；不含内嵌的 JSON）
  skin/SkinRenderer.kt      ← SkinRenderer.swift 里的 grid(pose:) 和 dim 色调公式
  skin/SkinLibrary.kt       按名字找形象：内置的在 assets，自定义的由 Mac 推送；找不到就用 clawd
  motion/MotionMath.kt      ← Motion/MotionMath.swift（jsRound、MotionRNG）
  motion/TickGrid.kt        ← TickGrid.swift
  motion/Particle.kt        ← Motion/Particle.swift
  motion/ActorSnapshot.kt   ← Motion/ActorSnapshot.swift（另外加 JSON 序列化，金样测试用）
  motion/MotionActor.kt     ← Motion/MotionActor.swift
  motion/MotionActorState.kt        ← MotionActor+State.swift
  motion/MotionActorInteraction.kt  ← MotionActor+Interaction.swift
  motion/MotionGaze.kt      ← Motion/MotionGaze.swift
  motion/MotionTravel.kt    ← Motion/MotionTravel.swift
  flock/FlockModel.kt       ← FlockModel.swift
  board/BoardTrigger.kt     看板自动打开、退出的状态机
  board/BoardLayout.kt      Critter 模式下每只的位置和缩放
  overlay/OverlayGeometry.kt  悬浮球的位置夹取、吸边、展开后的尺寸
android/core/src/test/kotlin/…   移植过来的测试，加上金样比对测试
android/core/src/test/resources/golden/*.json   Swift 导出的金样
Tests/CritterCoreTests/GoldenExportTests.swift   Swift 端导出金样（加环境变量才写文件）
android/app/src/main/kotlin/local/critter/phone/
  critter/SpriteAtlas.kt    位图缓存
  critter/CritterRenderer.kt  ← CritterSpriteLayer 的绘制规则
  critter/CritterClock.kt   ← MotionClock 和 TickGrid 的调度
  critter/CritterView.kt    一只或多只小人的 View，处理触摸交互
  overlay/OverlayController.kt   悬浮窗的增删和尺寸
  overlay/PileView.kt  overlay/ColumnView.kt
  board/CritterBoard.kt     看板的 Critter 模式
  board/BoardTriggerService.kt   在 BridgeService 里注册充电和传感器监听
  onboarding/*.kt           首次引导和各厂商的保活引导
  ui/detail/DetailActivity.kt    会话详情和"发一句"
```

---

### Task 1: 形象模型、校验、渲染网格，以及 assets 复制

**Files:**
- Create: `core/.../skin/Skin.kt`、`SkinRenderer.kt`、`SkinLibrary.kt`
- Modify: `app/build.gradle.kts`：注册一个复制任务，把 `../../Skins` 复制到生成的 assets 目录 `skins/<名字>/manifest.json`，把 `../../Sounds` 复制到 `sounds/`；用 `androidComponents.onVariants` 加入 `sources.assets`
- Test: `core/.../skin/SkinTest.kt`：逐条移植 `Tests/CritterCoreTests/SkinTests.swift` 里的 39 个测试，测试名保持一致，改成 camelCase

**Interfaces:**
- Produces（Kotlin 的命名照搬 Swift，只是驼峰化）：
  - `@Serializable data class SkinManifest(...)`，字段和 `Skin.swift` 里的 `SkinManifest` 一一对应；
  - `object SkinValidator { fun validate(m: SkinManifest): List<String> }`：返回错误列表，规则和 Swift 一致，包括 `schema == 2`、`tickMs` 在 16…1000 之间、`grid == [18,10]`；
  - `object SkinLoader { fun decode(json: String): SkinManifest? }`：校验不通过时返回 null；
  - `object SkinRenderer { fun grid(manifest: SkinManifest, pose: String): PixelGrid; fun dim(color: Int, strength: Double): Int }`：色调公式是混灰比例 `0.5·s`、不透明度 `1−0.15·s`；
  - `class SkinLibrary(assetReader: (String) -> String?, pushed: Map<String, String>)`，方法 `fun manifest(name: String): SkinManifest`：找不到或不合法时返回 clawd。

- [ ] **Step 1: 移植测试**，再加上 `unknownOrInvalidSkinFallsBackToClawd` 和 `bundledSkinsAllValidate`（逐个解码 `Skins/*/manifest.json`，测试资源目录直接指向仓库根目录的 `Skins`）。
- [ ] **Step 2: 运行，确认测试失败**

Run: `cd android && ./gradlew :core:test --tests '*SkinTest*'`
Expected: 编译失败。

- [ ] **Step 3: 实现，并加上 assets 复制任务**
- [ ] **Step 4: 运行，确认测试通过**

Run: `cd android && ./gradlew :core:test && ./gradlew :app:assembleDebug && unzip -l app/build/outputs/apk/debug/app-debug.apk | grep -c 'assets/skins/.*/manifest.json'`
Expected: 测试全部通过；grep 计数为 5。

- [ ] **Step 5: 提交**

```bash
git add android
git commit -m "feat(android): port the skin model, validator and renderer"
```

---

### Task 2: 移植动画引擎

**Files:**
- Create: `core/.../motion/*.kt`（见文件结构）、`core/.../flock/FlockModel.kt`
- Test: 逐条移植以下 Swift 测试，测试名保持一致：
  - `TickGridTests.swift`：5 个；
  - `ParticleTests.swift`：9 个；
  - `MotionPlaybackTests.swift`：14 个；
  - `MotionStateTests.swift`：26 个；
  - `MotionInteractionTests.swift`：38 个；
  - `FlockModelTests.swift`：全部。

**Interfaces:**
- Produces（命名照搬 Swift，Kotlin 化）：
  - `class MotionActor(manifest: SkinManifest, rng: MotionRNG, reducedMotion: Boolean)`，主要方法有：
    - `enterState(state, activity, now)`、`step()`、`snapshot(): ActorSnapshot`、`ticksUntilChange(): Int`；
    - `wake()`、`play(clip)`、`setMode(clip)`、`cancelOnce()`；
    - 与交互相关的 `lift`、`lag`、`gaze` 等属性。
    - 各方法的签名都以 Swift 源码为准。
  - `data class ActorSnapshot(...)`：字段和 Swift 的 `ActorSnapshot` 一一对应（`hidden`、`pose`、`bodyX`、`bodyY`、`offsetX`、`offsetY`、`tint`、`alpha`、`z`、`shadowWidth`、`accessory`、`badge`、`particles`、`props`），并且可以序列化。
  - `class TickGrid(tickMs: Long)`：`due(afterTicks)`、`take(now)`，规则和 Swift 一致，包括最多 1000 拍的上限和 2 ms 的宽限。
  - `object FlockModel`：合并还是展开的判断。
- 移植时只把 `CGPoint` / `CGFloat` 换成 `data class Pt(val x: Double, val y: Double)`，其它逻辑不改。

- [ ] **Step 1: 移植测试**
- [ ] **Step 2: 运行，确认测试失败**

Run: `cd android && ./gradlew :core:test`
Expected: 编译失败。

- [ ] **Step 3: 逐文件移植实现**
- [ ] **Step 4: 运行，确认测试通过**

Run: `cd android && ./gradlew :core:test`
Expected: 移植过来的测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add android/core
git commit -m "feat(android): port the motion engine"
```

---

### Task 3: 金样比对（Swift 导出、Kotlin 逐拍比较）

**Files:**
- Create: `Tests/CritterCoreTests/GoldenExportTests.swift`
- Create: `android/core/src/test/resources/golden/*.json`，由 Swift 生成后提交
- Test: `android/core/.../motion/GoldenTest.kt`

**Interfaces:**
- 金样场景（每个都是固定种子，一个场景一个 JSON 文件）：
  1. `clawd-idle-2400`：空闲 2400 拍，覆盖小动作、打瞌睡、睡着；
  2. `clawd-states`：空闲 → 运行中（laptop）→ 运行中（read）→ 等你确认 → 做完了 → 出错，每个状态 300 拍；
  3. `sprig-running-variants`：运行中，activity 按 think、bash、juggle 依次切换，每种 200 拍；
  4. `mochi-interactions`：依次 notice、press、boop、拎起来并带 lag、放下、摸摸开始和结束，每步之间 40 拍；
  5. `peep-reduced-motion`：减少动态效果打开时，跑一遍状态序列。
- JSON 格式是 `{"skin": …, "seed": …, "ops": [{"at": 拍, "op": "enterState", …}], "frames": [{"tick": n, "snapshot": {…}, "ticksUntilChange": k}]}`。只记录快照或 `ticksUntilChange` 与前一拍不同的那些拍。
- Swift 端只在设置了环境变量 `CRITTER_EXPORT_GOLDEN=<目录>` 时写文件；不设置时，这个测试只校验场景能跑完。
- Kotlin 端读进 ops，用同样的种子重放，在每个记录的拍上做断言，快照和 `ticksUntilChange` 都要逐字段相等。

- [ ] **Step 1: 写 Swift 导出测试，生成金样**

Run: `CRITTER_EXPORT_GOLDEN=$PWD/android/core/src/test/resources/golden swift test --filter GoldenExportTests`
Expected: 生成 5 个 JSON 文件，每个 50–500 KB。

- [ ] **Step 2: 写 Kotlin 的 `GoldenTest`，运行**

Run: `cd android && ./gradlew :core:test --tests '*GoldenTest*'`
Expected: 5 个场景全部逐拍一致。如果不一致，失败信息里要指出第一处不同的拍号和字段，然后修 Task 2 的移植，不改金样。

- [ ] **Step 3: 提交**

```bash
git add Tests/CritterCoreTests/GoldenExportTests.swift android/core
git commit -m "test(android): golden snapshots shared with the Swift engine"
```

---

### Task 4: `CritterView` 的渲染、时钟和触摸交互

**Files:**
- Create: `app/.../critter/SpriteAtlas.kt`、`CritterRenderer.kt`、`CritterClock.kt`、`CritterView.kt`
- Create（只在 debug 构建里）: `app/src/debug/.../SkinGalleryActivity.kt`：把五个形象分别放到五种状态下，用来人工核对

**Interfaces:**
- Consumes: Task 1–2 的内容。
- Produces:
  - `class CritterView(context: Context) : View`：
    - `fun setActors(list: List<CritterSlot>)`，其中 `data class CritterSlot(val sessionId: String, val manifest: SkinManifest, val state: PetState, val activity: String?, val dimStrength: Double, val x: Float, val y: Float, val scale: Float)`；
    - `var listener: CritterTouchListener?`，接口里有 `onTap(sessionId)` 和 `onLongDragEnd(sessionId)`；
    - `var debugFrameCount: Int`，只读，调试用。
  - `CritterRenderer`：绘制规则照搬 `Sources/CritterApp/CritterSpriteLayer.swift`：
    - 身体在地面处裁切；
    - 影子不透明度 0.28，`x = bodyX + 9 − w/2`；
    - 绘制顺序：道具、粒子、头顶标记、角标；
    - 纵坐标翻转：`groundRow(10) − y − h`；
    - 快照和上一次相同时不重画。
  - `CritterClock`：
    - 用 `Choreographer.postFrameCallbackDelayed` 或 `Handler.postDelayed`，在 `TickGrid.due(ticksUntilChange)` 那一刻醒来；
    - View 收到 `onDetachedFromWindow`，或者 `onVisibilityAggregated(false)` 时停止；
    - 处理触摸前先 `catchUp`。
  - 触摸交互（spec §8.2）：
    - 按下：`wake()`，然后 `cancelOnce()`，再 `setMode(interactions.press)`；
    - 移动超过 3 dp：拎起来，`setMode(held)`，`lift = 3`，`lag = MotionDrag.lag(dx)`；
    - 松手：如果拎起来过，就 `play(drop)`；否则 `play(boopEnd)`，并回调 `onTap`；
    - `RubDetector` 判定为摸摸时 `setMode(pet)`；停手 0.7 秒后 `play(petEnd)`；
    - 手指在屏幕上时，目光跟着手指走（`GazeZone`）。
  - 自定义皮肤：`BridgeRepository` 新增 `suspend fun skinManifest(name: String): String?`。
    - assets 里没有这个名字时，发 `SkinRequest` 向 Mac 要 manifest，结果在内存里缓存，同时写进应用私有目录 `skins/<名字>.json`；
    - `SkinLibrary` 的 `pushed` 参数就来自这里。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 真机验证**

Run: `adb shell am start -n local.critter.phone/.SkinGalleryActivity`，然后 `adb exec-out screencap -p > /tmp/critter-gallery.png`；静置 60 秒后读一次 `debugFrameCount`，可以通过 logcat 打印。

Expected：
- 截图里的 25 只小人和桌面上的样子一致，可以拿 `docs/superpowers/specs/2026-10-17-sprig-motion-preview.html` 对照；
- 只放一只空闲并且已经睡着的小人时，60 秒内 `debugFrameCount` 的增量应该远小于 1000（每 60 ms 画一次时，60 秒是 1000 帧）。把实际数字写进报告。

- [ ] **Step 3: 提交**

```bash
git add android/app
git commit -m "feat(android): critter view with the desktop's drawing rules and touch interactions"
```

---

### Task 5: 看板的 Critter 模式

**Files:**
- Create: `core/.../board/BoardLayout.kt`，测试 `BoardLayoutTest.kt`
- Create: `app/.../board/CritterBoard.kt`
- Modify: `app/.../ui/board/BoardActivity.kt`：增加两种模式的切换，右上角放一个切换按钮，左右滑动也能切换；记住上次选的模式

**Interfaces:**
- Produces:
  - `object BoardLayout`，方法 `fun place(count: Int, widthDp: Float, heightDp: Float): Layout`，其中 `data class Layout(val scale: Float, val slots: List<Pt>, val pileFrom: Int?)`：
    - 一排最多放 6 只，缩放倍数范围是 5 到 3；
    - 超过 6 只时，第 6 个位置放一堆，`pileFrom` 等于 5，从第 5 个会话往后的空闲会话都合并进这一堆。
- 画面按草图 board-modes 里的 Critter 模式：
  - 每只小人：头顶是气泡和状态标记；脚下是名字和"分支 · 来源"；再下面一条细线表示上下文用量。
  - 左上角是时钟，每分钟刷新一次；右上角是 5 小时和 7 天额度的小进度条。
- 点击：
  - 有待答请求的那只：打开 `AnswerActivity`；
  - "做完了"的那只：调用 `repository.seen`；
  - 其它：打开 `DetailActivity`（Task 7）。
- 防烧屏挪动和亮度沿用计划 2 的 `BoardChrome`。
- 看板提示音（spec §8.7）：
  - 设置项"看板提示音"，默认关；
  - 用 `SoundPool` 播放 assets 里 `sounds/<套名>/{waiting,done,error}.wav`；套名取快照里的 `prefs.soundTheme`，取值是 `system` 或者 assets 里没有这一套时，改用 `voice`；
  - 只在看板显示时、并且有会话**刚进入**这三种状态时播放；同一份快照只播最急的那个，第一份快照不播，规则和桌面的 `SoundTrigger.enteredAlertStates` 一样；
  - 勿扰模式下不播。

- [ ] **Step 1: 写 `BoardLayoutTest`**：0、1、6、7、12 只这几种情况都不越界；`pileFrom` 的取值正确。
- [ ] **Step 2: 运行，确认测试失败；实现；再运行，确认测试通过**

Run: `cd android && ./gradlew :core:test --tests '*BoardLayoutTest*'`
Expected: 先失败，实现后通过。

- [ ] **Step 3: 真机验证**：打开看板切到 Critter 模式，截图对照草图；摸一摸、拎一拎小人。
- [ ] **Step 4: 提交**

```bash
git add android
git commit -m "feat(android): critter board mode"
```

---

### Task 6: 悬浮球

**Files:**
- Create: `core/.../overlay/OverlayGeometry.kt`，测试 `OverlayGeometryTest.kt`
- Create: `app/.../overlay/OverlayController.kt`、`PileView.kt`、`ColumnView.kt`
- Modify:
  - `BridgeService`：持有 `OverlayController`；
  - `Alerts`：只在悬浮球看不见时才发通知（spec §8.7）；
  - 设置页：新增悬浮球一组，含开关、大小、空闲淡化（默认跟着电脑）、没有会话时自动隐藏、全屏应用里隐藏。

**Interfaces:**
- Produces:
  - `object OverlayGeometry`：
    - `fun snap(x: Int, y: Int, w: Int, h: Int, screen: Rect): Placement`，其中 `Placement(edge: Edge, y: Int)`：先把位置夹回屏幕内，再吸附到最近的左边或右边；
    - `fun expandedSize(count: Int, screen: Rect, itemHeight: Int): Size`：最多占屏幕高度的 70%，超出时可以滚动。
  - "全屏应用里隐藏"的检测方法：悬浮窗根视图监听 `WindowInsets`，`statusBars()` 的高度变成 0 时（前台 App 进入了沉浸式），就隐藏悬浮球，状态栏回来后再显示。只在这个设置打开时才这样做。
  - `OverlayController`：
    - 方法：`show()`、`hide()`、`render(body: SnapshotBody)`、`expand()`、`collapse()`、`isVisible`；
    - 窗口参数见 Global Constraints；
    - 收起和展开用的是同一个窗口，只调 `updateViewLayout` 改尺寸；
    - 位置记在 `SettingsStore` 里。
  - `PileView`：
    - 最急的那只站在最前面，后排最多两只，变暗（不透明度 0.55 和 0.75，同桌面）；
    - 上方是状态数量（`?n`、`✓n`、`!n`），下方标签写"N 个会话"；
    - 只有一个会话时就显示那一只；
    - 离线时是一只灰色睡着的小人，标签写"离线"。
  - `ColumnView`：
    - 沿吸附的那条边竖排，每项依次是气泡（朝屏幕内侧）、小人、标签（名字 · 来源）；
    - 末尾是"收起"把手。
  - 点击：同 Task 5 的规则。点窗口外面（`ACTION_OUTSIDE`）就收起。
  - 有会话刚变成"等你确认"时，收起状态下最前面那只会蹦一下，播放 interactions 里的 notice 动作。
- 悬浮窗权限：没有 `Settings.canDrawOverlays` 时，悬浮球不启动，设置里显示"去授权"，跳转到 `ACTION_MANAGE_OVERLAY_PERMISSION`。

- [ ] **Step 1: 写 `OverlayGeometryTest`**，覆盖：吸边、超出屏幕时夹回来、旋转后夹回来、12 个会话展开时的高度上限。
- [ ] **Step 2: 运行，确认测试失败；实现；再运行，确认测试通过**

Run: `cd android && ./gradlew :core:test --tests '*OverlayGeometryTest*'`
Expected: 先失败，实现后通过。

- [ ] **Step 3: 真机验证**：在别的 App 上面拖动悬浮球、吸边、展开、收起，点外面收起；来一个权限请求时，那只会蹦出来，并且不发通知。每个状态截一张图。
- [ ] **Step 4: 提交**

```bash
git add android
git commit -m "feat(android): floating critter pile that expands along the screen edge"
```

---

### Task 7: 会话详情和"发一句"

**Files:**
- Create: `app/.../ui/detail/DetailActivity.kt`：半透明底部弹层，样式同 `AnswerActivity`

**Interfaces:**
- Consumes: `BridgeRepository.say`。
- 内容：
  - 状态和正在做什么、目录、分支、模型、上下文（估算值前面加 "≈"）、最后更新时间；
  - 输入框"发一句"，最多 4000 字；下面一行说明："Claude 会把这句话当成另一个会话发来的消息，它不能用来批准任何东西"（spec §6.4）；
  - 发送后：成功提示"已发送"；回执是 `unavailable` 时提示"这个会话收不到消息（可能是启动得太早，重启会话后可用）"；`failed` 时提示失败原因。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 真机验证**：给一个空闲的 haiku 会话发"只回复 PINEAPPLE"，终端里出现 PINEAPPLE。
- [ ] **Step 3: 提交**

```bash
git add android/app
git commit -m "feat(android): session details and sending a message"
```

---

### Task 8: 看板自动打开和退出

**Files:**
- Create: `core/.../board/BoardTrigger.kt`，测试 `BoardTriggerTest.kt`
- Create: `app/.../board/BoardTriggerService.kt`（由 `BridgeService` 持有）
- Modify: `BoardActivity`：
  - 加上 `setShowWhenLocked(true)` 和 `setTurnScreenOn(true)`；
  - 手动退出时通知 `BoardTrigger`；
  - 在锁屏上作答前先 `requestDismissKeyguard`（AnswerActivity 已经做了，这里确认一下）。

**Interfaces:**
- Produces:

```kotlin
class BoardTrigger(private val holdMs: Long = 3_000, private val unplugExitMs: Long = 10_000, private val portraitExitMs: Long = 3_000) {
    sealed interface Action { data object Open : Action; data object Close : Action; data object None : Action }
    fun onPower(charging: Boolean, nowMs: Long): Action
    fun onOrientation(landscape: Boolean, still: Boolean, nowMs: Long): Action
    fun onTick(nowMs: Long): Action          // 调用方在下一个到期时刻调用
    fun onManualExit(nowMs: Long)
    fun onBoardShown(shown: Boolean)
    fun nextDeadline(): Long?                // 调用方据此安排下一次 onTick
    val sensorWanted: Boolean                // 只有充电时为 true
}
```

- 横放的判断：重力向量 `|gx| > 7 m/s²`，并且 `|gz| < 6 m/s²`（横立着），或者手机平放时 `|gz| > 9`，**手机平放不算横放**。
- 静止的判断：最近 1.5 秒内，各轴变化都小于 0.5。

**测试**：

```kotlin
@Test fun opensAfterHoldWhileChargingAndLandscape()
@Test fun doesNotOpenWhenNotCharging()
@Test fun brieflyPortraitDoesNotExit()         // 竖起来 2 秒又放回横屏 → 不退出
@Test fun portraitForThreeSecondsExits()
@Test fun unplugExitsAfterTenSeconds()
@Test fun replugWithinTenSecondsKeepsBoard()
@Test fun manualExitSuppressesUntilReplug()
@Test fun sensorWantedOnlyWhileCharging()
```

- [ ] **Step 1: 写测试，运行，确认失败**

Run: `cd android && ./gradlew :core:test --tests '*BoardTriggerTest*'`
Expected: 编译失败。

- [ ] **Step 2: 实现 `BoardTrigger`，运行，确认测试通过**
- [ ] **Step 3: 实现 `BoardTriggerService`**：
  - 动态注册 `ACTION_POWER_CONNECTED` 和 `ACTION_POWER_DISCONNECTED`，初始状态从 `ACTION_BATTERY_CHANGED` 读；
  - `sensorWanted` 为真时注册 `TYPE_GRAVITY`，没有这个传感器就用加速度计；参数是 `SENSOR_DELAY_NORMAL`，`maxReportLatencyUs = 500_000`；
  - 动作是 Open 时，执行 `startActivity(Intent(BoardActivity).addFlags(FLAG_ACTIVITY_NEW_TASK))`；动作是 Close 时，发一个本地广播，让 BoardActivity 自己 `finish()`。
- [ ] **Step 4: 真机验证**（vivo）：
  1. 插电，横着立起来，3 秒后看板出现；
  2. 拔电，10 秒后看板退出；
  3. 手动退出后，在这次插电期间不再自动出现；
  4. 关掉 vivo 的"后台弹出界面"开关，再试一次，记下现象（写进 Task 9 的引导）。
- [ ] **Step 5: 提交**

```bash
git add android
git commit -m "feat(android): open the board while charging in landscape"
```

---

### Task 9: 首次引导、厂商保活引导、减少动态效果，以及 README

**Files:**
- Create: `app/.../onboarding/OnboardingActivity.kt`、`OemGuide.kt`
- Modify: `MainActivity`：第一次启动时进入引导；`SettingsScreen`：新增"保持后台运行"入口和"减少动态效果"开关（默认跟随系统）；`README.md`

**Interfaces:**
- 引导依次是（spec §8.8）：
  1. 配对；
  2. 本地网络（API 37 及以上）；
  3. 通知；
  4. 悬浮窗；
  5. 忽略电池优化；
  6. 保持后台运行。

  每一步都可以跳过，跳过时用一句话说明影响。
- `OemGuide`：按 `Build.MANUFACTURER`（转小写）给出步骤文字和可以尝试跳转的 Intent。跳转失败时退回系统的应用详情页 `ACTION_APPLICATION_DETAILS_SETTINGS`。
  - **vivo**：
    - 自启动（`com.vivo.permissionmanager/.activity.BgStartUpManagerActivity`）；
    - 允许后台高耗电；
    - 后台弹出界面；
    - 在最近任务里锁定。
  - **xiaomi / redmi**：
    - 自启动（`com.miui.securitycenter/com.miui.permcenter.autostart.AutoStartManagementActivity`）；
    - 省电策略设为"无限制"；
    - 后台弹出界面；
    - 锁定最近任务。
  - **oppo / oneplus / realme**：自启动、允许后台运行、关闭电池优化、锁定最近任务、悬浮窗。
  - **huawei / honor**：电池 → 应用启动管理，改为手动管理，三个开关全部打开。
  - **samsung**：电池设为"不受限制"，加入"永不休眠的应用"。
  - **其它品牌**：只引导关闭电池优化。
- 减少动态效果：`Settings.Global.ANIMATOR_DURATION_SCALE == 0f`，或者设置里手动打开时，把 `MotionActor` 的 `reducedMotion` 设为 true（spec §8.2）。
- 形象设置（spec §8.8）：
  - "跟着电脑"（默认）：每个会话用快照里 `skin` 给的形象；
  - "手机上单独选"：从五个内置形象里选一个，所有会话都用它。
  - 设置页里每个选项带一个 `CritterView` 小预览。
- README 补充：
  - 悬浮球、看板自动打开、引导各步的用途；
  - vivo 实测需要打开的开关（来自 Task 8 和计划 2 Task 9 的结论）；
  - 已知限制。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 真机走查**：先 `adb shell pm clear local.critter.phone` 清空数据，从第一次启动开始把引导走完；vivo 的自启动页能跳转过去；打开系统的"移除动画"后，小人停在代表姿势上。
- [ ] **Step 3: 提交**

```bash
git add android README.md
git commit -m "feat(android): onboarding, OEM keep-alive guide and reduced motion"
```
