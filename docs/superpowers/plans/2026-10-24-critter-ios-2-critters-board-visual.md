# Critter 手机端 · iOS 计划 2：宠物、看板和像素界面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 iOS App 长成 Android 版现在的样子：
- 小宠物用桌面版的同一套代码画出来，会动、能摸、能拎；
- 首页草地、会话卡片、作答卡片、详情、配对、设置全部换成像素材质；
- 横屏看板的宠物模式和专业模式；App 在前台时，充电加横放自动打开。

另外做掉 `docs/critter-ios-backlog.md` 里"计划 2"和"前端优化轮"两组条目。

spec §14 第 3 步写的是"宠物与看板，按视觉设计做完整的界面"。Android 当年先做宠物（计划 3）再整套重做视觉（计划 4）；iOS 上视觉设计已经定稿，所以这份计划一次做完，不先做一版朴素的。首次引导（欢迎页、种子进度、通知和实时活动两步、快捷指令图解）属于 spec §14 第 5 步，放到 iOS 推送那份计划；推送、实时活动、提醒设置也在那里。

**Architecture:**
- **共享代码 `CritterKit`**：把 Mac App 里的 `SpriteAtlas`、`CritterSpriteLayer`、`MotionClock` 和 `CritterCore` 里的 `SoundTrigger` 移进来，补上 Android 视觉轮加进引擎的动作片段（抬头看你、跳一下）和拖走后走回原位，再把 Android 的 `BoardTrigger` 翻成 Swift。Mac 端代码只改 import 和访问级别。
- **手机逻辑 `CritterClient`**：所有不碰 UIKit 的部分——手机上的形象解析、合群判断、看板排位、看板的亮度和防烧屏、天空和草地格子、像素轮廓和图标行数据、标签让位、发一句的反馈——都放这里，在 Mac 上 `swift test`。照 Android 的 Kotlin 逐个翻，测试也逐个翻。
- **iOS App**：SwiftUI 画界面，宠物用一个 UIKit 视图 `CritterStageView`（多只 `CritterSpriteLayer` + 一个 `MotionClock` + 触摸），对应 Android 的 `CritterView`。像素部件对应 Android `ui/theme/` 下的那一套。

**Tech Stack:** 同计划 1，另外用到 QuartzCore、CoreMotion（重力）、AVFoundation（`AVAudioPlayer`，看板提示音）。不加第三方依赖，不加 capability / entitlement。

**Spec:** `docs/superpowers/specs/2026-10-23-critter-ios-design.md` §6.1、§8.2、§8.4、§8.6、§8.9、§9、§14 第 3 步。画面以视觉设计 `docs/superpowers/specs/2026-10-19-critter-phone-visual-design.md` 和它的草图 `2026-10-19-critter-phone-visual-mockups.html` 为准；看板的行为按 Android 设计 `docs/superpowers/specs/2026-10-18-critter-android-design.md` §8.2、§8.6。

**参考实现是 Android 版。** 每个任务都写了对应的 Kotlin 文件：行为、数值、文案以它为准，翻成惯用的 Swift / SwiftUI，不逐行照搬 Compose 写法。Kotlin 和视觉设计不一致时以视觉设计为准，并在提交说明里写一句。

## Global Constraints

- 计划 1 的全局约束继续有效：Bundle ID、iOS 17.2、只支持 iPhone、Swift 6、没有第三方依赖、不加 capability / entitlement、只在模拟器上构建；Mac 端行为不变（`swift test` 原有测试全过，已知在这台机器上失败的两个 Codex 发现测试除外；`make app` 照常构建）；文案逐字照抄 Android。
- **画面以草图为准**：颜色逐个取视觉设计 §5 的值（浅色、深色、看板三套），像素材质按 §4（台阶：卡片 4、按钮和输入框 3、小标签 2、大面板 5、弹层顶部 6；底边：卡片和按钮 4、小部件 2–3，按下收成 1 并整体下沉 3；高光三格只放在有颜色的面上），dp 按 1:1 换成 pt，排版基准 iPhone 17 Pro（402×874 pt）。
- **字体**：Silkscreen（Regular、Bold）用于时钟、百分比、数量、配对码这类数字，"%" 用 Nunito；Nunito 用于英文和数字正文、标题；中文跟随系统；命令和路径用系统等宽字体。字体文件只有一份：`android/app/src/main/res/font/` 下的三个 `.ttf`。
- **内置形象和声音只有一份**：仓库根目录的 `Skins/`、`Sounds/`，打包时原样进 App（文件夹引用），不复制进 `ios/`。
- **动效**（视觉设计 §7）：小部件按 60 ms 一格跳（开关 3 格 180 ms，按钮 70 ms 一步到位）；弹层、列表重排用弹簧；**不做任何无限循环的界面动画**（`repeatForever`、常驻 `CADisplayLink`、`TimelineView(.animation)` 都不许用），持续在动的只有宠物。减少动态效果时，界面过渡退成 150 ms 淡入淡出，宠物停在代表姿势。
- **减少动态效果** = 系统的"减少动态效果"（`UIAccessibility.isReduceMotionEnabled`，会随时变）或 App 设置里的开关，任一打开就算。
- **省电**（spec §9）：宠物时钟按 `ticksUntilChange` 醒来，宠物视图不在窗口里、App 不在前台时停掉；钟表文字用 `TimelineView(.everyMinute)`；重力最多 10 Hz，只在充电、App 在前台、开着自动打开时读；常亮和亮度只在看板显示时改，离开看板就还原。
- 不用 Claude 的品牌色 `#D97757`、不用 ✻、不用 Clawd 形象。
- 触控目标不小于 44 pt；正文对比度不低于 4.5:1。
- **只用命令行操作模拟器**：`xcrun simctl`（`launch`、`io screenshot`、`ui appearance`、`status_bar`、`terminate`）。不许用 `osascript`、辅助功能脚本、DeviceHub 或任何驱动窗口的办法（计划 1 里出过一次，会弹系统授权框）。模拟器是 iPhone 17 Pro · iOS 27.0，UDID `CEE21FEB-932A-4463-92C6-5BE5A48E0584`。
- 每个新画面、新状态都要有 DEBUG 启动参数能直接打开，方便截图（沿用 `ios/Critter/Debug/DebugLaunch.swift` 的写法，并在它的文件注释里补上说明）。
- 截图和临时文件放 `ios/build/`（已被忽略），不进仓库。

## Review Focus

1. **会话很多（9 个以上）。** 首页草地放最急的 5 只，其余合成一堆；看板先缩小到每格 3 pt，再把放不下的合成一堆；名字标签不能叠在一起。由 Task 3 的 `boardLayoutPilesWhatDoesNotFit`、`flockMergesPastTheThreshold`，Task 4 的 `labelRoom*` 四个测试，以及 Task 10、15 的 `many` 截图覆盖。
2. **手机上没有的形象**（Mac 上的自定义形象还没下载到、清单是坏的、名字里带 `/` 或 `..`）。先画小芽，Mac 发来清单后只换这一只；坏的清单一直用小芽；永远不崩。由 Task 3 的 `unknownSkinShowsSprigUntilTheMacSendsIt`、`aBrokenPushedSkinStaysSprig`、`pathLikeNamesAreNeverLookedUp` 覆盖。
3. **离开看板的每一种方式**（点关闭、拔电 10 秒、竖起来 3 秒、退到后台、App 被系统结束前）都把屏幕亮度和自动锁屏还原。由 Task 3 的 `everyWayOutRestoresTheScreen` 覆盖，Task 15 只做接线。
4. **宠物全都睡着、或者 App 在后台时，不能一直重画。** 由 Task 8 的帧计数检查覆盖（`-critterFrameLog`，全睡着时 30 秒内几乎不增加，退到后台后不增加）。
5. **离线时的首页和看板**：天黑、宠物灰着睡、数据变淡、作答按钮变灰并写"连上后才能作答"。由 Task 10 的 `offline` 截图和 Task 4 的 `inlineAnswerNeedsConnection` 覆盖。

## 执行分批

| 批次 | 任务 | 验证方式 |
|---|---|---|
| A 共享代码与纯逻辑 | 1–5 | `swift test` |
| B iOS 地基 | 6–8 | `make ios-sim` + 截图 |
| C 首页与弹层 | 9–12 | 同上 |
| D 配对与设置 | 13–14 | 同上 |
| E 看板 | 15–17 | 同上 |
| 收尾 | 18 | 截图走查、联机、文档 |

---

## 文件结构

```
Sources/CritterKit/
  Render/SpriteAtlas.swift Render/CritterSpriteLayer.swift Render/MotionClock.swift   从 Sources/CritterApp/ 移入（Task 1）
  SoundTrigger.swift                         从 CritterCore 移入（Task 1）
  Motion/MotionCues.swift                    新：抬头看你、跳一下（Task 1）
  Motion/MotionActor+Interaction.swift       改：carry、walkHome（Task 1）
  Board/BoardTrigger.swift                   新（Task 2）
Sources/CritterClient/
  Skins/PhoneSkinLibrary.swift               手机上的形象解析（Task 3）
  Flock/PhoneFlock.swift                     合并还是展开（Task 3）
  Board/BoardLayout.swift Board/ProBoardCards.swift Board/BoardScreen.swift   看板的排位、专业卡片、亮度与防烧屏（Task 3）
  Look/Sky.swift Look/PixelOutline.swift Look/PixelIcons.swift Look/Wordmark.swift
  Look/Meters.swift Look/LabelRoom.swift Look/HomeMoon.swift                    （Task 4）
  Presentation/SayFeedback.swift Presentation/HomeRules.swift                  （Task 4）
  BridgeClient.swift Store/BridgeStore.swift Store/StoreProtocols.swift         改：网络变化、立即重连、心跳间隔、取形象（Task 5）
  NetworkWatcher.swift                       新：NWPathMonitor 包装（Task 5）
Tests/CritterKitTests/{MotionCues,MotionCarry,BoardTrigger}Tests.swift
Tests/CritterClientTests/{PhoneSkinLibrary,PhoneFlock,BoardLayout,ProBoardCards,BoardScreen,Sky,PixelLook,LabelRoom,HomeMoon,SayFeedback,HomeRules}Tests.swift
ios/Critter/
  Look/Theme.swift Look/Fonts.swift Look/PixelShape.swift Look/PixelSurface.swift
  Look/Parts.swift Look/PixelIconView.swift Look/WordmarkView.swift           像素部件（Task 6、7）
  Critter/CritterStageView.swift Critter/CritterStage.swift Critter/Portraits.swift
  Critter/SkinStore.swift Platform/PhoneSettings.swift Platform/OrientationLock.swift   （Task 6、8）
  Meadow/MeadowBackdrop.swift Meadow/Meadow.swift Meadow/LonePet.swift          （Task 9）
  Home/* Answer/* Detail/* Pairing/* Settings/*                                 按新部件重写（Task 10–14）
  Sheet/SheetShell.swift                                                         （Task 11）
  Board/BoardView.swift Board/CritterBoard.swift Board/ProBoard.swift
  Board/BoardChrome.swift Board/BoardSounds.swift Board/BoardAutoOpen.swift     （Task 15–17）
  Debug/Gallery.swift Debug/Fixtures/{many,offline-idle,board}.json             只在 DEBUG 下
  Assets.xcassets/AppIcon.appiconset Assets.xcassets/LaunchSky.colorset         （Task 6）
ios/Critter.xcodeproj                        改：文件夹引用 Skins/、Sounds/，字体文件引用
ios/Config/Info.plist                        改：UIAppFonts、横屏、启动画面
scripts/dev/render-mockups.sh                新：把草图渲染成分块 PNG（Task 6）
scripts/dev/make-ios-icon.py                 新：从 Skins/sprig 画出 1024 px 图标（Task 6）
```

---

## 批次 A：共享代码与纯逻辑

### Task 1: 渲染移进 `CritterKit`，补动作片段和拖走后走回

**Files:**
- Move（`git mv`，内容只改 import 和访问级别）：`Sources/CritterApp/{SpriteAtlas,CritterSpriteLayer,MotionClock}.swift` → `Sources/CritterKit/Render/`；`Sources/CritterCore/SoundTrigger.swift` → `Sources/CritterKit/SoundTrigger.swift`
- Create: `Sources/CritterKit/Motion/MotionCues.swift`
- Modify: `Sources/CritterKit/Motion/MotionActor+Interaction.swift`
- Test: `Tests/CritterKitTests/MotionCuesTests.swift`、`Tests/CritterKitTests/MotionCarryTests.swift`

**参考：** `android/core/src/main/kotlin/local/critter/core/motion/MotionCues.kt`、`MotionActorInteraction.kt` 的 `carry`、`walkHome`；测试 `android/core/src/test/kotlin/local/critter/core/motion/MotionCuesTest.kt`、`MotionCarryTest.kt`。

**Interfaces:**
- Produces（全部 `public`）：
  - `SpriteAtlas(skin:dimStrength:)`、`pose(_:dim:)`、`glyph(_:color:)`、`glyphSize(_:)`；
  - `CritterSpriteLayer(atlas:unit:)`、`groundOrigin`、`seatRow`、`needsRender(_:)`、`render(_:)`。坐标仍是 y 朝上（Mac 的视图不翻转），iOS 的宿主视图负责翻转（Task 8）；
  - `@MainActor MotionClock(tickMs:)`、`onTick`、`isRunning`、`start()`、`stop()`、`catchUp()`、`poke()`；
  - `SoundTrigger.enteredAlertStates(old:new:)`（不变）；
  - `MotionCues.lookAtYou(_ skin: SkinManifest) -> MotionClip`、`MotionCues.hop(_:) -> MotionClip`、`MotionCues.hopMs(_:) -> Int`；
  - `MotionActor.carry(dxCells: Double)`、`MotionActor.walkHome()`。

- [ ] **Step 1: 记下基线。** Run: `swift test 2>&1 | tail -3`。Expected: 记下测试数 N 和失败的那两个 Codex 测试的名字。
- [ ] **Step 2: 移文件。** 三个渲染文件和 `SoundTrigger` 移过去，把类型和用到的成员改成 `public`，`import CritterCore` 改成 `import CritterKit`。`CritterApp` 里用到它们的地方不用改（`CritterCore` 已经 `@_exported import CritterKit`）。
- [ ] **Step 3: 翻测试。** 把 `MotionCuesTest.kt`、`MotionCarryTest.kt` 的每个测试翻成 Swift Testing，名字照抄（驼峰）。至少包括：`lookAtYou` 是 `clips[interactions.notice]` 后接 `[lookUp, 12] [blinkPose, 2] [lookUp, 10] [lookCenter, 2]`；`hop` 是四格 `hop`（dy 2、4、3、1）加 `land` 2 拍带 `landDust`；`carry` 后快照的横向偏移等于给的格数；`walkHome` 后一拍走 1 格，离家超过 6 格时一拍 2 格，到家停下并眨一下眼；减少动态效果时下一拍就到家。
- [ ] **Step 4: Run** `swift test --filter 'MotionCues|MotionCarry' 2>&1 | tail -3`。Expected: FAIL（`MotionCues` 未定义）。
- [ ] **Step 5: 实现** `MotionCues` 和 `carry` / `walkHome`，照 Kotlin。
- [ ] **Step 6: Run** `swift test 2>&1 | tail -3`。Expected: 只有基线里那两个 Codex 测试失败，总数 = N + 新测试数。
- [ ] **Step 7: Run** `xcodebuild -scheme CritterKit -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build -quiet && make app`。Expected: 两个都成功。
- [ ] **Step 8: Commit** `git commit -m "refactor(kit): sprite rendering and the motion clock move to CritterKit; look-at-you, hop, carry and walk home"`

### Task 2: 看板自动打开的规则 `BoardTrigger`

**Files:**
- Create: `Sources/CritterKit/Board/BoardTrigger.swift`
- Test: `Tests/CritterKitTests/BoardTriggerTests.swift`

**参考：** `android/core/src/main/kotlin/local/critter/core/board/BoardTrigger.kt` 和 `android/core/src/test/kotlin/local/critter/core/board/BoardTriggerTest.kt`（31 个测试）。

**Interfaces:**
- Produces: `public final class BoardTrigger`，`init(holdMs: Int64 = 3_000, unplugExitMs: Int64 = 10_000, uprightExitMs: Int64 = 3_000, openTimeoutMs: Int64 = 2_000)`；`enum Action { case open, close, blocked, none }`；`enum Pose { case landscape, upright, other }`；`var autoOpen`、`var awaitingOpen`、`var sensorWanted`；`onPower(charging:nowMs:)`、`onScreen(on:nowMs:)`、`onOrientation(pose:still:nowMs:stillSinceMs:)`、`onGravity(x:y:z:nowMs:)`、`onSensorStarted()`、`onTick(nowMs:)`、`onManualExit(nowMs:)`、`onOpenFailed()`、`onBoardShown(_:)`、`nextDeadline() -> Int64?`。时间是单调毫秒。

逐行翻，规则一条不改。`blocked` 在 iOS 上不会出现（App 在前台时看板总能打开），但照样翻过来，测试照样过，好和 Android 对照。

- [ ] **Step 1: 翻 31 个测试**，名字照抄。
- [ ] **Step 2: Run** `swift test --filter BoardTrigger`。Expected: FAIL（未定义）。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** `swift test --filter BoardTrigger 2>&1 | tail -3`。Expected: 31 个通过。
- [ ] **Step 5: Commit** `git commit -m "feat(kit): BoardTrigger, ported from Android"`

### Task 3: 手机上的形象、合群和看板逻辑

**Files:**
- Create: `Sources/CritterClient/Skins/PhoneSkinLibrary.swift`、`Sources/CritterClient/Flock/PhoneFlock.swift`、`Sources/CritterClient/Board/{BoardLayout,ProBoardCards,BoardScreen}.swift`
- Test: `Tests/CritterClientTests/{PhoneSkinLibrary,PhoneFlock,BoardLayout,ProBoardCards,BoardScreen}Tests.swift`

**参考：**
- `android/core/.../skin/SkinLibrary.kt`、`android/app/.../critter/SkinStore.kt`（只取纯逻辑）、测试 `SkinLibraryTest.kt`；
- `android/core/.../flock/FlockModel.kt`、`FlockModelTest.kt`（Mac 的 `FlockModel` 用的是 `PetSession`，手机上要一份用 `BridgeSession` 的）；
- `android/core/.../board/BoardLayout.kt`、`BoardLayoutTest.kt`；
- `android/app/.../ui/board/ProBoard.kt` 里决定卡片排法和请求怎么答的部分、`ProBoardTest.kt`；
- `android/app/.../ui/board/BoardChrome.kt`、`BoardActivity.kt` 里的变暗、防烧屏、时钟文字，测试 `BoardChromeTest.kt`。

**Interfaces:**
- `PhoneSkinLibrary(bundled: (String) -> SkinManifest?, pushed: [String: Data], forced: String?, clockSkin: String?, reuse: PhoneSkinLibrary?)`；`manifest(_ name: String) -> SkinManifest`；`static let fallback = "sprig"`。规则同 Kotlin：`forced` 优先；先找 Mac 发来的、再找内置的；找不到或解码失败用小芽；名字为空或带 `/`、`\`、`.` 的一律不查；和 `clockSkin` 的 tick 不同的形象不能和它同排（Kotlin 里的做法照搬）；重建时没变的清单直接沿用上一份（Swift 里比较 `Data` 是否相同）。另加 `needsFetch(_ name: String) -> Bool`：既不是内置、也还没收到、名字合法 → 应该向 Mac 要。
- `PhoneFlock.present(_ sessions: [BridgeSession], threshold: Int, override: FlockOverride?) -> PhoneFlockPresentation`、`merged(_:)`、`mostUrgent(_:)`，照 Kotlin。`FlockOverride`、`StateCount` 已在 `CritterCore`；手机上要用就把这两个移进 `CritterKit`（`git mv` 到 `Sources/CritterKit/FlockValues.swift`，Mac 端不受影响），`PhoneFlockPresentation` 在 `CritterClient` 新建。
- `BoardLayout.place(count:width:height:) -> BoardLayout.Layout`、`placeRow(...)`，`Layout(scale: CGFloat, slots: [CGPoint], pileFrom: Int?)`，常量照 Kotlin（每排最多 6 只、每格 6 到 3 pt、宽 18 格、间隔 4 格、边距 24）。
- `ProBoardCards.arrange(_ body: SnapshotBody?) -> [ProBoardCard]`：每张卡对应一个会话或一个请求，带所在列、占几行、能不能直接答（只有一个权限请求时直接答，多个时显示最早的、点开卡片；提问和计划总是打开卡片）。字段名照 Kotlin 的意思起。
- `BoardScreen`（看板的屏幕策略，纯值类型）：
  - `brightness(base: Double, idleSince: Date?, lastTouch: Date?, now: Date) -> Double`：15 分钟没人碰、状态也没变时降到 base 的 60%，永远不到 0（Kotlin 的下限照搬）；
  - `shift(seed:) -> CGSize`：防烧屏位移，每 3 分钟换一次，横竖都在 ±4 pt 内；
  - `clockText(_:)`、`dateText(_:)`：读法同草图（`clockAndDateReadLikeTheMockup`）；
  - `enum Exit { case closeButton, unplugged, upright, background, terminated }`，`restore(saved: ScreenState, on exit: Exit) -> ScreenState`：每一种都回到进看板前保存的亮度，并关掉常亮。`ScreenState(brightness: Double, idleTimerDisabled: Bool)`。

- [ ] **Step 1: 翻测试。** `SkinLibraryTest`（3 个）、`FlockModelTest`（6 个）、`BoardLayoutTest`（12 个）、`ProBoardTest`（6 个）、`BoardChromeTest`（5 个）逐个翻，名字照抄。再加：
  - `unknownSkinShowsSprigUntilTheMacSendsIt`：`manifest("custom")` 先是小芽、`needsFetch("custom")` 为真；带上 `pushed["custom"]` 重建后是 custom、`needsFetch` 为假；
  - `aBrokenPushedSkinStaysSprig`：`pushed["bad"] = Data("{".utf8)` → 小芽，不崩；
  - `pathLikeNamesAreNeverLookedUp`：`"../x"`、`"a/b"`、`""` 都不调 `bundled`，`needsFetch` 为假；
  - `boardLayoutPilesWhatDoesNotFit`：12 个会话在 874×402 上，`scale` 是 3，`pileFrom` 不为 nil，每个槽位不重叠；
  - `everyWayOutRestoresTheScreen`：五种 `Exit` 都还原成保存的亮度、`idleTimerDisabled == false`。
- [ ] **Step 2: Run** `swift test --filter 'PhoneSkinLibrary|PhoneFlock|BoardLayout|ProBoardCards|BoardScreen'`。Expected: FAIL（未定义）。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上。Expected: 全部通过；再跑一遍完整的 `swift test`，只有那两个 Codex 测试失败。
- [ ] **Step 5: Commit** `git commit -m "feat(client): skins, the flock and the board's layout and screen rules for the phone"`

### Task 4: 界面的纯逻辑

**Files:**
- Create: `Sources/CritterClient/Look/{Sky,PixelOutline,PixelIcons,Wordmark,Meters,LabelRoom,HomeMoon}.swift`、`Sources/CritterClient/Presentation/{SayFeedback,HomeRules}.swift`
- Test: `Tests/CritterClientTests/{Sky,PixelLook,LabelRoom,HomeMoon,SayFeedback,HomeRules}Tests.swift`

**参考：** `android/app/src/main/kotlin/local/critter/phone/ui/look/`（`Sky.kt`、`PixelOutline.kt`、`PixelIcons.kt`、`Wordmark.kt`、`Meters.kt`、`Stepped.kt`、`LabelRoom.kt`）、`ui/home/HomeList.kt`、`ui/detail/LetterFlight.kt`、`ui/SessionUi.kt` 里发一句的反馈；测试 `android/app/src/test/kotlin/local/critter/phone/` 下的 `SkyTest`、`PixelLookTest`、`LabelRoomTest`、`HomeMoonTest`、`SayFeedbackTest`、`HomeListTest`。

**Interfaces:**（名字照 Kotlin，改成 Swift 惯用写法；颜色用 `UInt32` 的 0xRRGGBB，不依赖 SwiftUI）
- `SkyTime { dawn, day, dusk, night }`、`SkyTime.at(hour:)`（6–10 清晨、10–17 白天、17–20 黄昏、其余夜里）、`SkyColors.of(_:)`、`meadowCells(width:height:ground:cell:time:seed:) -> [MeadowCell]`；
- `PixelOutline.points(width:height:step:topOnly:) -> [CGPoint]`（20 个点，顺时针；台阶不超过短边的四分之一）；
- `PixelIcons.rows(_ icon: PixelIcon) -> [String]`，`PixelIcon` 列出视觉设计 §6 的全部图标和五个状态符号；`PixelIcons.runs(_:)`（每个像素恰好覆盖一次的横向连续段，画的时候用）；
- `Wordmark.rows`（42×9）；
- `Meters.litSegments(fraction:count:)`、`Meters.level(percent:)`（< 60 绿、60–85 金、≥ 85 红）、`Stepped.fraction(_:)`（按三分之一走）；
- `LabelRoom.rooms(centers:natural:width:taken:) -> [CGFloat]`；
- `HomeMoon.position(...)`（照 Kotlin 的参数）；
- `SayFeedback.text(for: CommandResult, isInterrupt: Bool) -> String`、`LetterFlight.path(from:to:steps: 7) -> [CGPoint]`；
- `HomeRules.inlineAnswerEnabled(kind:canAct:)`、`HomeRules.shouldPlayOpening(lastShownDay:today:)`（冷启动钻出来一天只放一次）。

- [ ] **Step 1: 翻测试**（上面六个文件，名字照抄），加上 `inlineAnswerNeedsConnection`（`canAct` 为假时首页的「允许」「拒绝」不可用）。
- [ ] **Step 2: Run** `swift test --filter 'Sky|PixelLook|LabelRoom|HomeMoon|SayFeedback|HomeRules'`。Expected: FAIL。
- [ ] **Step 3: 实现。** 图标和 Logo 的行数据从 Kotlin 原样复制。
- [ ] **Step 4: Run** 同上。Expected: 全部通过。
- [ ] **Step 5: Commit** `git commit -m "feat(client): sky, pixel outlines, icons, meters and label room for the phone UI"`

### Task 5: 连接的三处补丁，向 Mac 要形象

**Files:**
- Create: `Sources/CritterClient/NetworkWatcher.swift`
- Modify: `Sources/CritterClient/BridgeClient.swift`、`Sources/CritterClient/Store/{BridgeStore,StoreProtocols}.swift`
- Test: `Tests/CritterClientTests/BridgeClientTests.swift`、`Tests/CritterClientTests/BridgeStoreTests.swift`

台账"计划 2"组的前三条（`docs/critter-ios-backlog.md`）：

**Interfaces:**
- `BridgeClient.reconnectNow()`：已连上时什么都不做（不推进退避、不发 `offline`）；在退避等待中时立刻连一次，退避级数不变。
- `BridgeClient.setPingInterval(_ seconds: TimeInterval)`：运行中改心跳，下一次心跳按新间隔排；pong 的期限跟着变。
- `protocol NetworkWatching: Sendable { func changes() -> AsyncStream<Void> }`；`NWPathNetworkWatcher`（`NWPathMonitor`，只在路径变成 `.satisfied` 且和上一次不同时发一次）。`BridgeStore` 在前台时收到变化就 `reconnectNow()`，后台时忽略。
- `BridgeStore.boardOpen: Bool`（看板开着时设为真，心跳 30 秒；关掉回到 60 秒）。
- `BridgeStore.requestSkin(_ name: String) async -> Data?`：转给连接的 `requestSkin`，把 `JSONValue` 编成 `Data` 返回；不在线时返回 nil。`BridgeLink` 协议加对应方法，测试用的假连接一起改。

- [ ] **Step 1: 写测试**：`reconnectNowWhileConnectedChangesNothing`（不重连、`conn` 不闪 `offline`、退避级数不变）、`reconnectNowWhileWaitingConnectsAtOnce`、`pingIntervalCanChangeWhileRunning`（30 秒的间隔下 31 秒内收到一次 ping）、`aNetworkChangeInTheForegroundReconnects`、`aNetworkChangeInTheBackgroundIsIgnored`、`boardOpenSetsThePingTo30Seconds`、`requestSkinReturnsTheManifestBytes`。用计划 1 的 `FakeMac` 和可控时钟。
- [ ] **Step 2: Run** `swift test --filter 'BridgeClient|BridgeStore'`。Expected: 新测试 FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** `swift test --filter 'BridgeClient|BridgeStore' 2>&1 | tail -3`。Expected: 全部通过；完整 `swift test` 只有那两个 Codex 测试失败。
- [ ] **Step 5:** 在 `docs/critter-ios-backlog.md` 里删掉做完的三条。
- [ ] **Step 6: Commit** `git commit -m "fix(client): reconnect on network changes, reconnectNow keeps the backoff, ping interval at runtime"`

---

## 批次 B：iOS 地基

### Task 6: 资源、颜色、字体、方向、图标和启动画面

**Files:**
- Modify: `ios/Critter.xcodeproj/project.pbxproj`（文件夹引用 `../Skins`、`../Sounds`；三个字体文件的引用，路径指向 `../android/app/src/main/res/font/`；都进 App target 的 Copy Bundle Resources）、`ios/Config/Info.plist`
- Create: `ios/Critter/Look/{Theme,Fonts}.swift`、`ios/Critter/Platform/OrientationLock.swift`、`ios/Critter/Assets.xcassets/`（`AppIcon.appiconset` 三张 1024 px，`LaunchSky.colorset`，`LaunchIcon.imageset`）、`scripts/dev/render-mockups.sh`、`scripts/dev/make-ios-icon.py`
- Modify: `ios/Critter/CritterApp.swift`

**参考：** `android/app/.../ui/theme/Theme.kt`、`BoardColors.kt`、`ui/SessionUi.kt`（状态的颜色和符号）；视觉设计 §5、§6、§8.1；`android/app/src/main/res/drawable/` 下图标的前景和背景。

内容：
- **`render-mockups.sh [输出目录]`**：用 `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --headless=new --hide-scrollbars --virtual-time-budget=3000 --window-size=1400,19000 --user-data-dir=<临时目录> --screenshot=...` 渲染整页草图（按锚点截图会是空白，所以截整页），再用 `sips` 切成 1400×1500 的块，文件名 `mockup-01.png`…。默认输出 `ios/build/mockups/`。后面每个画面任务都用它对照。
- **`Theme`**：视觉设计 §5 全部颜色做成 `Color` 常量，浅色、深色两套（跟系统外观切换），看板一套固定。状态颜色（字、底、符号、描边）按 `PetState` 取。连接状态的颜色和"已在电脑上处理"、Mac 名字的兜底这些在几个视图里各写了一份的，收到这里（台账"前端优化轮"最后一条）。
- **`Fonts`**：`Font.silkscreen(size:bold:)`、`Font.nunito(size:weight:)`，以及 `UIFont` 版本。Info.plist 的 `UIAppFonts` 写三个文件名。
- **方向**：Info.plist 支持竖屏和两个横屏；`OrientationLock`（`@MainActor @Observable`，`mask` 默认竖屏）配 `UIApplicationDelegateAdaptor` 的 `application(_:supportedInterfaceOrientationsFor:)`；`lock(_ mask:)` 改 `mask` 后调 `windowScene.requestGeometryUpdate(.iOS(interfaceOrientations:))`。看板（Task 15）打开时锁横屏，关掉时回竖屏。
- **图标**：`make-ios-icon.py`（python3 + Pillow）读 `Skins/sprig/manifest.json` 的 `base` 姿势和调色板，按视觉设计 §8.1 的排法画 1024 px（36×36 格：清晨天空三段加一行抖动、底部草地，小芽左上角在格子 (9, 13)、脚踩第 23 行），另出深色变体（夜里天空）和着色变体（灰度轮廓，眼睛挖空），写进 `AppIcon.appiconset`（`appearances` 写 `luminosity: dark` / `tinted`）。PNG 进仓库，脚本也进仓库。
- **启动画面**：Info.plist `UILaunchScreen` 用 `LaunchSky`（清晨天空中间那一档 `#DDF0FF`）和居中的 `LaunchIcon`（图标那张图）。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `scripts/dev/render-mockups.sh && ls ios/build/mockups | wc -l`。Expected: 13 块左右，打开第一块能看到草图标题。
- [ ] **Step 3: Run** `make ios-sim`。Expected: BUILD SUCCEEDED；`ios/build/Build/Products/Debug-iphonesimulator/Critter.app` 里有 `Skins/sprig/manifest.json`、`Sounds/`、三个 `.ttf`。
- [ ] **Step 4: 截图检查：** 装好后 `xcrun simctl launch` 截一张启动画面附近的图，再用 `xcrun simctl io <UDID> screenshot` 截主屏幕看图标（`xcrun simctl terminate` 后回主屏幕）。Expected: 图标是天空、草地和小芽；深色外观下是夜空版本。
- [ ] **Step 5: Commit** `git commit -m "feat(ios): colors, fonts, bundled skins and sounds, orientation lock, app icon and launch screen"`

### Task 7: 像素部件和部件陈列页

**Files:**
- Create: `ios/Critter/Look/{PixelShape,PixelSurface,Parts,PixelIconView,WordmarkView}.swift`、`ios/Critter/Debug/Gallery.swift`
- Modify: `ios/Critter/Debug/DebugLaunch.swift`

**参考：** `android/app/.../ui/theme/{PixelShape,PixelChrome,PixelIcon,Components,WordmarkImage}.kt`；草图的"部件""像素图标""动效"几节；视觉设计 §4、§6、§7。

**Interfaces:**
- `PixelShape(step: CGFloat, topOnly: Bool = false): Shape`（用 `PixelOutline.points`）；
- `.pixelSurface(fill:lip:step:lipHeight:highlight:inset:)`（底边深一档；`inset` 时深色在顶部；高光三格）；`.pixelOutline(color:width:step:)`（两层做法：外层填描边色、内层缩进）；
- 部件：`PixelButton(title:role:style:action:)`（主要、次要、警示、文字；按下下沉 3 pt、底边 4→1，70 ms；禁用样子）、`StateTag(state:)`（换状态时上跳一格 60 ms）、`PixelToggle(isOn:)`（圆头 18 pt，3 格 180 ms）、`PixelSegmented`、`PixelSlider(value:)`（10 小格，滑块头是小太阳）、`SegmentMeter(fraction:segments:)`（颜色按 `Meters.level`）、`PixelTextField`（凹进去）、`OptionCard`（单选圆点、多选方框，选中淡紫底加描边；虚线版"自己写一句…"）、`CommandSlip(text:maxLines:)`（深色纸条、等宽）、`PixelIconView(_ icon: PixelIcon, cell: CGFloat = 2)`（跟文字颜色）、`WordmarkView(cell:)`（`i` 上的点是两片嫩芽 `#6BCB5F` / `#3F9442`，字下面一格浅阴影）。
- 动效全部有头有尾；减少动态效果时按钮、开关、标签直接到终态。
- `-critterGallery`：一个滚动页，按草图"部件"那一节的顺序摆出所有部件的各种状态，再列出全部像素图标和 Logo。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照：** `-critterGallery` 浅色、深色各一张，和 `render-mockups.sh` 里"部件""像素图标"所在的块并排用 Read 看。Expected: 台阶、底边、高光、颜色、图标和草图一致；"2"和"8"分得清。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): pixel parts, icons, wordmark and a debug gallery"`

### Task 8: 宠物舞台、静止头像、形象和设置存储

**Files:**
- Create: `ios/Critter/Critter/{CritterStageView,CritterStage,Portraits,SkinStore}.swift`、`ios/Critter/Platform/PhoneSettings.swift`
- Modify: `ios/Critter/CritterApp.swift`、`ios/Critter/Debug/{DebugLaunch,Gallery}.swift`

**参考：** `android/app/.../critter/{CritterView,CritterClock,Portraits,SkinStore,MotionPrefs,SessionTap,PileSlots}.kt`、`android/app/.../data/SettingsStore.kt`；Mac 端 `Sources/CritterApp/FlockView+Interaction.swift`（鼠标交互，阈值）。

**Interfaces:**
- `CritterSlot(sessionId:manifest:state:activity:dimStrength:origin:scale:seatRow:sleeping:)`，`origin` 是视图坐标里基准格第 0 列和地面的交点（y 朝下，和 Android 一样）。
- `final class CritterStageView: UIView`，对应 Android `CritterView`：`setActors(_:)`、`play(_:clip:)`、`notice(_:)`、`playClip(_:clip:delay:)`、`lookAtYou(_:)`、`hop(_:delay:)`、`sinkAll(stagger:onDone:)`、`riseAll(stagger:join:)`、`setPaused(_:)`；属性 `claimAllTouches`、`carryOnDrag`、`restingGaze`；`weak var delegate: CritterStageDelegate?`（`onTap`、`onLongDragEnd`、`onDragStart`、`onDragBy`、`onCarry`）。
  - 每只宠物一个 `CritterSpriteLayer`，放在一个 `isGeometryFlipped = true` 的容器层里，这样它的 y 朝上坐标和 Mac 一样；**截图确认宠物是正的、站在地上**（Step 3）。
  - 一个 `MotionClock`，tick 取第一只宠物的形象；`didMoveToWindow` 为 nil、`setPaused(true)`、App 不在前台时停，回来时恢复。
  - 触摸同 spec §8.2：按下 = 注意到你（睡着的醒，醒着的抬手）；移动超过 3 pt = 拎起来；轻点 = boop 加 `onTap`；来回蹭 = 摸摸（`RubDetector`）；手指在屏幕上时目光跟着手指（`MotionGaze`）。`carryOnDrag` 为真时（看板）拎起来横着跟手指走、松手 `drop` 再 `walkHome`。
  - DEBUG：`-critterFrameLog` 时每 10 秒往标准输出打一行"frames <n>"（`render` 真正改了画面的次数）。
- `CritterStage`（`UIViewRepresentable`）：SwiftUI 里用的包装，参数是 `[CritterSlot]` 和回调。
- `Portraits`：`@MainActor` 缓存，`image(skin:state:dim:scale:) -> UIImage?`，用减少动态效果模式下 `MotionActor` 的快照（代表姿势）加 `SkinRenderer.image` 画一次，按 (形象名, 状态, dim, scale) 缓存；最近点用 `.interpolation(.none)` 放大。
- `SkinStore`（`@MainActor @Observable`）：内置清单从 `Bundle.main` 的 `Skins/<name>/manifest.json` 读；Mac 发来的放内存，并存到 Application Support 的 `Skins/<name>.json`（下次启动先用它）；`library: PhoneSkinLibrary` 有新清单时重建；`fetchIfNeeded(names:store:)` 对 `needsFetch` 为真的名字向 `BridgeStore.requestSkin` 要，一个名字同时只要一次，失败了下一份快照再要；每份快照把 `prefs.skin` 设成 `clockSkin`（变了才重建），`prefs.idleDim` 就是各个 `CritterSlot` 的 `dimStrength`。
- `PhoneSettings`（`@MainActor @Observable`，`UserDefaults` 键前缀 `critter.settings.`）：`forcedSkin: String?`、`reduceMotion: Bool = false`、`boardAutoOpen: Bool = true`、`boardCritterMode: Bool = true`、`boardBrightness: Double = 0.3`、`boardSounds: Bool = false`、`openingShownOn: String?`（"yyyy-MM-dd"）。默认值照 Android `SettingsStore.kt`。推送那份计划会把它搬进 App Group，这里先用标准 `UserDefaults`。
- 减少动态效果：`PhoneSettings.reduceMotion || UIAccessibility.isReduceMotionEnabled`，监听 `UIAccessibility.reduceMotionStatusDidChangeNotification`。

- [ ] **Step 1: 实现。** 陈列页加一块：一排七个内置形象站在一小块草地上，可以点、拎、蹭；下面一排静止头像（五个状态各一个）。
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图：** `-critterGallery`。Expected: 宠物正着站在草地上，脚踩地面，阴影在脚下，头顶标记在头上；静止头像和会动的同一姿势一致。
- [ ] **Step 4: 帧计数：** `xcrun simctl launch --console-pty <UDID> com.braynlabs.critter -critterGallery -critterFrameLog` 跑 40 秒；再加一个 DEBUG 参数 `-critterAllAsleep`（陈列页的宠物全部 `sleepNow`）跑 40 秒；然后 `xcrun simctl launch` 一个系统 App（`com.apple.Preferences`）把 Critter 推到后台再等 20 秒。Expected: 全睡着时每 10 秒的帧数是个位数（打呼的 z 粒子），退到后台后不再有输出或帧数为 0。把输出贴进报告。
- [ ] **Step 5: Commit** `git commit -m "feat(ios): the critter stage, portraits, skins from the bundle and the Mac, phone settings"`

---

## 批次 C：首页与弹层

### Task 9: 天空、草地和草地上的一排宠物

**Files:**
- Create: `ios/Critter/Meadow/{MeadowBackdrop,Meadow,LonePet}.swift`

**参考：** `android/app/.../ui/meadow/{MeadowBackdrop,Meadow,PetStage,LonePet}.kt`、`ui/look/Sky.kt`；草图"首页""天空"两节；视觉设计 §8.3。

**Interfaces:**
- `MeadowBackdrop(time: SkyTime, size:)`：用 `meadowCells` 画成一张位图（尺寸或时间变了才重画），深色模式一律夜里，夜里有星星和月亮（`HomeMoon` 决定位置）。
- `Meadow(sessions:pending:skins:time:offline:onTap:)`：宠物 3 pt 一格、地平线在 200 pt；脚下白色名字标签（`LabelRoom` 让位）；等你确认的那只头顶橙色气泡"等你确认"；会话多于 5 个时放最急的 5 只，其余用 `PileSeating` 合成一堆，旁边是各状态数量；离线时天黑、宠物灰着睡。冷启动用 `riseAll`（`appear`，间隔 80 ms），按 `HomeRules.shouldPlayOpening` 一天只放一次。
- `LonePet(skin:state:sleeping:)`：一小块草地上一只宠物（空状态、作答卡片、详情里用）。
- 天空按手机时间整点换档：用 `TimelineView(.everyMinute)` 算 `SkyTime.at(hour:)`，档位没变就不重画。

- [ ] **Step 1: 实现**，陈列页加四档天空各一块草地。
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图的"天空跟着时间走"：加 DEBUG 参数 `-critterSkyHour <0-23>` 固定时间。Expected: 四档颜色、抖动、草、星月和草图一致。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the meadow, its sky and the critters on it"`

### Task 10: 首页

**Files:**
- Modify/Rewrite: `ios/Critter/Home/{HomeView,SessionRow,LimitsCards,RowRequest}.swift`
- Create: `ios/Critter/Debug/Fixtures/{many,offline-idle}.json`

**参考：** `android/app/.../ui/home/{HomeScreen,HomeList}.kt`、`ui/PlaceRow.kt`、`ui/MinuteClock.kt`；草图"首页"一节；视觉设计 §8.3。

内容（逻辑全部沿用计划 1 的 `BridgeStore`、`SessionText`、`SessionOrder`、`AnswerSubmit`，只换外观）：
- 上部草地 236 pt，天空铺到状态栏下面（`ignoresSafeArea(edges: .top)`）：左上 Mac 名和连接标签，右上两个图标按钮（看板、设置）。看板按钮这一任务先打开一个占位，Task 15 接上。
- 额度两张卡：左上名字、右上 Silkscreen 大数字、10 格分段条、重置时间。
- 会话卡片：左边 56 pt 的小草地格子（底色按状态）里是静止头像和头顶标记；右边名字 + 状态标签、在做什么、目录 · 分支 · 来源（小图标分隔）；底部"上下文"分格条和百分比。状态变化时卡片平滑挪位（减少动态效果时淡入淡出）。
- 等你确认的卡片：橙色 3 pt 描边、排第一，权限请求带命令纸条和「拒绝」「允许」；提问和计划是「打开回答」。
- 离线卡片、空状态（`LonePet` 睡着）、需要重新配对，照视觉设计 §8.3。
- 台账"前端优化轮"：首页那一行的回答还在途中时，从这一行打开的卡片要显示"正在提交…"并禁用按钮（不能没反应）；回答落地后，卡片写"已提交"，不写"已在电脑上处理"（结果来自这台手机）。

- [ ] **Step 1: 实现。** `many.json`：9 个会话（各状态都有，2 个等你确认的权限请求、1 个提问），`offline-idle.json`：4 个空闲会话；离线用已有的 DEBUG 机制让假连接只发快照、不发 `connected`（没有就加 `-critterFixtureOffline`）。
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图"首页"：`home-mixed`、`many`、`offline-idle -critterFixtureOffline`、`empty`，浅色深色各一套，再加 `-critterSkyHour 7`、`19` 各一张。Expected: 结构、颜色、字体、间距和草图一致；`many` 里草地上 5 只加一堆，名字不叠；离线的作答按钮变灰并写"连上后才能作答"。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the home screen in pixels, with the meadow"`

### Task 11: 弹层外壳和作答卡片

**Files:**
- Create: `ios/Critter/Sheet/SheetShell.swift`
- Modify/Rewrite: `ios/Critter/Answer/*.swift`

**参考：** `android/app/.../ui/sheet/SheetScaffold.kt`、`ui/answer/{AnswerSheet,MarkdownLite}.kt`；草图"作答"一节；视觉设计 §7、§8.6。

内容：
- `SheetShell`：顶部一块小草地格子（作答卡片 72×64，橙底，举手的宠物），弹层顶部 6 pt 台阶；打开带轻微过冲（300 ms），落稳后宠物 `lookAtYou`；关闭直接滑下（200 ms）；下拉关闭。减少动态效果时 150 ms 淡入淡出。用系统 `.sheet` 加自定义背景，还是自己画弹层，由实现者定，下拉关闭和键盘避让都要正常。
- 作答卡片照视觉设计 §8.6：权限（命令纸条最多约 8 行再滚动、「拒绝并写理由…」、「拒绝」「允许」，Codex 没有写理由）、提问（主题小标签、选项卡片、虚线"自己写一句…"、「提交 n 个回答」，只有一个单选题时点了就提交）、计划（凹进去的纸，可滚动，底部渐隐，「让它改…」「批准计划」）。
- 反馈照 §7：允许成功时按钮 3 格变绿、文字换成"✓ 已允许"，宠物切到 done 并播进场，900 ms 后关；拒绝时宠物 `notice`，直接关；已在电脑上处理：开着花的宠物、"已在电脑上处理"、2 秒后关；离线和失败的提示放同一位置。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图"作答"：`permission`、`question`、`plan` 三个 fixture 各开卡片；`-critterAutoSubmit allow` 在 0.5 秒和 1.2 秒各截一张；`-critterFixtureResult resolved -critterAutoSubmit allow`；`-critterReopen` 一次。浅色深色各一套。Expected: 和草图一致，计划 1 的作答行为不变（`swift test` 照常通过）。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the sheet shell and the answer cards in pixels"`

### Task 12: 会话详情和「发一句」

**Files:**
- Modify/Rewrite: `ios/Critter/Detail/DetailSheet.swift`

**参考：** `android/app/.../ui/detail/{DetailActivity,LetterFlight}.kt`；草图"详情""输入法"两节；视觉设计 §8.5。

内容：
- 顶部 150 pt 草地，宠物 4 pt 一格继续它的动作，旁边侧向气泡写在做什么；名字 + 状态标签；两列信息（目录、分支、来源、模型、上下文分格条、最后更新），每项一个小图标。
- 「发一句」输入框 + 发送按钮，下面小字说明；弹层跟着键盘升起。发送时像素信沿 `LetterFlight.path` 7 格飞到宠物头上（每格 60 ms），宠物 `notice` 后 `petEnd`，下面绿字"已送到"；失败显示 `SayFeedback.text`。发送途中输入的字保留。
- 台账"前端优化轮"：发一句和停止当前回合各有自己的"正在发送…"状态；输入框限制 4000 字（同 Android），超了显示一句说明而不是只把按钮变灰。
- `canStopTurn` 时显示「停止当前回合」。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图"详情"：`home-mixed -critterOpen detail:<Claude 会话>`、`detail:<Codex 会话>`（有「停止当前回合」），再加 DEBUG 参数 `-critterSayDraft <文字>` 预填输入框各截一张（含 4001 字的情况）。Expected: 和草图一致。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): session details and say in pixels, with the letter flight"`

---

## 批次 D：配对与设置

### Task 13: 配对画面

**Files:**
- Modify/Rewrite: `ios/Critter/Pairing/*.swift`、`ios/Critter/Platform/QRScannerView.swift`（只改取景框外观）

**参考：** `android/app/.../ui/pairing/{PairingScreen,QrScanner,ScanGuard}.kt`；草图"引导""扫码""配对码"几节；视觉设计 §8.2（不含欢迎页和种子进度）。

内容：
- 扫码：深色取景，四角像素直角，小芽在框下抬头（`lookUp`）；识别成功取景框闪绿、宠物跳一下。扫码说明照视觉设计 §8.2 的原文。
- 等 Mac 点允许：画出 Mac「添加手机」窗口里的那一行（"「手机型号」请求连接"和「拒绝」「允许」），允许按钮用橙色虚线圈出来，旁边小芽 `waiting`。
- 手动输入：找到的 Mac 列成卡片（选中的打"已选"标签），8 位码分 4+4 两组格子。
- 失败页：计划 1 的原因文案不变，换成新部件。
- 台账"前端优化轮"四条：确认框在大字号下能滚动（不用 `fixedSize`）；手动配对的证书探测任务要被跟踪，切换页面或重新开始时取消，晚到的结果丢掉；配对进行中收到的链接排队，当前这次失败或取消后再用它，成功则丢掉并不提示；失败页上"不在局域网"的提示要看得见。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照**：未配对启动（扫码页；模拟器没有相机，显示的是没有相机时的样子，照样要好看）、手动输入页（用计划 1 已有的 DEBUG 办法进各个状态，没有的补上）、等待批准、每种失败原因各一张，大字号（`xcrun simctl ui <UDID> content_size extra-extra-extra-large`）下的确认框一张。Expected: 和草图一致，大字号下能滚到按钮。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): pairing screens in pixels; fixes from the front-end backlog"`

### Task 14: 设置

**Files:**
- Modify/Rewrite: `ios/Critter/Settings/SettingsView.swift`

**参考：** `android/app/.../ui/settings/SettingsScreen.kt`；草图"设置""形象"两节；视觉设计 §8.8。

内容（这一轮只有下面三组加连接；推送、实时活动、提醒在推送那份计划）：
- 顶部连接卡片高度固定，状态变化只换文字和图标；「重新配对」「取消配对」。
- **形象**：一排小草地格子横向滚动，第一格"跟着电脑"（小电脑图标），然后七个内置形象，每格一只会动的宠物；选中的描主色边、右上角打勾，并播一次 done 的进场。写 `PhoneSettings.forcedSkin`，所有画面立刻换。
- **看板**：自动横屏打开（开关）、默认模式（宠物 / 专业）、亮度（10 小格滑块）、提示音（开关，默认关）。
- **动画与省电**：减少动态效果（开关，说明里写"系统的「减少动态效果」打开时也会生效"）。
- 每组标题前一个像素图标。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图"设置"：`-critterOpen settings` 浅色深色各一张；选一个形象后回首页一张（首页宠物全换成它）。Expected: 和草图一致。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): settings in pixels: skin, board and motion"`

---

## 批次 E：看板

### Task 15: 看板外壳和宠物模式

**Files:**
- Create: `ios/Critter/Board/{BoardView,CritterBoard,BoardChrome,BoardSounds}.swift`、`ios/Critter/Debug/Fixtures/board.json`
- Modify: `ios/Critter/Home/HomeView.swift`（看板按钮）

**参考：** `android/app/.../ui/board/{BoardActivity,BoardChrome,BoardLook}.kt`、`board/{CritterBoard,BoardSounds}.kt`；草图"看板"几节；视觉设计 §5（看板颜色）、§8.7；Android 设计 §8.6。

内容：
- `BoardView`：全屏盖住首页（`fullScreenCover`），打开时 `OrientationLock` 锁横屏、隐藏状态栏和主屏指示条（`persistentSystemOverlays(.hidden)`）、纯黑背景；`BridgeStore.boardOpen = true`。屏幕：进来前保存亮度和常亮，设亮度为 `PhoneSettings.boardBrightness`、开常亮；按 `BoardScreen.brightness` 15 分钟没人碰再暗一档；每 3 分钟按 `BoardScreen.shift` 挪画面；任何一种离开（`BoardScreen.Exit`）都按 `BoardScreen.restore` 还原，退到后台也还原、回前台再设。右上模式切换按钮，记住选的模式；关闭按钮。
- 宠物模式（`CritterBoard`）：宠物 6 pt 一格（多了按 `BoardLayout` 缩小、合并）；2 pt 地平线 `#1A1630`、稀疏暗草；名字、目录 · 分支在地平线下，再下面 3 pt 的上下文分格条；左上 Silkscreen 时钟和日期（`TimelineView(.everyMinute)`），右上 5h / 7d 两条分格额度；运行中和等你确认的宠物头上深色气泡，等你确认的橙色描边，写"想运行 xxx / 点我回答"；空闲、做完的宠物 dim。
- 拖动：`carryOnDrag`，拎起来横着跟手指走（不出看板）、其他宠物不动；松手 `drop` 后 `walkHome`；名字标签留在原位，宠物离家时它的气泡藏起来；减少动态效果时直接回原位。轻点是 boop，点等你确认的那只打开作答卡片（横屏下照样能答）。
- 提示音：`PhoneSettings.boardSounds` 打开时，`SoundTrigger.enteredAlertStates` 有结果就放 `Sounds/<主题>/<状态>.wav` 里最急的那个；主题用快照里 Mac 的 `prefs.soundTheme`；音频会话 `.ambient`（静音键生效、不打断别的 App 的声音）。参考 `BoardSounds.kt`。
- DEBUG：`-critterBoard critter|pro` 启动后直接打开看板；`board.json`：6 个会话，一个等你确认。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照** 草图"看板"：`board -critterBoard critter`、`many -critterBoard critter`（缩小加合并，名字不叠）。用 `xcrun simctl io` 截的图是横的。Expected: 和草图一致。
- [ ] **Step 4: 还原检查**：加 DEBUG 参数 `-critterBoardLog`，每次改亮度和常亮都打一行；开看板、点关闭、再开、退到后台、回来、关掉，各一次。Expected: 每次离开都打出还原成进来前的亮度和"idle timer off"。
- [ ] **Step 5: Commit** `git commit -m "feat(ios): the landscape board and its critter mode"`

### Task 16: 专业看板

**Files:**
- Create: `ios/Critter/Board/ProBoard.swift`

**参考：** `android/app/.../ui/board/ProBoard.kt`；草图"专业看板"一节；视觉设计 §8.7。

内容：左栏时钟、日期、两张额度卡（20 格分段条）；右边两列卡片（按 `ProBoardCards.arrange`），左上是这只会话的静止头像（dim；等你确认的不 dim），等你确认的卡片占两行，带命令纸条和「拒绝」「允许」（只有一个权限请求时；多个时显示最早的、点开卡片），提问和计划点开卡片；会话多时右边上下滑。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图对照**：`board -critterBoard pro`、`many -critterBoard pro`。Expected: 和草图一致。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the pro board"`

### Task 17: 充电横放时自动打开看板

**Files:**
- Create: `ios/Critter/Board/BoardAutoOpen.swift`
- Modify: `ios/Critter/CritterApp.swift`、`ios/Critter/Home/HomeView.swift`

**参考：** `android/app/.../board/BoardTriggerService.kt`（只取接线的思路，iOS 没有前台服务）；spec §8.6。

**Interfaces:**
- `@MainActor @Observable final class BoardAutoOpen`：持有一个 `BoardTrigger`；`var wantsBoard: Bool`（`HomeView` 据此打开、关闭看板）；`sceneActive(_:)`、`boardShown(_:)`、`manualExit()`。
- 充电：`UIDevice.current.isBatteryMonitoringEnabled = true`，`batteryState` 是 `.charging` 或 `.full` 算充电，监听 `batteryStateDidChangeNotification`。
- 重力：`CMMotionManager.deviceMotionUpdateInterval = 0.1`（10 Hz）；只在 `trigger.sensorWanted` 且场景是 `.active` 时开，否则立刻停（拔电、退到后台、关掉自动打开都停）。把 `gravity` 交给 `onGravity`。
- 场景 `.active` 等同 Android 的"屏幕亮着"（`onScreen`）。
- 时间：`ProcessInfo.processInfo.systemUptime` 换算成毫秒；按 `nextDeadline()` 设一个一次性的 `Task.sleep`，到点调 `onTick`，不轮询。
- 手动关掉看板 → `onManualExit`；`PhoneSettings.boardAutoOpen` 改了 → `trigger.autoOpen`。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 模拟器检查**：模拟器的电池状态和重力不能用命令行改，所以加 DEBUG 参数 `-critterFakeDock`：用一个假的电源和重力来源（启动 2 秒后"插电"并"横放"，20 秒后"竖起来"），加 `-critterBoardLog` 打出 `BoardTrigger` 的动作。Expected: 约 5 秒时打开看板（2 秒 + 静止 3 秒），约 23 秒时关掉；日志里重力只在"插电"之后开、关掉自动打开时停。真机上的检查留到装真机那份计划。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the board opens by itself while charging in landscape"`

---

## 收尾

### Task 18: 走查、台账、文档

**Files:**
- Modify: `docs/critter-ios-backlog.md`、`README.md`（iOS 一节）、`ios/Critter/Debug/DebugLaunch.swift` 的文件注释

- [ ] **Step 1: 全量验证。** Run: `swift test 2>&1 | tail -3`（只有那两个 Codex 测试失败）、`make ios-sim`、`xcodebuild -project ios/Critter.xcodeproj -scheme Critter -configuration Release -destination '$(IOS_SIM)' -derivedDataPath ios/build build`（Release 不含 DEBUG 代码和 fixture）、`make app`。Expected: 全部成功。
- [ ] **Step 2: 截图走查。** 每个画面浅色、深色各一张，减少动态效果打开时再过一遍弹层开关（看是不是淡入淡出），全部和 `render-mockups.sh` 的块对照，差异列进报告；明显不对的当场修。
- [ ] **Step 3: 省电逐条对照** spec §9 和视觉设计 §2 反目标：`grep -rn "repeatForever\|CADisplayLink\|TimelineView(.animation" ios/` 应为空；宠物时钟在看不见时停（Task 8 的帧计数）；重力只在条件满足时开（Task 17 的日志）。
- [ ] **Step 4: 联机。** 按计划 1 的做法（`defaults write local.critter.pet debugEnabled -bool true`，跑完删掉）跑 `scripts/dev/ios-sim-live.sh`，看真实会话在草地上、宠物用的是 Mac 分配的形象。Expected: 两张截图都显示"已连接"和 Mac 上的会话。
- [ ] **Step 5: 台账。** `docs/critter-ios-backlog.md`：删掉这份计划做完的条目（"计划 2"一组、"前端优化轮"一组）；做的过程中新发现、推迟的，按要落到的计划写进去。
- [ ] **Step 6: README** 的 iOS 一节补上看板、形象、`render-mockups.sh`、新的 DEBUG 参数。
- [ ] **Step 7: Commit** `git commit -m "docs: iOS plan 2 walkthrough, backlog and README"`
