# Critter 手机端 · 计划 4：视觉重做 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把手机 App 的整套界面换成和宠物同一种像素材质：首页草地、像素部件、宠物回到每个画面、统一的动效节拍，并做掉台账里跟画面有关的条目（应用图标、看板时藏起悬浮球、看板里拖宠物走回原位等）。

**Architecture:**
- **纯逻辑放在能跑 JVM 单测的地方**：像素轮廓、像素图标行数据、分格条、天空分档和草地格子、Logo 格子放在 `:app` 的 `ui/look/`（不碰 Android API）；动作片段（抬头看你、跳一下）、拖动后走回原位、草地的一排站位、配对失败分类、看板被拦放在 `:core`。
- **Compose 部件**放在 `ui/theme/`，所有画面只用这些部件和 `CritterColors` 取色；悬浮球是 View，用同一份轮廓数据画的 `PixelDrawable`。
- **宠物**：会动的仍然只用 `CritterView`；列表、专业看板、通知里的静止小头像用减少动态效果模式下的 `MotionActor` 快照加现有 `CritterRenderer` 画成位图并缓存。

**Tech Stack:** 同计划 2、3，不新增库依赖。新增资源：字体 Nunito（可变字重）、Silkscreen（Regular、Bold），OFL 许可。启动画面用系统自带的 SplashScreen 主题属性（`values-v31`），不引入 `core-splashscreen`。

**Spec:** `docs/superpowers/specs/2026-10-19-critter-phone-visual-design.md`（以下简称“设计”）。画面以草图 `docs/superpowers/specs/2026-10-19-critter-phone-visual-mockups.html` 为准；草图和设计文字不一致时（文案、码长、拖动细节）以设计文字为准。

**前提**：计划 1–3 已完成；`docs/critter-phone-backlog.md` 第三部分里不涉及画面的条目不在本计划，另见计划 5。

## Global Constraints

- 原设计（`2026-10-18-critter-android-design.md`）§9 的省电要求全部有效。另外：**不用 `rememberInfiniteTransition` 或任何无限循环的界面动画**；界面动画都有头有尾；持续在动的只有 `CritterView`；列表、专业看板、通知里的宠物是静止位图。
- 颜色只从 `CritterColors`（浅、深两套）和 `BoardColors` 取，画面里不写颜色字面量。数值照抄设计 §5。
- 像素必须落在整像素上：宠物、图标、轮廓台阶的每格都是 `round(dp × density)` 个整像素，最小 1。
- 字体：正文 Nunito；数字（时钟、百分比、数量、配对码）用 Silkscreen，“%” 用 Nunito；命令和路径用 `FontFamily.Monospace`；中文回落系统字体。
- 小部件按 60 ms 一格走：开关圆头 `tween(180, easing = steps(3))`，按钮按下 / 松开不做补间；大动作（弹层、悬浮球架子、列表重排）用平滑弹簧或 `tween`。时长照抄设计 §7。
- 减少动态效果（`MotionPrefs.manual` 或系统动画缩放为 0）打开时，所有界面过渡换成 150 ms 淡入淡出，宠物停在代表姿势上。
- 触控目标不小于 44dp；正文对比度不低于 4.5:1（设计 §5 已核对，照抄颜色即可）。
- 现有行为一律保留：设置里的每一项、作答只按 requestId 取请求、锁屏上作答先解锁（`withKeyguardDismissed`）、`AnswerDraft` 的提交规则、`SessionTap` 的分发。
- 文案用设计里的中文原文；没写到的地方沿用现有文案。
- 测试：`cd android && ./gradlew :core:test :app:testDebugUnitTest`；构建：`./gradlew :app:assembleRelease`；装机：在仓库根目录 `make android-install`。截图：`~/Library/Android/sdk/platform-tools/adb exec-out screencap -p > shot.png`。
- 每个任务一个提交，提交说明结尾带会话要求的署名行。

## Review Focus

1. **很长的名字、命令、分支名**（中英混排、没有空格的长路径）：草地标签、状态标签、命令纸条、悬浮球气泡、看板名字都不能溢出像素轮廓或把相邻元素挤歪，只能截断或换行。由 Task 18 用调试快照的 `--ez long true` 在真机上逐屏检查。
2. **会话数从 0 到 12**：草地最多站 5 只，多出来的合成一堆；0 个时显示空状态的那一只。由 Task 6 的 `BoardLayoutTest.placeRow*` 覆盖。
3. **离线时在首页列表里点「允许」**：按钮必须是灰的、点了什么都不发。由 Task 7 的 `HomeListTest.inlineAnswerNeedsConnection` 覆盖。
4. **减少动态效果打开时拖看板上的宠物**：松手直接回原位，不走路、不卡在半路。由 Task 4 的 `MotionCarryTest.reducedMotionSnapsHome` 覆盖。
5. **系统字体放大到 1.3 倍**：固定高度的地方（草地 236dp、额度卡、会话卡、作答卡头部）不能把字裁掉。由 Task 18 在真机上用 `adb shell settings put system font_scale 1.3` 检查，查完改回 1.0。

---

## 执行分批

| 批次 | 任务 | 依赖 | 说明 |
|---|---|---|---|
| A 地基 | 1–5 | 无 | 先做，后面都用它 |
| B 首页 | 6–7 | A | 和 C、D 并行（各用自己的 worktree） |
| C 弹层 | 8–10 | A | 同上 |
| D 引导、配对、设置 | 11–13 | A | 同上 |
| E 看板、悬浮球、图标、通知 | 14–17 | A、D | D 合回 main 之后再做（共用 `BoardTriggerService`） |
| 收尾 | 18 | 全部 | 真机走查、台账 |

## 文件结构

```
android/app/src/main/res/font/            nunito.ttf  silkscreen_regular.ttf  silkscreen_bold.ttf
android/fonts/                            OFL-Nunito.txt  OFL-Silkscreen.txt
android/app/src/main/kotlin/local/critter/phone/
  ui/look/PixelOutline.kt   台阶轮廓的顶点（纯逻辑）
  ui/look/PixelIcons.kt     像素图标的行数据和合并成横条（纯逻辑）
  ui/look/PixelDrawable.kt  View 用的像素面（悬浮球）
  ui/look/Meters.kt         分格条点亮几格、颜色档（纯逻辑）
  ui/look/Wordmark.kt       Logo 的格子（纯逻辑）
  ui/look/Sky.kt            天空分档、配色、草地格子（纯逻辑）
  ui/look/Stepped.kt        60 ms 一格的缓动
  ui/theme/Theme.kt         CritterColors、字体、CritterTheme（重写）
  ui/theme/BoardColors.kt   看板固定配色
  ui/theme/PixelShape.kt    Compose 的 Shape 和 Modifier.pixelSurface
  ui/theme/PixelIcon.kt     Compose 画像素图标
  ui/theme/Components.kt    按钮、状态标签、开关、分段、滑块、分格条、输入框、选项卡
  ui/theme/WordmarkImage.kt
  ui/meadow/MeadowBackdrop.kt  天空和草地（一张缓存的位图）
  ui/meadow/PetStage.kt        一小块草地上的一只会动的宠物
  ui/meadow/Meadow.kt          首页草地：多只宠物、名字标签、等你确认的气泡
  ui/sheet/SheetScaffold.kt    底部弹层外壳（遮罩、台阶顶、滑入、抬头看你）
  critter/Portraits.kt         静止小头像位图和缓存
android/core/src/main/kotlin/local/critter/core/
  motion/MotionCues.kt      抬头看你、跳一下
  motion/MotionActorInteraction.kt  + carry / walkHome
  board/BoardLayout.kt      + placeRow
  board/BoardTrigger.kt     + Action.Blocked
  net/PairOutcome.kt        配对结果和失败原因
scripts/dev/make-android-icons.py   从 Skins/sprig/manifest.json 生成图标矢量
```

---

## 批次 A：地基

### Task 1: 颜色、字体、主题、状态的样子

**Files:**
- Create: `android/app/src/main/res/font/nunito.ttf`, `silkscreen_regular.ttf`, `silkscreen_bold.ttf`；`android/fonts/OFL-Nunito.txt`, `android/fonts/OFL-Silkscreen.txt`；`ui/theme/BoardColors.kt`
- Modify: `ui/theme/Theme.kt`（重写），`ui/SessionUi.kt`，`data/SettingsStore.kt`，`README.md`（许可一节），`res/values/themes.xml`，`AndroidManifest.xml`
- Test: `app/src/test/kotlin/local/critter/phone/PresentationTest.kt`

**Interfaces:**
- Produces:
  - `@Immutable data class CritterColors(...)`，字段名照设计 §5 的名字：`bg, surface, surface2, shade, line, ink, ink2, ink3, brand, brandDeep, brandSoft, onBrand, knob, highlight, run, runBg, runGlyph, wait, waitDeep, waitInk, waitBg, done, doneBg, doneGlyph, err, errBg, errGlyph, idle, idleBg, term, termInk, termDim, scrim`（都是 `Color`）。`val LightCritterColors`、`val DarkCritterColors`。
  - `val LocalCritterColors`；`object Critter { val colors: CritterColors @Composable @ReadOnlyComposable get() }`。
  - `val Nunito: FontFamily`（400/600/700/800/900，用 `FontVariation.weight`），`val Silkscreen: FontFamily`（400、700）。
  - `@Composable fun CritterTheme(dark: Boolean = isSystemInDarkTheme(), content)`：提供 `LocalCritterColors`，并把 MaterialTheme 的 colorScheme、typography 映射过去（正文 Nunito）。
  - `object BoardColors`：设计 §5“看板”一节的全部颜色。
  - `data class StateColors(val fg: Color, val bg: Color, val glyph: Color)`；`fun CritterColors.state(s: PetState): StateColors`（waiting 的 `bg` 是实心 `wait`、`fg` 是墨色 `#2A2140`）。
  - `fun stateIcon(s: PetState): String`：`waiting→"q"`, `running→"sun"`, `done→"check"`, `error→"bang"`, `idle/unknown→"z"`（图标名对应 Task 2 的 `PixelIcons`）。
  - `fun folderBranch(s: BridgeSession): String`（“proj · main”，没有分支时只有目录）；`placeLine(s)` 改成“目录 · 分支 · 来源”。
  - `PhoneSettings` 新增 `openingShownOn: Long? = null`（上次播开场动画的那天，`LocalDate.toEpochDay()`）和 `boardBlockedAt: Long? = null`（看板最近一次被系统拦下的时间，毫秒）。读写照现有字段的写法。

- [ ] **Step 1: 改测试**：`PresentationTest` 里加 `placeLineIsFolderBranchSource`：`placeLine(session())` 等于 `"proj · main · 终端"`；`folderBranch(session(branch = null))` 等于 `"proj"`。加 `stateIconsMatchTheDesktopMarkers`：五个状态依次是 `q sun check bang z`。
- [ ] **Step 2: 跑测试，确认失败**：`./gradlew :app:testDebugUnitTest --tests '*PresentationTest*'`，预期 `folderBranch`、`stateIcon` 未定义。
- [ ] **Step 3: 下载字体**（走代理）：`curl -x http://127.0.0.1:1082 -L -o …` 从 `https://github.com/google/fonts/raw/main/ofl/nunito/Nunito%5Bwght%5D.ttf`、`…/ofl/silkscreen/Silkscreen-Regular.ttf`、`…/Silkscreen-Bold.ttf`，以及两个目录下的 `OFL.txt`。资源文件名全小写（上面的名字）。README“许可”一节加一句：字体 Nunito、Silkscreen 以 SIL Open Font License 1.1 发布，许可文本在 `android/fonts/`。
- [ ] **Step 4: 实现**上面的 Interfaces。`stateColor()` 保留给 View 代码，改成返回设计 §5 的符号色（运行 `#E8A21E`、等你确认 `#FF9F0A`、做完 `#2FB457`、出错 `#F0453A`、空闲 `#8C85A3`）。删掉 `CritterOrange`；`WaitingOrange` 保留（值不变），其余调用处在后面的任务里换掉。`themes.xml` 加 `Theme.Critter.Main`（父 `Theme.Material.Light.NoActionBar`，`windowBackground` 用 `#F4F2FA`），清单里 application 的主题换成它。
- [ ] **Step 5: 跑测试和构建**：`./gradlew :app:testDebugUnitTest :app:assembleRelease`，全部通过。
- [ ] **Step 6: 提交**：`feat(android): Critter colors, fonts and state styles`

### Task 2: 像素轮廓、像素面、像素图标

**Files:**
- Create: `ui/look/PixelOutline.kt`, `ui/look/PixelIcons.kt`, `ui/look/PixelDrawable.kt`, `ui/theme/PixelShape.kt`, `ui/theme/PixelIcon.kt`
- Test: `app/src/test/kotlin/local/critter/phone/PixelLookTest.kt`

**Interfaces:**
- Produces:
  - `fun pixelOutline(width: Float, height: Float, step: Float, topOnly: Boolean = false): FloatArray`：顶点 `x0,y0,x1,y1,…`，顺时针，从左上角下面那一点开始。完整轮廓 20 个点：每个角 `(0,2s) (s,2s) (s,s) (2s,s) (2s,0)` 的镜像；`topOnly` 12 个点（下面两个角是直角）。`step` 先夹到 `floor(min(width, height) / 4)` 以内。
  - `class PixelShape(val step: Dp, val topOnly: Boolean = false) : Shape`（用 `pixelOutline` 建 `Path`，台阶按整像素取整）。
  - `fun Modifier.pixelSurface(color: Color, step: Dp = 4.dp, lip: Dp = 4.dp, lipColor: Color, highlight: Color? = null, recessed: Boolean = false, border: Color? = null, borderWidth: Dp = 3.dp, topOnly: Boolean = false): Modifier`：裁成 `PixelShape`、填色；底边（`recessed` 时是顶边）画 `lip` 高的 `lipColor` 条；`highlight` 非空时在 `(2s,s) (3s,s) (s,2s)` 画三格；`border` 用“外层填描边色、内层缩进 `borderWidth`、内层台阶 `step - 1dp`”的做法（设计 §4）。
  - `object PixelIcons { val rows: Map<String, List<String>>; fun runs(rows: List<String>): List<IntArray> }`：`rows` 照抄草图脚本 `ICONS` 的全部条目（含 8 列宽的 `seed`、`bud`、`sprout`，5×5 的 `z`）；`runs` 把每行连续的 `#` 合成 `[x, y, length]`。
  - `@Composable fun PixelIcon(name: String, modifier: Modifier = Modifier, tint: Color = LocalContentColor.current, cell: Dp = 2.dp)`：用 `Canvas` 画 `runs`，尺寸 = 列数 × cell、行数 × cell。
  - `class PixelDrawable(fill: Int, stepPx: Int, lipPx: Int, lipColor: Int, highlight: Int? = null, topOnly: Boolean = false) : Drawable`；`fun PixelIcons.bitmap(name: String, color: Int, cellPx: Int): Bitmap`（悬浮球用）。

- [ ] **Step 1: 写测试** `PixelLookTest`：
  - `fullOutlineHasTwentyCornersClockwise`：`pixelOutline(100f, 40f, 4f)` 长度 40，前 10 个数是 `0,8, 4,8, 4,4, 8,4, 8,0`，第 11–12 个数是 `92,0`。
  - `topOnlyKeepsSquareBottom`：`pixelOutline(100f, 40f, 4f, topOnly = true)` 长度 24，最后两点 `100,40` 和 `0,40`。
  - `stepIsClampedToAQuarterOfTheShortSide`：`pixelOutline(10f, 10f, 4f)` 的第 2 个数（第一个点的 y）是 `4f`（step 夹到 2）。
  - `everyIconIsRectangular`：`PixelIcons.rows` 每个图标的各行长度相同。
  - `runsCoverEveryPixelOnce`：对每个图标，`runs` 的长度和等于 `#` 的个数，且没有两个 run 重叠。
- [ ] **Step 2: 跑测试，确认失败**（未定义）。
- [ ] **Step 3: 实现**上面的 Interfaces。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 提交**：`feat(android): pixel outline, surfaces and icons`

### Task 3: 部件、分格条、Logo

**Files:**
- Create: `ui/look/Meters.kt`, `ui/look/Wordmark.kt`, `ui/look/Stepped.kt`, `ui/theme/Components.kt`, `ui/theme/WordmarkImage.kt`
- Test: `app/src/test/kotlin/local/critter/phone/PixelLookTest.kt`（续）

**Interfaces:**
- Consumes: Task 1 的 `Critter.colors`、`Nunito`、`Silkscreen`、`stateIcon`、`state()`；Task 2 的 `pixelSurface`、`PixelIcon`。
- Produces:
  - `fun litSegments(percent: Double?, segments: Int): Int`（`round(p/100 × n)` 夹在 0..n，null 为 0）；`enum class MeterLevel { Calm, Busy, Hot }`；`fun meterLevel(percent: Double?): MeterLevel`（< 60 Calm，< 85 Busy，其余 Hot）。
  - `fun steppedFraction(x: Float, steps: Int): Float`（`floor(x × steps) / steps`，x ≥ 1 时为 1）；`val PixelSteps3: Easing`。
  - `object Wordmark { const val WIDTH = 42; const val HEIGHT = 9; fun cells(): List<WordmarkCell> }`，`data class WordmarkCell(val x: Int, val y: Int, val kind: Kind)`，`enum Kind { Ink, Leaf, Stem }`。字母行照抄草图脚本 `LETTERS`（`i` 的前两行 `G..G`、`.gg.` 是 Leaf、Stem）。
  - `@Composable fun WordmarkImage(cell: Dp, ink: Color, shade: Color, modifier)`：先画下移一格的 `shade`，再画字（Leaf `#6BCB5F`，Stem `#3F9442`）。
  - 部件（全在 `Components.kt`，样子照草图“部件”一节）：
    - `enum class ButtonKind { Primary, Secondary, Warning, Ghost }`，`enum class ButtonSize { Small, Regular, Large }`（高 34 / 44 / 52dp）；`@Composable fun PixelButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, kind: ButtonKind = ButtonKind.Primary, size: ButtonSize = ButtonSize.Regular, enabled: Boolean = true, icon: String? = null)`：按下时 `graphicsLayer.translationY = 3dp`、底边 1dp，不补间；Primary、Warning 有高光；禁用时 `surface2` 底、`ink3` 字。
    - `@Composable fun StateChip(state: PetState, text: String = stateLabel(state))`：`state` 变化时上移 3dp 停一格（60 ms）再落回（`LaunchedEffect(state)`，不是循环动画）。
    - `@Composable fun PixelSwitch(checked: Boolean, onCheckedChange: (Boolean) -> Unit, contentDescription: String)`：轨道 46×28，圆头 20dp，`animateDpAsState(tween(180, easing = PixelSteps3))`，`Modifier.toggleable(role = Role.Switch)`。
    - `@Composable fun PixelSegmented(options: List<String>, selected: Int, onSelect: (Int) -> Unit, modifier)`。
    - `@Composable fun PixelSlider(value: Float, onValueChange: (Float) -> Unit, range: ClosedFloatingPointRange<Float>, segments: Int = 10, modifier)`：值吸附到 `segments` 等分；滑块头是 `sun` 图标；可拖、可点。
    - `@Composable fun SegmentMeter(percent: Double?, segments: Int, modifier, height: Dp = 8.dp, level: MeterLevel? = meterLevel(percent))`：Calm 用 `doneGlyph`、Busy 用 `runGlyph`、Hot 用 `errGlyph`；`level = null` 时用 `brand`。
    - `@Composable fun PixelField(value: String, onValueChange: (String) -> Unit, placeholder: String, modifier, enabled: Boolean = true, minLines: Int = 1, maxLines: Int = 5, focused 时描主色边)`（`BasicTextField`，凹面）。
    - `@Composable fun OptionCard(title: String, description: String?, selected: Boolean, multi: Boolean, onClick: () -> Unit, enabled: Boolean = true)`；`@Composable fun WriteOwnCard(text: String, onClick: () -> Unit)`（虚线卡片）。
    - `@Composable fun rememberReduceMotion(): Boolean`（`MotionPrefs.manual` 或系统动画缩放为 0；回到前台时重读）。

- [ ] **Step 1: 写测试**：
  - `litSegmentsRoundsAndClamps`：`(11.0, 10)→1`，`(62.0, 10)→6`，`(100.0, 10)→10`，`(140.0, 10)→10`，`(-5.0, 10)→0`，`(null, 20)→0`，`(32.0, 24)→8`。
  - `meterLevelsSplitAtSixtyAndEightyFive`：`59.9→Calm`，`60.0→Busy`，`84.9→Busy`，`85.0→Hot`，`null→Calm`。
  - `steppedFractionMovesInThirds`：`(0.2,3)=0f`，`(0.5,3)=1/3f`，`(0.99,3)=2/3f`，`(1f,3)=1f`。
  - `wordmarkIsFortyTwoByNine`：所有格子 `x in 0..41`、`y in 0..8`；`Leaf` 和 `Stem` 只出现在 `y in 0..1`、`x in 13..16`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**上面的 Interfaces。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 提交**：`feat(android): pixel components, meters and the wordmark`

### Task 4: 宠物：动作片段、拖动后走回、静止小头像、CritterView 新接口

**Files:**
- Create: `android/core/src/main/kotlin/local/critter/core/motion/MotionCues.kt`, `app/.../critter/Portraits.kt`
- Modify: `core/.../motion/MotionActorInteraction.kt`, `app/.../critter/CritterView.kt`
- Test: `android/core/src/test/kotlin/local/critter/core/motion/MotionCuesTest.kt`, `MotionCarryTest.kt`

**Interfaces:**
- Produces（`:core`）：
  - `object MotionCues { fun lookAtYou(skin: SkinManifest): MotionClip; fun hop(skin: SkinManifest): MotionClip }`。`lookAtYou` = `skin.clips[interactions.notice]` 的各键，再接 `[lookUp, 12] [blinkPose, 2] [lookUp, 10] [lookCenter, 2]`（设计 §7）。`hop` = `[hop,1,0,2] [hop,1,0,4] [hop,1,0,3] [hop,1,0,1] [land,2,0,0,landDust]`。
  - `fun MotionActor.carry(dxCells: Double)`：被拎着时身体画在离锚点 `dxCells` 格处（写 `offX`，不设 `following`）。
  - `fun MotionActor.walkHome()`：开始走回锚点，复用现有跟随行走（`following = true`、`followHold = false`、`followLook = null`）；到家后 `followStep` 已有的逻辑会停下并眨眼。
- Produces（`:app`）：
  - `object Portraits { fun still(manifest: SkinManifest, state: PetState, activity: String?, cellPx: Int, asleep: Boolean = false, dim: Boolean = false, dimStrength: Double = 0.5): Bitmap }`：20×20 格，基准框左边在第 1 格、地面在最底一行；用 `MotionActor(reduceMotion = true)` 的快照和 `CritterRenderer.draw` 画；按全部参数做 key 的 LRU 缓存（48 张）。`@Composable fun CritterPortrait(manifest, state, activity, cell: Dp, modifier, asleep = false, dim = false)`（`Image`，`FilterQuality.None`）。
  - `CritterView` 新增：
    - `fun playClip(sessionId: String, clip: MotionClip, delayMs: Long = 0)`；`fun lookAtYou(sessionId: String)`（播 `MotionCues.lookAtYou`）；`fun hop(sessionId: String, delayMs: Long = 0)`。
    - `fun sinkAll(staggerMs: Long = 60, onDone: () -> Unit)`：照桌面 `FlockChoreographer.sinkOut`：每只先 `holdUnderground(12)` 再播 `interactions.vanish`，间隔 `staggerMs`；减少动态效果时立刻完成；全部播完调 `onDone`。
    - `fun riseAll(staggerMs: Long = 90, join: Boolean = false)`：还没在地下的先 `holdUnderground(12)`，然后逐只 `releaseUnderground()` 并播 `interactions.appear`（`join` 为 true 时播 `interactions.join`，钻出来后左右看看）。
    - `var carryOnDrag: Boolean = false`：为 true 时，拎起后横向跟手（`carry((rawX - downRawX) / scale)`，再把身体夹在视图左右边界内），松手播 `drop`，`drop` 播完 `walkHome()`；`CritterTouchListener` 新增 `fun onCarry(sessionId: String, away: Boolean) {}`：拎起时 `away = true`，走到家时 `false`。为 false 时行为不变（悬浮球靠 `onDragBy` 挪窗口）。

- [ ] **Step 1: 写 core 测试**：
  - `MotionCuesTest.lookAtYouIsNoticeThenAHeldLookUp`：用 `Skins/sprig/manifest.json`（core 测试已能读到），clip 的姿势序列是 `attn, base, look_up, shut, look_up, base`，帧数和为 29。
  - `MotionCuesTest.hopLandsWithDust`：5 个键，最后一个 `effect == interactions.landDust`，帧数和 6。
  - `MotionCarryTest.carriedCritterWalksHomeAfterTheDrop`：sprig 演员 `carry(10.0)` 后快照 `offsetX == 10`；`walkHome()` 后逐拍 `step()`，`offsetX` 依次 `8, 6, 5, 4, 3, 2, 1, 0`；走的时候姿势属于 `interactions.walkLeft`；到 0 后 `following == false`。
  - `MotionCarryTest.reducedMotionSnapsHome`：`reduceMotion = true`，`carry(10.0)`、`walkHome()`、一拍之后 `offsetX == 0`。
- [ ] **Step 2: 跑测试，确认失败**：`./gradlew :core:test --tests '*MotionCues*' --tests '*MotionCarry*'`。
- [ ] **Step 3: 实现 core 部分。** 不改 `followStep`、`followPose` 的现有行为（金样测试必须照旧通过）。
- [ ] **Step 4: 实现 app 部分**（`Portraits`、`CritterView` 新接口）。
- [ ] **Step 5: 跑全部测试和构建**：`./gradlew :core:test :app:testDebugUnitTest :app:assembleRelease`，包括 `GoldenTest` 在内全部通过。
- [ ] **Step 6: 提交**：`feat(android): look-at-you and hop cues, carry and walk home, still portraits`

### Task 5: 天空、草地、一小块草地上的宠物

**Files:**
- Create: `ui/look/Sky.kt`, `ui/meadow/MeadowBackdrop.kt`, `ui/meadow/PetStage.kt`
- Test: `app/src/test/kotlin/local/critter/phone/SkyTest.kt`

**Interfaces:**
- Produces:
  - `enum class SkyTime { Dawn, Day, Dusk, Night }`；`fun skyTimeAt(hour: Int, dark: Boolean): SkyTime`（dark → Night；6–9 Dawn；10–16 Day；17–19 Dusk；其余 Night）。
  - `data class SkyColors(val top: Long, val middle: Long, val bottom: Long, val cloud: Long, val grass: Long, val grassHi: Long, val grassLo: Long, val onSky: Long, val tag: Long, val tagInk: Long)`（ARGB）；`fun skyColors(time: SkyTime): SkyColors`，数值照抄设计 §5（白天 `#9FD6FF/#C4E8FF/#E8F6FF`、清晨、黄昏、夜里；草 `#8ED07A/#B5E39C/#6DB65A`，夜里 `#2F5A33/#3E7342/#22452A`；`onSky` 黄昏和夜里是白，其余墨色；`tag` 白 88% / 夜里 `#17142A` 82%；`tagInk` 同 `onSky`）。
  - `data class MeadowCell(val x: Int, val y: Int, val w: Int, val h: Int, val color: Long)`；`fun meadowCells(width: Int, height: Int, ground: Int, cell: Int, time: SkyTime, seed: Int = 7, clouds: List<Pair<Float, Float>> = DEFAULT_CLOUDS, moon: Pair<Float, Float> = 0.58f to 0.3f): List<MeadowCell>`：照草图脚本 `paintMeadow` 的最终版：三段天空分在 `ground` 的 42% 和 74%（吸附到 `cell` 的整数倍）；每个分界只有一行抖动（下段第一行 `i % 2 == 0` 的格子用上段色，上段最后一行 `i % 4 == 1` 的格子用下段色）；非夜里且 `ground > 60` 时画 `CLOUD` 云；夜里画 `round(width × ground / 2600)` 颗星（用 `seed` 的线性同余数列）和 `MOON` 月亮；草从 `ground` 开始，第一行亮色，草尖（`i % 7 == 2` 一格、`i % 13 == 8` 两格），暗点 `width × (height − ground) / 900` 个。
  - `@Composable fun MeadowBackdrop(time: SkyTime, ground: Dp, modifier: Modifier, cell: Dp = 3.dp)`：按尺寸和 `time` 生成一张 `ImageBitmap`（`remember` 缓存），整张画出来；不做逐帧绘制。
  - `@Composable fun PetStage(manifest: SkinManifest, state: PetState, activity: String?, modifier: Modifier, cell: Dp = 4.dp, time: SkyTime = currentSkyTime(), groundInset: Dp = 22.dp, bright: Boolean = true, asleep: Boolean = false, onView: (CritterView) -> Unit = {})`：`MeadowBackdrop` 加一只居中的 `CritterView` 宠物；`bright` 时不带 `dim` 色调（装饰用的宠物不淡化，设计 §8.2）；`onView` 把视图交给调用者（弹层用它播“抬头看你”）。
  - `@Composable fun currentSkyTime(): SkyTime`（整点刷新一次，用现有 `rememberMinuteClock` 推出小时；深色主题一律 Night）。

- [ ] **Step 1: 写测试** `SkyTest`：
  - `hoursMapToFourSkies`：`5→Night, 6→Dawn, 9→Dawn, 10→Day, 16→Day, 17→Dusk, 19→Dusk, 20→Night`；`skyTimeAt(12, dark = true) == Night`。
  - `duskAndNightTextIsWhite`：`skyColors(Dusk).onSky == 0xFFFFFFFF`，`skyColors(Night).onSky == 0xFFF3F0FC`，`skyColors(Day).onSky == 0xFF2A2140`。
  - `bandsSplitAtFortyTwoAndSeventyFourPercent`：`meadowCells(360, 236, 200, 3, Day)` 里 `y == 0` 的大块颜色是 top，`y == 84` 那一行出现 middle 的大块，`y == 147` 那一行出现 bottom 的大块。
  - `starsAndMoonOnlyAtNight`：白天的格子里没有 `#FFF3C4`，夜里有。
  - `sameSeedSameMeadow`：同样参数调两次结果相等；换 `seed` 不等。
  - `grassStartsAtTheGround`：所有 `color == grass` 的格子 `y >= 200`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**上面的 Interfaces。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 提交**：`feat(android): sky, meadow backdrop and the pet stage`

---

## 批次 B：首页

### Task 6: 草地上的一排宠物

**Files:**
- Modify: `core/.../board/BoardLayout.kt`
- Create: `ui/meadow/Meadow.kt`
- Test: `core/src/test/kotlin/local/critter/core/board/BoardLayoutTest.kt`

**Interfaces:**
- Consumes: Task 5 的 `MeadowBackdrop`、`skyColors`；Task 4 的 `CritterView.riseAll`。
- Produces:
  - `fun BoardLayout.placeRow(count: Int, widthDp: Float, groundDp: Float, scale: Float, marginDp: Float, maxPerRow: Int): Layout`：一行、固定 `scale`、宠物宽 18 格、间隔 4 格、堆多占 7 格，放不下时最后一格变成堆（和 `place` 同样的规则，只是不缩放）。
  - `@Composable fun Meadow(sessions: List<BridgeSession>, library: SkinLibrary, dim: Double, time: SkyTime, onTap: (String) -> Unit, modifier: Modifier, height: Dp = 236.dp, ground: Dp = 200.dp, asleep: Boolean = false, bubbles: Map<String, String> = emptyMap(), opening: Boolean = false)`：背景 `MeadowBackdrop`；`placeRow(n, 宽, ground, 3f, 12f, 5)`；一个 `CritterView`（整像素格）；每只脚下白色名字标签（`tag`/`tagInk`，10.5sp，一行截断），`bubbles` 里有的那只头顶一个橙色气泡（台阶尾巴，草图“首页”）；堆用 `PileSlots.build` 和计数；`asleep` 时全部 `CritterSlot(sleeping = true)` 且调暗；`opening` 为 true 时第一次有宠物时调 `riseAll(80)`。

- [ ] **Step 1: 写测试** `BoardLayoutTest`：
  - `placeRowFitsFiveOnAPhone`：`placeRow(5, 360f, 200f, 3f, 12f, 5)` 有 5 个位置、`pileFrom == null`、`x` 依次 `21, 87, 153, 219, 285`、`y` 都是 200。
  - `placeRowPilesTheRest`：`placeRow(7, 360f, 200f, 3f, 12f, 5)` 有 4 个位置、`pileFrom == 3`；`placeRow(12, …)` 同样 4 个、`pileFrom == 3`。
  - `placeRowEmpty`：`placeRow(0, …)` 没有位置。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**上面的 Interfaces。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 提交**：`feat(android): a meadow row of Critters`

### Task 7: 首页

**Files:**
- Modify: `ui/home/HomeScreen.kt`（重写），`bridge/BridgeRepository.kt`（加 `answerPermission`）
- Create: `ui/home/HomeList.kt`（纯逻辑）
- Test: `app/src/test/kotlin/local/critter/phone/HomeListTest.kt`

**Interfaces:**
- Consumes: Task 6 的 `Meadow`；Task 3 的部件；Task 4 的 `CritterPortrait`；`ui/board/ProBoard.kt` 的 `cardRequests`。
- Produces:
  - `fun inlineAnswer(request: CardRequest?, online: Boolean): InlineAnswer`，`enum class InlineAnswer { None, AllowDeny, AllowDenyDisabled, Open }`：单个权限请求在线时 `AllowDeny`、离线时 `AllowDenyDisabled`；提问、计划或多个请求时 `Open`；没有请求时 `None`。
  - `fun openingDue(lastShownOn: Long?, today: Long): Boolean`（今天还没播过）。
  - `fun BridgeRepository.answerPermission(request: BridgePending, allow: Boolean, onResult: (ServerMessage.Result) -> Unit)`（写在 `BridgeRepository` 里）：用 `AnswerDraft` 生成回答，在仓库自己的 `scope` 里发（离开画面不取消），`onResult` 回到主线程。

- [ ] **Step 1: 写测试** `HomeListTest`：
  - `inlineAnswerNeedsConnection`：单个权限请求，`online = true → AllowDeny`，`false → AllowDenyDisabled`。
  - `questionsAndPlansOpenTheCard`：提问 → `Open`；两个权限请求（`more == 1`）→ `Open`；`null → None`。
  - `openingOncePerDay`：`(null, 100) → true`，`(100, 100) → false`，`(99, 100) → true`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现首页**，照草图“首页”四个画面：
  - 草地 236dp 铺到状态栏下（`MainActivity` 已 `enableEdgeToEdge`），左上 Mac 名（21sp 900）和连接标签（`tag` 底，像素点 + `connText`；离线时 “离线 · n 分钟前”），右上两个 44dp 图标按钮（`board`、`sliders`）。气泡：等你确认的会话写“等你确认”。开场：`openingDue(settings.openingShownOn, today)` 为真时 `opening = true` 并写回今天。
  - 额度两张卡：名字、Silkscreen 大数字（“%” 用 Nunito）、10 格 `SegmentMeter`、重置时间；`LimitsText.staleness` 有值时下面一行灰字。
  - “会话 n”标题；会话卡：56dp 小草地格子（底色 `state().bg` 的淡色，底部 7dp 草）里放 `CritterPortrait`（`cell = 2.dp`），名字、`StateChip`、在做什么、`目录 · 分支 · 来源`（三个像素小图标：`folder`、`branch`、来源用 `term`/`editor`/`laptop`），底部“上下文” + 24 格细分格条 + 百分比。
  - 有请求的卡片：3dp 橙色描边、排第一（`SessionOrder.forBoard` 已是这样），多一张命令纸条（`permissionBody`，等宽，`term` 底），按 `inlineAnswer` 显示「拒绝」「允许」（离线时灰，下面写“连上后才能作答”）或「打开回答」。点「允许」「拒绝」先 `withKeyguardDismissed`，再调 `repo.answerPermission`；失败（不是 `resolved`）时 Toast 显示 `message ?: "没有发送出去"`。
  - 离线：草地 `asleep = true` 加夜空；列表上方一张“连不上 xxx / 正在重试。下面是 n 分钟前的样子。”卡片带「重试」（调 `repo.ensureConnected()`）；额度和卡片 alpha 0.6。
  - 没有会话：草地上一只睡着的宠物（`skinOverride`，没有就 `sprig`），列表区 `seedling` 图标、“电脑上还没有会话”、“在电脑上开一个 Claude Code 会话，它的宠物会从这片草地里钻出来。”
  - 需要重新配对：保留现有逻辑，按钮换成 `PixelButton`。
  - 列表用 `LazyColumn`，`Modifier.animateItem()` 做重排。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机截图**：`make android-install`，截首页（浅色、深色各一张，深色用 `adb shell cmd uimode night yes`，看完改回 `no`），和草图对照；对不上的地方改到一致。
- [ ] **Step 6: 提交**：`feat(android): the home meadow and session cards`

---

## 批次 C：弹层

### Task 8: 弹层外壳

**Files:**
- Create: `ui/sheet/SheetScaffold.kt`

**Interfaces:**
- Consumes: Task 2 的 `PixelShape(topOnly)`；Task 3 的 `rememberReduceMotion`；Task 5 的 `PetStage`。
- Produces:
  - `@Composable fun SheetScaffold(onDismiss: () -> Unit, modifier: Modifier = Modifier, visible: Boolean = true, onSettled: () -> Unit = {}, content: @Composable ColumnScope.() -> Unit)`：全屏 `scrim` 遮罩（点了 `onDismiss`），底部 `surface` 面、6dp 台阶顶、40×5 抓手；进场从下滑入 300 ms（`spring(dampingRatio = 0.8f, stiffness = 380f)` 或 `tween(300, easing = CubicBezierEasing(.18f,.9f,.28f,1.08f))`），落稳后调 `onSettled` 一次；`visible = false` 时 200 ms 滑出（`tween(200, easing = FastOutLinearInEasing)`）；减少动态效果时都是 150 ms 淡入淡出。保留 `imePadding()`、`navigationBarsPadding()`，点面本身不穿透到遮罩。
  - `@Composable fun SheetHeader(manifest: SkinManifest, state: PetState, activity: String?, title: String, session: BridgeSession?, onView: (CritterView) -> Unit)`：72×64 小草地格子（底色 `waitBg`）里一只 `PetStage`（`cell = 3.dp`），右边 18sp 900 标题和“目录 · 分支 · 来源”。

- [ ] **Step 1: 实现**上面的 Interfaces（纯界面，没有可单测的逻辑）。
- [ ] **Step 2: 构建**：`./gradlew :app:assembleRelease` 通过。
- [ ] **Step 3: 提交**：`feat(android): the bottom sheet scaffold`

### Task 9: 作答卡片

**Files:**
- Modify: `ui/answer/AnswerSheet.kt`, `ui/answer/AnswerActivity.kt`
- Test: `app/src/test/kotlin/local/critter/phone/AnswerInputTest.kt`

**Interfaces:**
- Consumes: Task 8 的 `SheetScaffold`、`SheetHeader`；Task 3 的 `OptionCard`、`WriteOwnCard`、`PixelButton`、`PixelField`；Task 4 的 `CritterView.lookAtYou`。
- Produces:
  - `sealed interface AnswerOutcome { data object Sent; data object HandledElsewhere; data class Failed(val message: String) }`；`fun answerOutcome(result: ServerMessage.Result): AnswerOutcome`（ok → Sent；`resolved` → HandledElsewhere；其余 → Failed(message ?: "没有发送出去，再试一次")）。
  - `const val SUCCESS_HOLD_MS = 900L`。

- [ ] **Step 1: 写测试**（`AnswerInputTest` 里加）：`answerOutcomeMapsTheMacReceipt`：ok → `Sent`；`reason = resolved` → `HandledElsewhere`；`reason = failed, message = "socket 断了"` → `Failed("socket 断了")`；没有 message → `Failed("没有发送出去，再试一次")`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**，照草图“作答卡片”：
  - 外壳用 `SheetScaffold`，顶上 `SheetHeader`（标题用现有 `Alerts.requestTitle`），落稳后 `lookAtYou`。
  - 权限：命令纸条（`term` 底、等宽 12.5sp、`›` 提示符、最多 8 行后滚动）；「拒绝并写理由…」文字按钮，点开后纸条下出现 `PixelField`，按钮变成「拒绝并发送理由」；底部「拒绝」（Secondary，左）「允许」（Primary，右，宽 1.4 倍）。
  - 提问：每题主题小标签（`brandSoft` 底）+ 问题（15sp 900）+ `OptionCard`（单选圆点、多选方框）+ `WriteOwnCard` 点开 `PixelField`；多选题旁写“可多选”；底部「提交 n 个回答」；`submitsOnPick` 时点选项就提交（现有逻辑）。
  - 计划：凹面“纸”（`surface2`、顶边 3dp 深色），`MarkdownLite` 渲染，可滚动，底部 46dp 渐隐；「让它改…」点开纸缩短、下面 `PixelField`，按钮变「发回去」；「批准计划」。
  - 底部一行 `laptop` 图标 + “电脑上也能答，谁先答算谁的”。
  - 结果：`answerOutcome` 为 `Sent` 时主按钮 3 格（`PixelSteps3`，180 ms）变成 `doneGlyph` 底、“✓ 已允许 / 已提交 / 已批准”，头部 `PetStage` 的 `state` 换成 `done`（`CritterView.setActors` 收到新状态会播 done 的进场：欢呼撒花瓣），`SUCCESS_HOLD_MS` 后弹层滑出并 `finish()`；拒绝成功时宠物 `notice`，直接滑出。`HandledElsewhere` 和请求已消失：头部换成开着花的宠物（`PetStage`，`done`）、“已在电脑上处理”、“<名字> 的这个请求已经在电脑上处理了。”、「好的」，1.5 s 后自己关（现有时长）。离线：标题下一行“未连接，连上后才能作答”，按钮全灰。`Failed`：按钮上方红字原因，卡片不关。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机截图**：用电脑上真实的权限请求（或计划 5 之前用调试快照）截三种卡片，对照草图。
- [ ] **Step 6: 提交**：`feat(android): pixel answer cards with a success beat`

### Task 10: 会话详情与「发一句」

**Files:**
- Modify: `ui/detail/DetailActivity.kt`
- Create: `ui/detail/LetterFlight.kt`（纯逻辑）
- Test: `app/src/test/kotlin/local/critter/phone/SayFeedbackTest.kt`

**Interfaces:**
- Consumes: Task 8、Task 5 的 `PetStage`、Task 3 的部件。
- Produces: `fun letterPath(from: Pair<Float, Float>, to: Pair<Float, Float>, steps: Int = 7, rise: Float = 60f, cell: Float = 3f): List<Pair<Float, Float>>`：第 i 步（1..steps）的位置是线性插值减去 `sin(t·π)·rise`，再吸附到 `cell` 的整数倍。

- [ ] **Step 1: 写测试**（`SayFeedbackTest` 里加）：`letterArcsAndLands`：`letterPath(300f to 300f, 150f to 60f)` 有 7 个点；最后一点 `(150f, 60f)`；所有坐标是 3 的倍数；中间那点（第 4 个）的 y 比直线插值高约 60（误差 3 以内）。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**，照草图“会话详情”：
  - `SheetScaffold`；顶部 150dp 的 `PetStage`（`cell = 4.dp`，宠物在左 1/4 处），右侧一个侧向气泡（台阶尾巴朝左）写 `doingText`，一行截断；落稳后 `lookAtYou`。
  - 名字（20sp 900）+ `StateChip`；两列信息：目录（完整 `cwd`，一行截断）、分支、来源、模型，上下文占一整行（24 格 `SegmentMeter` + 百分比），最后更新；每项前一个像素小图标。
  - `PixelField`（“发一句…”）+ 48dp 发送按钮（`send` 图标）；下面小字说明（现有文案）。成功：按 `letterPath` 每 60 ms 移动一个 `letter` 图标，从发送按钮飞到宠物头顶，然后宠物 `lookAtYou`；输入框清空；下面绿字 `sayFeedback`。失败：红字，保留输入。
  - 弹层跟着输入法升起（保留 `imePadding`）。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机截图**并对照草图。
- [ ] **Step 6: 提交**：`feat(android): the details sheet and the flying letter`

---

## 批次 D：引导、配对、设置

### Task 11: 配对失败的原因

**Files:**
- Create: `core/.../net/PairOutcome.kt`
- Modify: `core/.../net/BridgeClient.kt`, `app/.../bridge/BridgeRepository.kt`
- Test: `core/src/test/kotlin/local/critter/core/net/BridgeClientTest.kt`, `core/src/test/kotlin/local/critter/core/net/PairOutcomeTest.kt`

**Interfaces:**
- Produces:
  - `enum class PairFailure { BadCode, Rejected, Protocol, CertMismatch, NoAnswer, Unreachable }`；`sealed interface PairResult { data class Paired(val paired: ServerMessage.Paired) : PairResult; data class Failed(val why: PairFailure) : PairResult }`。
  - `internal fun pairFailureOf(denied: DenyReason?, cause: Throwable?, timedOut: Boolean, closedCleanly: Boolean): PairFailure`：`badCode → BadCode`，`rejected → Rejected`，`protocol/badToken/unknown → Protocol`；没有 denied 时：`cause.hasPinMismatch() → CertMismatch`，`timedOut` 或 Mac 正常关掉连接（没有 denied 的 close，见协议文档“等 Mac 点允许 300 s”）→ `NoAnswer`，其余 → `Unreachable`。
  - `BridgeClient.pair(uri, deviceName): PairResult`（原来返回 `Paired?`）；`BridgeRepository.pair(uri): PairFailure?`（null 表示成功；地址不在局域网时返回 `Unreachable`）。
  - App：`fun pairFailureText(why: PairFailure): String`（`ui/pairing/PairingScreen.kt`），文案逐条照抄设计 §8.2。

- [ ] **Step 1: 写测试**：
  - `PairOutcomeTest`：上面映射的每一行一个断言（`SSLPeerUnverifiedException("Certificate pinning failure!")` 这类现有 `hasPinMismatch` 认的异常 → `CertMismatch`；`IOException("Connection refused") → Unreachable`；`timedOut = true → NoAnswer`）。
  - `BridgeClientTest.pairDeniedBadCodeSaysSo`：`FakeMac` 对 `pair` 回 `{"type":"denied","reason":"badCode"}` 后关闭，`pair()` 返回 `Failed(BadCode)`；`pairDeniedRejectedSaysSo` 同理 `Rejected`；`pairTimesOutAsNoAnswer`：`pairTimeoutMs = 300` 且 FakeMac 不回，返回 `Failed(NoAnswer)`；现有 `pairWaitsForApproval` 改成断言 `Paired`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**；`pair()` 里由 `link.ended` 的 `End` 和超时得出 `pairFailureOf` 的参数。`PairingScreen` 的报错换成 `pairFailureText(why)`（画面在 Task 12）。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 提交**：`feat(android): say why pairing failed`

### Task 12: 欢迎页、引导各步、配对画面

**Files:**
- Modify: `onboarding/OnboardingActivity.kt`, `ui/pairing/PairingScreen.kt`, `ui/pairing/QrScanner.kt`（只改取景框外观），`ui/MainActivity.kt`（`LocalNetworkGate` 换样式）
- Create: `onboarding/Seeds.kt`（纯逻辑）
- Test: `app/src/test/kotlin/local/critter/phone/OemGuideTest.kt`（同目录新增 `OnboardingStepsTest.kt`）

**Interfaces:**
- Consumes: Task 3 的部件和 `WordmarkImage`；Task 5 的 `PetStage`、`MeadowBackdrop`；Task 11 的 `pairFailureText`。
- Produces:
  - `enum class SeedState { Seed, Bud, Sprout }`；`fun seeds(current: Int, total: Int = 6): List<SeedState>`（之前的 Sprout，当前的 Bud，之后的 Seed）。
  - `Step` 枚举最前面加 `Welcome`；`fun onboardingSteps(onlyKeepAlive: Boolean, sdk: Int): List<Step>`（只有保活时 `[KeepAlive]`；否则 `Welcome` 开头，再按现有规则过滤本地网络、通知）。进度里的“n / 6”不算欢迎页。

- [ ] **Step 1: 写测试** `OnboardingStepsTest`：`seedsSproutBehindTheCurrentOne`：`seeds(2) == [Sprout, Sprout, Bud, Seed, Seed, Seed]`；`welcomeComesFirst`：`onboardingSteps(false, 37).first() == Welcome`，`onboardingSteps(true, 37) == [KeepAlive]`，`onboardingSteps(false, 33)` 不含 `LocalNetwork`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**，照草图“首次引导与配对”：
  - 欢迎页：470dp 清晨草地（`MeadowBackdrop` + 五只宠物 `riseAll(260, join = true)` 钻出来；顶部 `WordmarkImage(cell = 6.dp)` 和 “for Claude Code”），下面标题“电脑上的会话，在手机上也看得到”、一段说明、「开始配对」、小字“要先在 Mac 的 Critter 里打开「允许手机连接」”。
  - 每步顶部：六颗种子（`seed`/`bud`/`sprout` 图标，`ink3`/`brand`/`doneGlyph`）+ Silkscreen “n / 6”。权限各步：312×240 的 `PetStage` 插图（通知 = 团子 waiting，头顶画一条通知卡；悬浮窗 = 啾啾 idle；电池 = 刺球 idle；本地网络 = 小芽 idle）、24sp 标题、说明、主按钮、「跳过」、跳过后果（现有文案）。保持后台运行：左上 96×84 夜里草地睡觉的啾啾，步骤编号卡片（做完的换 `check`、去掉按钮）。
  - 配对页：扫码态深色全屏取景、四角像素直角（6dp 粗）、小芽 `look_up` 在框下（`PetStage` 无背景版或直接 `CritterView`），说明用设计 §8.2 的文案，底部「手动输入」「返回」；配对中（`busy`）：画出 Mac「添加手机」里那一行（“「${Build.MODEL}」请求连接”、「拒绝」「允许」，允许用橙色虚线框），上方 `PetStage` 小芽 waiting，标题“在 Mac 上点「允许」”；手动态：Mac 列表卡片（选中打“已选”），8 位码 4+4 两组格子（Silkscreen 24sp），连接按钮；出错：红底卡片 + 一只 `error` 状态的小宠物 + `pairFailureText`。
  - 已配对那一步（引导里 `pairing != null`）和配对成功用同一个版式（同样大小的插图区，宠物换成 done），不再从扫码画面跳到居中的一行字（台账“已配对面板切换有视觉跳动”）。
  - `LocalNetworkGate` 用同一套步骤版式。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机截图**：`adb shell am start -n local.critter.phone/.ui.MainActivity --ez onboarding true` 需要 debug 版，正式版就在设置里点「重新走一遍引导」，逐步截图对照草图。
- [ ] **Step 6: 提交**：`feat(android): welcome, seeds and the pixel pairing screens`

### Task 13: 设置，以及看板被系统拦下的记录

**Files:**
- Modify: `ui/settings/SettingsScreen.kt`（重写），`core/.../board/BoardTrigger.kt`，`board/BoardTriggerService.kt`
- Test: `core/src/test/kotlin/local/critter/core/board/BoardTriggerTest.kt`

**Interfaces:**
- Consumes: Task 3 的部件；Task 5 的 `PetStage`；Task 1 的 `PhoneSettings.boardBlockedAt`。
- Produces:
  - `BoardTrigger.Action.Blocked`：`evaluate` 里“打开了 2 秒没出现”那个分支返回 `Blocked`（原来是 `None`）；`onOpenFailed()` 改为返回 `Action`，返回 `Blocked`。
  - `BoardTriggerService.perform(Blocked)`：`settingsStore.update { it.copy(boardBlockedAt = now) }`（通知在 Task 17 加）。看板之后自己成功打开（`boardShown(true)` 且是自动打开的）时把 `boardBlockedAt` 清掉。

- [ ] **Step 1: 写测试**：`BoardTriggerTest.openThatNeverShowsReportsBlocked`：照现有 `openThatNeverShowsBacksOffUntilReplug` 的走法，2 秒到点那次 `onTick` 返回 `Blocked`；`openThatFailsOutrightReportsBlocked`：`onOpenFailed()` 返回 `Blocked`；现有两条退避测试照旧通过。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**触发器和服务部分。
- [ ] **Step 4: 实现设置页**，照草图“设置”：返回图标按钮 + “设置”；连接卡片（固定 44dp 的状态行：电脑图标、Mac 名、像素点 + `connText`；「重新配对」「取消配对」；“保持后台连接”开关）；分组卡片，每组标题前一个像素图标：
  - 形象：横向滚动的一排 76×70 小草地格子：“跟着电脑”（`laptop` 图标）、Clawd、小芽、团子、啾啾、刺球（`PetStage`，`cell = 3.dp`，`bright`）；选中的描 3dp 主色边、右上打勾，点选时那只播 `done` 的进场。
  - 悬浮球：显示悬浮球（缺权限时一条橙色提示 + 「去授权」）；大小 `PixelSegmented(小/中/大)` + 右边那个大小的宠物预览（2/3/4dp 一格）；空闲淡化跟着电脑（开关，关掉后出现 `PixelSlider`，0–100%）；没有会话时藏起来；全屏应用里隐藏。
  - 看板：亮度 `PixelSlider`（10%–100%，10 格）；充电横放时自动打开（说明文字照旧，没有悬浮窗权限时红字）；`boardBlockedAt != null` 时一条橙色提示“上次插电时被系统拦下了。vivo、小米等手机要在应用权限里打开「后台弹出界面」。”+「去打开」（打开应用详情页，并清掉 `boardBlockedAt`）；看板提示音。
  - 提醒：三个开关。动画与省电：减少动态效果；电池优化状态（已忽略时绿字）和「忽略电池优化」；保持后台运行（进入只有保活那一步的引导）；重新走一遍引导。
  - 确认取消配对用像素样式的对话框（同一套部件），文案不变。
- [ ] **Step 5: 跑测试和构建**，全部通过。
- [ ] **Step 6: 装机截图**并对照草图（上、下两屏）。
- [ ] **Step 7: 提交**：`feat(android): pixel settings and the board-blocked notice`

---

## 批次 E：看板、悬浮球、图标、通知

### Task 14: 看板宠物模式

**Files:**
- Modify: `board/CritterBoard.kt`, `ui/board/BoardActivity.kt`, `ui/board/BoardChrome.kt`

**Interfaces:**
- Consumes: Task 4 的 `carryOnDrag`、`onCarry`；Task 1 的 `BoardColors`、`Silkscreen`；Task 3 的 `SegmentMeter`、`PixelIcon`。

- [ ] **Step 1: 实现**，照草图“看板 · 宠物模式”和设计 §8.7：
  - 地平线：宠物脚下 40dp 内边距的一条 2dp `#1A1630`，稀疏的 4dp 暗草（`#16301B`），用 `Canvas` 画一次（随 `shift` 一起挪）。
  - 左上 Silkscreen 52sp 时钟（`BoardColors.clock`）和下面“10 月 19 日 星期日”（13sp，`dim`）；未连接时下面一行橙字（现有文案）。右上 5h / 7d 两条 10 格分格条 + Silkscreen 百分比；最右 40dp 模式切换按钮（宠物模式里画 `grid` 图标，专业模式里画 `paw`），替换现在的 “▤ / ◉” 文字。
  - 气泡：运行中和等你确认的宠物头上一个深色台阶气泡（`card2` 底、1.5dp `edge` 描边，12sp 两行）；等你确认的描 2dp 橙边，写“想 xxx”和第二行橙色“点我回答”。名字 14sp 900（`name` 色）、下面“目录 · 分支”11sp（`dim`）、再下面 14 格 3dp 分格条。
  - 拖动：`CritterView.carryOnDrag = true`；`onCarry(id, away)` 维护一个“离家的会话”集合，离家的那只气泡藏起来，名字留在原位。
  - `BoardChrome.rememberBurnInShift` 改成只在 `Lifecycle.State.STARTED` 时计时（`repeatOnLifecycle`），`BoardActivity` 的分钟时钟同理（台账“看板的分钟时钟和防烧屏循环不跟随生命周期”，画面相关，放这里）。
- [ ] **Step 2: 跑测试和构建**，全部通过（`BoardChromeTest` 照旧）。
- [ ] **Step 3: 装机验证**：插电横放打开看板，截图对照草图；拖一只宠物，确认只有它被拎起、松手落地后走回原位、气泡回来；打开减少动态效果再拖一次，确认直接回原位。
- [ ] **Step 4: 提交**：`feat(android): the pixel board and a Critter you can carry`

### Task 15: 专业看板

**Files:**
- Modify: `ui/board/ProBoard.kt`，`ui/board/BoardActivity.kt`（作答改调 `repo.answerPermission`）
- Test: `app/src/test/kotlin/local/critter/phone/ProBoardTest.kt`（照旧通过）

- [ ] **Step 1: 实现**，照草图“看板 · 专业模式”：左栏 212dp（Silkscreen 44sp 时钟、日期、两张额度卡：名字、Silkscreen 22sp 百分比、20 格分格条、重置时间）；右边两列卡片（`card` 底、1dp `edge` 描边、3dp 台阶），左上 44×40 的静止宠物（`CritterPortrait`，`dim`；等你确认的不调暗），名字、状态小标签（深色版配色）、在做什么、`folder`/`branch` 小图标 + 目录、分支、来源、16 格上下文条；`LazyVerticalGrid` 做不了跨两行，所以右边改成两个可滚动的 `Column`（共用一个滚动状态），卡片按顺序交替放进左右两列，有请求的卡片一律放左列最上面；`CardRequest.inline` 的卡片更高，带命令纸条和深色「拒绝」「允许」；其余请求「打开」。去掉 `CritterButton = #D97757`。「拒绝」「允许」改调 Task 7 的 `repo.answerPermission`，不再用 `lifecycleScope`（台账“`BoardActivity.answerPermission` 用 `lifecycleScope`”那条）。
- [ ] **Step 2: 跑测试和构建**，全部通过。
- [ ] **Step 3: 装机截图**并对照草图。
- [ ] **Step 4: 提交**：`feat(android): pro board cards with their Critters`

### Task 16: 悬浮球

**Files:**
- Modify: `overlay/PileView.kt`, `overlay/ColumnView.kt`, `overlay/OverlayController.kt`, `service/BridgeService.kt`, `bridge/BridgeRepository.kt`
- Test: `app/src/test/kotlin/local/critter/phone/OverlayLookTest.kt`

**Interfaces:**
- Consumes: Task 2 的 `PixelDrawable`、`PixelIcons.bitmap`；Task 4 的 `sinkAll`、`riseAll`、`hop`、`MotionCues.hop`。
- Produces:
  - `fun pileCounts(sessions: List<BridgeSession>): List<Pair<String, Int>>`（`overlay/PileCounts.kt`）：图标名和数量，顺序 `q, sun, check, bang, z`，数量为 0 的不出现。
  - `BridgeRepository.boardOnScreen: StateFlow<Boolean>`（`boardVisible()` 同时更新它）；`OverlayController.setBoardShown(shown: Boolean)`。

- [ ] **Step 1: 写测试** `OverlayLookTest.pileCountsInDesktopOrder`：等你确认 1、运行 2、做完 1、空闲 1 的会话列表 → `[q 1, sun 2, check 1, z 1]`；全是运行中 → `[sun n]`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**，照草图“悬浮球”和设计 §8.4：
  - 收起：上面一个白色台阶计数标签（`pileCounts`：像素图标 + Silkscreen 数字），下面“n 个会话”标签（同样的白底），脚下一条两层的浅影子（`rgba(20,10,40,.16)`）。离线：“离线”标签，一只睡着的宠物（现有）。
  - 展开：`ColumnView` 背景换成 `PixelDrawable`（`surface` 94%、4dp 底边、5dp 台阶）；顶部计数和“点宠物打开”；气泡换成 `PixelDrawable`（运行和做完 `surface2`，等你确认实心橙色 + 第二行“点我回答”）；标签“名字 · 来源”`ink2`；末尾「收起」是像素小按钮（`chevU` 图标）。View 代码里的颜色从 `LightCritterColors` / `DarkCritterColors` 按当前夜间模式取。
  - 展开动画：换成架子后 `scaleY` 从 0.3 到 1（`pivotY` = 那一堆的高度，240 ms，`OvershootInterpolator(1.2f)`），宠物自上而下 `hop(id, i × 55)`。收起动画：宠物自下而上 `hop`，然后架子 200 ms 缩回，换成那一堆，领头的 `hop`。减少动态效果时都是 150 ms 淡入淡出。
  - 看板在前台时藏起来（台账一.2）：`BridgeService` 收集 `repo.boardOnScreen`，调 `overlay.setBoardShown`。`setBoardShown(true)`：展开着就先直接收起（不播动画），然后 `pile.critters.sinkAll { hiddenForBoard = true; applyVisibility() }`；`setBoardShown(false)`：`hiddenForBoard = false; applyVisibility(); pile.critters.riseAll()`。`contentShown()` 加上 `!hiddenForBoard`。用户关着悬浮球时什么都不做。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机验证**：截收起、展开两张图对照草图；点展开、点收起看动画；打开看板确认悬浮球钻回地里、关掉看板确认钻出来。
- [ ] **Step 6: 提交**：`feat(android): pixel floating pile, and it hides while the board is up`

### Task 17: 应用图标、启动画面、通知

**Files:**
- Create: `scripts/dev/make-android-icons.py`；生成 `app/src/main/res/drawable/ic_launcher_background.xml`、`ic_launcher_foreground.xml`、`ic_launcher_monochrome.xml`、`ic_stat_critter.xml`；`app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`、`ic_launcher_round.xml`；`app/src/main/res/values-v31/themes.xml`
- Modify: `AndroidManifest.xml`，`service/Alerts.kt`，`board/BoardTriggerService.kt`，`service/NotificationActionReceiver.kt`
- Test: `app/src/test/kotlin/local/critter/phone/PresentationTest.kt`

**Interfaces:**
- Produces:
  - `Alerts.requestText(request: BridgePending, session: BridgeSession?): String?`：权限请求是 `permissionBody(request.input)`（命令或路径），其余是会话目录名（现有）。
  - `Alerts.publicTitle(session: BridgeSession?): String`：“<名字> 需要你确认”（没有会话时“会话 需要你确认”）；公开版本正文固定“解锁后查看内容”。
  - `fun receiverMayOpenCard(sdk: Int): Boolean = sdk < 31`（`NotificationActionReceiver`）：安卓 12 起从通知按钮的广播里启动界面会被系统悄悄拦下、不抛异常，所以 31 及以上不去尝试。
  - `Alerts.boardBlocked(context: Context)`：低优先级通知（`CH_STATUS` 渠道），标题“没能自动打开看板”，正文“系统拦下了后台弹出的界面。打开「后台弹出界面」后，下次插电就能自动打开。”，按钮「去设置」打开应用详情页。

- [ ] **Step 1: 写测试**（`PresentationTest`）：`receiverOpensCardsOnlyBeforeAndroid12`：`receiverMayOpenCard(30)` 为真、`31` 为假。`requestTextShowsTheCommand`：`input = {"command":"./gradlew test"}` 的权限请求 → `"./gradlew test"`；提问 → 会话目录名。`publicTitleHidesTheCommand`：`publicTitle(session())` 等于 `"proj 需要你确认"`，`publicTitle(null)` 等于 `"会话 需要你确认"`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 写图标生成脚本**并运行：读 `Skins/sprig/manifest.json` 的 `base` 姿势（部件按 `at` 和 `rows` 叠加，同 `SkinRenderer.grid`），按设计 §8.1：108dp 视口 36×36 格（每格 3dp），背景层是清晨天空（`#8FCEFF`/`#B4DEFF`/`#D6EEFF` 三段加抖动）和第 23 行起的草地（`#8ED07A`、第一行 `#B5E39C`、草尖、`#6DB65A` 暗点），前景层小芽左上在 (9, 13)；单色层是同一轮廓去掉 `o`、`w` 两种颜色；状态栏图标是 `SB_ICON`（草图脚本，12×11 格，24dp 视口，白色）。每一行连续同色格子合成一个矩形路径。脚本结果确定（同输入同输出），生成的文件提交进仓库。
- [ ] **Step 4: 清单和主题**：application 加 `android:icon="@mipmap/ic_launcher"`、`android:roundIcon="@mipmap/ic_launcher_round"`；`values-v31/themes.xml` 的 `Theme.Critter.Main` 加 `android:windowSplashScreenBackground` `#BFE3FF`、`android:windowSplashScreenAnimatedIcon` `@drawable/ic_launcher_foreground`。
- [ ] **Step 5: 通知**：所有 `setSmallIcon` 换成 `R.drawable.ic_stat_critter`，`setColor(0xFF6346D6)`；请求通知 `setContentText(requestText)`、`BigTextStyle`、大图标 `Portraits.still(…)` 画在 `waitBg` 圆角底上（96px）、`setVisibility(VISIBILITY_PRIVATE)` + `setPublicVersion(publicTitle / 解锁后查看内容，带同样的按钮)`（台账锁屏那条）；做完和出错的通知也带大图标；`BoardTriggerService.perform(Blocked)` 时调 `Alerts.boardBlocked`；`NotificationActionReceiver.openCard` 在 `receiverMayOpenCard(SDK_INT)` 为假时不启动界面，只 Toast“点通知正文打开卡片”（锁屏时是“先解锁手机，再点通知正文回答”），原通知保留（台账跳板那条）。
- [ ] **Step 6: 跑测试和构建**，全部通过。
- [ ] **Step 7: 装机验证**：桌面图标（圆形和系统主题图标各看一次）、启动画面、锁屏上的请求通知（只显示“需要你确认”）、解锁后的横幅（显示命令）、状态栏小图标，逐一截图。
- [ ] **Step 8: 提交**：`feat(android): Sprig app icon, splash and pixel notifications`

---

## 收尾

### Task 18: 真机走查、台账、文档

**Files:**
- Modify: `android/app/build.gradle.kts`（debug 版用 release 签名）、`app/src/debug/kotlin/local/critter/phone/DebugSnapshotReceiver.kt`（`--ez long true`）、`docs/critter-phone-backlog.md`、`docs/superpowers/specs/2026-10-19-critter-phone-visual-design.md`（状态）

- [ ] **Step 1: 调试工具**：`build.gradle.kts` 里有 `keystore.properties` 时 `debug { signingConfig = signingConfigs.getByName("release") }`，这样 debug 包能直接覆盖手机上的正式版、不丢配对。`DebugSnapshotReceiver` 加 `--ez long true`：会话名换成“这是一个名字特别特别长的会话-with-a-very-long-english-tail”，分支换成 `feature/a-really-long-branch-name-that-keeps-going`，命令换成一条 200 字符的 `adb shell` 命令。
- [ ] **Step 2: 走查**：`./gradlew :app:installDebug`，依次注入 `count 0`、`1`、`5`、`12` 和 `long true`，每种在首页、悬浮球（收起、展开）、看板两种模式、作答卡片、详情里各截一张；浅色、深色各一轮；`font_scale 1.3` 再一轮（Review Focus 1、2、5）。对不上草图或溢出的地方当场修，每处一个提交。
- [ ] **Step 3: 换回正式版**：`make android && make android-install`，确认连上电脑、真实会话正常。
- [ ] **Step 4: 台账**：`docs/critter-phone-backlog.md` 第一部分三项和第三部分里本计划做掉的条目（副标题顺序、已配对面板跳动、后台启动被拦没有提示、锁屏通知显示命令、pair() 分不清原因、通知跳板、看板时钟和防烧屏的生命周期）标记已完成并写上提交号；设计文档状态改成“已实现”。
- [ ] **Step 5: 提交**：`docs: phone visual round done`
