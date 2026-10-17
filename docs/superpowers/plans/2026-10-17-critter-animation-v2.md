# Critter 动画 v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把用户确认过的动作库（预览页）原样做进 Critter.app：数据驱动的像素动画引擎、按工具区分的工作动作、展开/合并/加入/离开的编排、悬停/目光/来回蹭/拎起/跟随/放下等交互。

**Architecture:** 动作数据全部在 `Skins/clawd/manifest.json`（schema 2，已由预览生成）。`CritterCore/Motion/` 里是纯逻辑的运动引擎：`MotionActor` 一格一格（60 ms）推进动作、状态大脑、粒子、移动、跟随，输出可比较的 `ActorSnapshot`；`FlockTransition` 给编排分类、排队。App 端 `CritterSpriteLayer` 把快照画成 Core Animation 图层，`MotionClock` 只在画面会变的那一格醒来，`FlockView` 负责编排时序和鼠标交互，窗口何时改大小由 `FlockView` 回调 `PetController`。

**Tech Stack:** Swift 6 / SwiftPM / Swift Testing；AppKit、Core Animation；零第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-17-critter-animation-v2-design.md`（行为规则）；`docs/superpowers/specs/2026-10-17-critter-motion-preview.html`（参考实现：`Actor`、`enterState`、`brainStep`、`travelKeys`、`followStep`、`gazeFor`，数值以它为准）。

## Global Constraints

- 平台与工具链不变：`platforms: [.macOS(.v14)]`，`swift-tools-version: 6.0`，Swift 6 语言模式，测试用 Swift Testing（`import Testing`），零第三方依赖。
- **每个任务结束时 `swift build --build-tests` 和 `swift test` 都必须通过**（`--build-tests` 会连 App 目标一起编译）。
- 内存（`footprint` 的 `phys_footprint`）≤ 50 MB（5 个会话展开、有动画）；没有动作在变化时 CPU 接近 0；持续动画（敲笔记本）平均 < 1%。
- 主线程只做界面；运动引擎只在主线程使用（非 `Sendable` 的 `final class`，测试函数标 `@MainActor` 或在同一个任务里创建和使用）。
- `critter-hook`：永远 exit 0；除 `pet`/`toggle` 外不向 stdout 输出；单次执行 < 30 ms。状态文件 schema 仍是 `1`，新字段只能是可选的。
- 一格 = `tickMs` = 60 ms；一个像素格 u = 3 pt × `petScale`；基准框 18×10 个正方形像素格，第 10 行是地面。
- 颜色：身体 `#D97757`、眼睛 `#1D1D1F`；状态色 waiting `#FF9F0A`、done `#34C759`、error `#FF3B30`、running/idle `#8E8E93`（气泡条、标签、计数小标签沿用）。
- 取整一律用预览的 `Math.round` 语义：`jsRound(v) = floor(v + 0.5)`（`-2.5 → -2`）。Swift 的 `.rounded()` 在负的 .5 上不同，不要用。
- 形象素材只在 `Skins/`；`Skins/clawd/manifest.json` 必须与 `docs/superpowers/specs/2026-10-17-clawd-manifest-v2.json` 逐字节相同，`SkinLoader.builtinJSON` 与它逐字相同。
- 实机验证用开发版：先 `osascript -e 'quit app "Critter"'` 退出用户装的那份，`make app && open dist/Critter.app`；截图、日志放在 `mktemp -d` 的临时目录；任务结束时 `scripts/demo-sessions.sh clean`，退出开发版，`open ~/Applications/Critter.app` 恢复用户原来的。

## Review Focus

1. **编排中状态改变**（合并途中某会话变成等确认）→ 它立刻换成提问动作，合并照常完成，那一堆最前面是它。（Task 6 `stateOnlyChangeIsUpdate`；Task 9 Step 7 实机）
2. **编排中结构又变**（离开途中同一会话又回来、连续加减会话）→ 只执行最新的一份，不留下孤儿图层，不卡在“忙”。（Task 6 `latestPendingWins`、`finishRunsPendingThenGoesIdle`；Task 9 Step 7 实机）
3. **动画中拖动**（展开/合并途中按住拖）→ 窗口照常跟手；正在跳的那几只不参与跟随，落地位置正确。（Task 5 `followIgnoredWhileTraveling`；Task 10 Step 6 实机）
4. **动画中隐藏**（合并途中 `/pet`）→ 播完沉下去再收起，时钟停；再显示时是最新状态。（Task 9 Step 7 实机）
5. **动画中途打开“减少动态效果”** → 正在跳的立刻到位、完成回调照常触发，编排不卡住。（Task 5 `enablingReduceMotionFinishesTravel`）

---

## File Structure

```
Skins/clawd/manifest.json                 # ← 替换为 schema 2（逐字节复制 docs 里那份）
Sources/CritterCore/
  Skin.swift                              # 改：schema 2 的类型、校验、加载、内置 JSON
  SkinRenderer.swift                      # 改：姿势合成 PixelGrid、位图、字形位图
  WorkActivity.swift                      # 新：工具名 → 工作类别
  SessionRecord.swift / StateReducer.swift / SessionCatalog.swift   # 改：activity 字段
  FlockLayout.swift                       # 改：正方形像素行高、错位、窗口留白
  FlockTransition.swift                   # 新：编排分类 + 排队
  Motion/
    MotionMath.swift                      # 新：jsRound、MotionRNG
    Particle.swift                        # 新：粒子、生成、物理、绘制
    ActorSnapshot.swift                   # 新：渲染快照、GlyphDraw
    MotionActor.swift                     # 新：播放层、step、snapshot、ticksUntilChange
    MotionActor+State.swift               # 新：状态切换、大脑、变体防抖、头顶标记、减少动态效果
    MotionTravel.swift                    # 新：移动关键格、入座计划
    MotionActor+Interaction.swift         # 新：移动、入座、跟随、目光
    MotionGaze.swift                      # 新：目光区域、来回蹭判定
Sources/CritterApp/
  CritterLayer.swift                        # Task 1 改成静态过渡版；Task 8 删除
  SpriteAtlas.swift                       # 新：姿势/字形位图缓存
  CritterSpriteLayer.swift                  # 新：把 ActorSnapshot 画成图层
  MotionClock.swift                       # 新：60 ms 时钟，只在画面会变时醒来
  FlockView.swift                         # 改：驱动 MotionActor、编排、交互
  FlockChoreographer.swift                # 新：展开/合并/加入/离开的时序
  PetController.swift                     # 改：按内容区定位、交给 FlockView 决定何时改窗口、显示/隐藏动画
  ClickThrough.swift                      # 改：把指针位置转发给 FlockView
Tests/CritterCoreTests/
  SkinTests.swift（重写）  WorkActivityTests.swift  ParticleTests.swift  MotionPlaybackTests.swift
  MotionStateTests.swift  MotionInteractionTests.swift  FlockTransitionTests.swift
  FlockLayoutTests.swift / ReducerTests.swift / ModelTests.swift / CatalogTests.swift（补充）
README.md                                 # 改：动画说明、实测数字
```

## 执行分批（按用户偏好，见 memory `batch-subagent-execution`）

| 批次 | 任务 | 内容 |
|---|---|---|
| A | 1–2 | 皮肤 schema 2、栅格化、静态过渡；activity 字段 |
| B | 3–5 | 运动引擎：播放与粒子；状态与大脑；移动、跟随、目光 |
| C | 6–7 | 编排分类与排队；布局留白 |
| D | 8–9 | App 渲染与时钟；编排 |
| E | 10–11 | 交互；性能与收尾 |

每批一个实现者、一个审查者；批内每个任务单独提交；最后整个分支再审一次。

---

### Task 1: 皮肤清单 schema 2、姿势栅格化、App 静态过渡

**Files:**
- Modify: `Sources/CritterCore/Skin.swift`（整体替换 v1 类型）
- Modify: `Sources/CritterCore/SkinRenderer.swift`
- Replace: `Skins/clawd/manifest.json`（`cp docs/superpowers/specs/2026-10-17-clawd-manifest-v2.json Skins/clawd/manifest.json`）
- Modify: `Sources/CritterApp/CritterLayer.swift`、`Sources/CritterApp/FlockView.swift`（只为编译和静态显示）
- Test: `Tests/CritterCoreTests/SkinTests.swift`（重写）

**Interfaces:**
- Produces（`CritterCore`，全部 `public`、`Codable, Sendable, Equatable`，字段名 = JSON 键名）：
  - `SkinManifest { schema: Int; name: String; tickMs: Int; grid: [Int]; palette: [String: String]; parts: [String: SkinPart]; poses: [String: [String]]; glyphs: [String: [String]]; clips: [String: MotionClip]; effects: [String: EffectSpec]; accessories: [String: AccessorySpec]; states: [String: StateSpec]; interactions: InteractionNames; props: [String: PropSpec] }`，外加 `func state(_ s: PetState) -> StateSpec`（读 `states[s.rawValue]!`，只对校验过的清单调用）。
  - `SkinPart { at: [Int]; rows: [String] }`
  - `ClipKey { pose: String; ticks: Int; dx: Int; dy: Int; effect: String? }`，JSON 是数组：`[pose, ticks]`、`[pose, ticks, dx, dy]`、`[pose, ticks, dx, dy, effect]`；编码时输出能表达它的最短形式。`typealias MotionClip = [ClipKey]`。
  - `Span { min: Double; max: Double }`，`init(_ v: Double)`、`init(_ a: Double, _ b: Double)`；JSON 是数字或 `[a, b]`，`min == max` 时编码成数字。
  - `ParticleSpec { count: Int?; glyph: String; color: String?; colors: [String]?; x: Span; y: Span; vx: Span?; vy: Span?; ay: Double?; life: Span; sway: Double?; pop: Bool?; shrinkTo: String? }`
  - `EffectSpec { particles: [ParticleSpec]?; cycle: [[ParticleSpec]]? }`
  - `AccessorySpec { glyph: String?; frames: [String]?; color: String; periodMs: Int?; box: Int?; reduced: String?; bobEvery: Int?; twinkleEvery: Int?; twinkle: String? }`
  - `WeightedClip { clip: String; weight: Int }`（JSON `["blink", 6]`）、`FidgetSpec { every: [Int]; pick: [WeightedClip] }`
  - `SleepSpec { after: Int; doze: String; loop: String; wake: String; still: String }`、`ImpatientSpec { after: Int; loop: String }`
  - `BadgeSpec { glyph: String; color: String; x: Int; hopEvery: Int; impatientHopEvery: Int }`
  - `VariantSpec { loop: String; enter: String?; exit: String?; prop: String? }`
  - `StateSpec { enter: String?; loop: String?; tint: Tint?; accessory: String?; still: String; stillDy: Int?; seen: String?; fidget: FidgetSpec?; sleep: SleepSpec?; impatient: ImpatientSpec?; badge: BadgeSpec?; variants: [String: VariantSpec]?; defaultVariant: String? }`
  - `enum Tint: String { case dim }`（保留）
  - `InteractionNames { notice, pet, petEnd, press, boopEnd, held, heldStill, drop, blink, join, leave, appear, vanish, hop, land, blinkPose, landDust: String; walkLeft, walkRight: [String]; lookLeft, lookRight, lookUp, lookDown, lookCenter: String }`
  - `PropSpec { glyph: String; colors: [String] }`
  - `SkinValidator.problems(_:) -> [String]`、`SkinLoader.builtinJSON`、`SkinLoader.builtin()`、`SkinLoader.load(name:searchDirs:)`：签名不变。
  - `PixelGrid { minX: Int; minY: Int; width: Int; height: Int; rows: [String] }`（`rows[0]` 是第 `minY` 行，`.` 透明），`func character(atX: Int, y: Int) -> Character?`（基准框坐标，透明或越界返回 nil）。
  - `SkinRenderer.grid(pose: String, in skin: SkinManifest) -> PixelGrid?`：按部件顺序叠画，取实际像素的外接框。
  - `SkinRenderer.image(_ grid: PixelGrid, palette: [String: String], dim: Bool) -> CGImage?`：每格 1 像素；`dim` 的算法沿用 v1（每个通道与 127.5 各半混合并取整，alpha 0.85）。
  - `SkinRenderer.glyphImage(_ rows: [String], color: String) -> CGImage?`：`#` 画成 `color`，其余透明。
- 删除：`Motion`、`Accessory`、`AnimationSpec`、`frames`、`animations`、`pixelAspect`。

- [ ] **Step 1: 替换清单文件，写失败的测试**

```swift
@Test func bundledManifestIsTheDesignCopy() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../..").standardized
    let bundled = try Data(contentsOf: root.appending(path: "Skins/clawd/manifest.json"))
    let design = try Data(contentsOf: root.appending(path: "docs/superpowers/specs/2026-10-17-clawd-manifest-v2.json"))
    #expect(bundled == design)
    #expect(String(decoding: bundled, as: UTF8.self) == SkinLoader.builtinJSON)
}
@Test func builtinIsValidSchema2() {
    let m = SkinLoader.builtin()
    #expect(m.schema == 2); #expect(m.tickMs == 60); #expect(m.grid == [18, 10])
    #expect(SkinValidator.problems(m).isEmpty)
}
@Test func basePoseIsTheApprovedGridDoubled() {
    let old = ["...############...", "...##o######o##...", ".################.", "...############...", "....#.#....#.#...."]
    let g = SkinRenderer.grid(pose: "base", in: SkinLoader.builtin())!
    for y in 0..<10 { for x in 0..<18 {
        let want = Array(old[y / 2])[x]
        #expect(g.character(atX: x, y: y) == (want == "." ? nil : want))
    } }
}
@Test func heldPoseHangsBelowGround() {   // dangling legs reach row 10
    let g = SkinRenderer.grid(pose: "held_a", in: SkinLoader.builtin())!
    #expect(g.minY + g.height == 11)
}
@Test func clipKeyDecodesShortAndLongForms() throws {
    let json = #"[["base",40],["base",10,0,-1],["base",1,0,-2,"dust"]]"#
    let keys = try JSONDecoder().decode(MotionClip.self, from: Data(json.utf8))
    #expect(keys == [ClipKey(pose: "base", ticks: 40, dx: 0, dy: 0, effect: nil),
                     ClipKey(pose: "base", ticks: 10, dx: 0, dy: -1, effect: nil),
                     ClipKey(pose: "base", ticks: 1, dx: 0, dy: -2, effect: "dust")])
    #expect(String(decoding: try JSONEncoder().encode(keys), as: UTF8.self) == json)
}
@Test func spanDecodesNumberOrRange() throws {
    #expect(try JSONDecoder().decode(Span.self, from: Data("5".utf8)) == Span(5))
    #expect(try JSONDecoder().decode(Span.self, from: Data("[3,13]".utf8)) == Span(3, 13))
}
@Test func dimImageMixesHalfWithGrey() { /* PixelGrid 1×1 "#"，palette "#D97757"，dim: true → 读回 RGBA == (172, 123, 107, 217)；dim: false → (217, 119, 87, 255) */ }
```

校验测试（每个都从 `SkinLoader.builtin()` 改一处，断言 `!problems.isEmpty`）：`validatorRejectsSchema1`、`validatorCatchesMissingState`、`validatorCatchesUnknownPoseInClip`、`validatorCatchesZeroTickKey`、`validatorCatchesUnknownEffect`、`validatorCatchesUnknownPartInPose`、`validatorCatchesRaggedPartRows`、`validatorCatchesCharacterNotInPalette`、`validatorCatchesMissingVariantLoop`、`validatorCatchesUnknownInteractionClip`、`validatorCatchesUnknownGlyphInEffect`。保留并改写 `loaderFallsBackOnInvalidSkin`、`loaderFindsValidSkinInSearchDirs`、`loaderFirstValidDirWins`（用“删掉 `states["waiting"]`”造无效皮肤）。删掉只针对 v1 的测试。

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter SkinTests`
Expected: 编译失败（`ClipKey`、`Span`、`PixelGrid` 等不存在）

- [ ] **Step 3: 实现 `Skin.swift` 的 schema 2 类型、`SkinValidator`、`SkinLoader`**

`builtinJSON` 是 `Skins/clawd/manifest.json` 的逐字拷贝（多行字符串字面量）。校验规则见 spec §3 最后一段；以 `@` 开头的特效名属于引擎内部（Task 5），清单里出现即报错。

- [ ] **Step 4: 实现 `SkinRenderer` 的 `grid` / `image` / `glyphImage`**

- [ ] **Step 5: App 静态过渡**

`CritterLayer`：按 18×10、每格 3 pt × scale 画；`apply(state:reduceMotion:)` 只把 `contents` 设成该状态 `still` 姿势（`tint == .dim` 时用调暗版）裁到 18×10 基准框的位图，不加任何动画；头顶仍用原来的 `CATextLayer` 和 `PetState.accessory` 文字；`stillImage(for:)` 返回 `base` 的调暗版。`FlockView` 只改到能编译。

- [ ] **Step 6: 运行全部测试和编译**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 7: Commit**

```bash
git add Skins/clawd/manifest.json Sources/CritterCore/Skin.swift Sources/CritterCore/SkinRenderer.swift Sources/CritterApp/CritterLayer.swift Sources/CritterApp/FlockView.swift Tests/CritterCoreTests/SkinTests.swift
git commit -m "feat(core): skin manifest schema 2 with parts, poses, clips and effects"
```

---

### Task 2: 状态文件记录工作类别 `activity`

**Files:**
- Create: `Sources/CritterCore/WorkActivity.swift`
- Modify: `Sources/CritterCore/SessionRecord.swift`、`Sources/CritterCore/StateReducer.swift`、`Sources/CritterCore/SessionCatalog.swift`
- Test: `Tests/CritterCoreTests/WorkActivityTests.swift`（新）、`ReducerTests.swift`、`ModelTests.swift`、`CatalogTests.swift`

**Interfaces:**
- Produces:
  - `public enum WorkActivity: String, Codable, Sendable, CaseIterable { case think, laptop, read, bash, juggle }`，`static func forTool(_ name: String) -> WorkActivity`
  - `SessionRecord.activity: String?`（`init` 末尾加 `activity: String? = nil`）
  - `PetSession.activity: String?`（`init` 末尾加 `activity: String? = nil`），`SessionCatalog.build` 从记录里带出（没有记录 → nil）

- [ ] **Step 1: 写失败的测试**

```swift
@Test func toolCategories() {
    for t in ["Edit", "MultiEdit", "Write", "NotebookEdit"] { #expect(WorkActivity.forTool(t) == .laptop) }
    for t in ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"] { #expect(WorkActivity.forTool(t) == .read) }
    for t in ["Bash", "BashOutput", "KillShell"] { #expect(WorkActivity.forTool(t) == .bash) }
    for t in ["Agent", "Task"] { #expect(WorkActivity.forTool(t) == .juggle) }
    #expect(WorkActivity.forTool("mcp__github__create_issue") == .laptop)
    #expect(WorkActivity.forTool("SomethingNew") == .laptop)
}
```

`ReducerTests` 增加：`promptSubmitRecordsThink`（`UserPromptSubmit` → `activity == "think"`）、`preToolUseRecordsToolActivity`（Edit → `laptop`、Read → `read`、Bash → `bash`、Task → `juggle`）、`postToolUseBackToThink`（`PostToolUse`、`PostToolUseFailure`、`PermissionDenied` → `think`）、`stopClearsActivity`（`Stop` → nil）、`askUserQuestionHasNoActivity`（`PreToolUse` 的 `AskUserQuestion` → waiting 且 activity nil）。`ModelTests` 增加 `recordWithoutActivityDecodes`（一份不含 `activity` 键的 v1 JSON 解码后 `activity == nil`）。`CatalogTests` 增加 `catalogCarriesActivity`。

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter "WorkActivityTests|ReducerTests|ModelTests|CatalogTests"`
Expected: 编译失败（`WorkActivity` 不存在）

- [ ] **Step 3: 实现**

`StateReducer` 的 `write(state:detail:)` 加一个 `activity:` 参数，按 spec §5.6 的表填写；表外的事件写 nil。

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过（含 `CritterHookTests`）

- [ ] **Step 5: Commit**

```bash
git add Sources/CritterCore/WorkActivity.swift Sources/CritterCore/SessionRecord.swift Sources/CritterCore/StateReducer.swift Sources/CritterCore/SessionCatalog.swift Tests/CritterCoreTests
git commit -m "feat(core): record each running session's work activity"
```

---

### Task 3: 运动引擎：随机数、粒子、播放层、快照

**Files:**
- Create: `Sources/CritterCore/Motion/MotionMath.swift`、`Motion/Particle.swift`、`Motion/ActorSnapshot.swift`、`Motion/MotionActor.swift`
- Test: `Tests/CritterCoreTests/ParticleTests.swift`、`Tests/CritterCoreTests/MotionPlaybackTests.swift`

**Interfaces:**
- Consumes: Task 1 的 `SkinManifest`、`MotionClip`、`EffectSpec`、`ParticleSpec`、`Span`、`InteractionNames`
- Produces:
  - `public func jsRound(_ v: Double) -> Int`（`Int(floor(v + 0.5))`）
  - `public final class MotionRNG { init(seed: UInt64); static func system() -> MotionRNG; func unit() -> Double /* [0,1) SplitMix64 */; func value(_ s: Span) -> Double; func integer(_ s: Span) -> Int /* 闭区间 */; func integer(in r: ClosedRange<Int>) -> Int }`
  - `public struct GlyphDraw: Equatable, Sendable { glyph: String; color: String; x: Int; y: Int; alpha: Double }`：`x`、`y` 是字形左上格，基准框坐标（y 向下，地面 = 10），相对“锚点 + 跟随偏移”，已含 lag、lift 和（粒子、道具的）关键格 dx。
  - `public struct ActorSnapshot: Equatable, Sendable { hidden: Bool; pose: String; bodyX: Int /* 关键格 dx + lag */; bodyY: Int /* 关键格 dy + lift，向上为正，决定地面裁切 */; offsetX: Int; offsetY: Int /* 跟随偏移，u，向上为正 */; tint: Tint?; alpha: Double; z: Int; shadowWidth: Int /* u，0 = 无 */; accessory: GlyphDraw?; badge: GlyphDraw?; particles: [GlyphDraw]; props: [GlyphDraw] }`
  - `public struct Particle: Equatable, Sendable`：字段 `glyph, color: String; x, y, vx, vy, ay, sway: Double; life, age: Int; pop: Bool; shrinkTo: String?`；`mutating func step(dt: Double)`；`var isAlive: Bool`；`func draw() -> GlyphDraw`（相对粒子坐标系，调用方再加偏移）
  - `public enum ParticleSpawner { static func spawn(_ e: EffectSpec, cycleIndex: Int, rng: MotionRNG) -> [Particle] }`
  - `public final class MotionActor`：
    - `init(skin: SkinManifest, rng: MotionRNG, reduceMotion: Bool = false)`；`let skin`
    - 可写：`reduceMotion: Bool`、`tint: Tint?`、`alpha: Double`（1）、`z: Int`（2）、`hidden: Bool`、`noAccessory: Bool`、`lift: Int`、`lag: Int`
    - 只读：`clock: Int`、`isPlayingOnce: Bool`、`modeName: String?`、`currentClipName: String?`（生成的动作为 nil）、`currentKeyIndex: Int`、`particles: [Particle]`
    - `setLoop(_ name: String)`、`setLoop(clip: MotionClip, name: String?)`、`setMode(_ name: String?)`
    - `play(_ name: String, completion: ((Bool) -> Void)? = nil)`、`play(clip: MotionClip, name: String?, completion: ((Bool) -> Void)? = nil)`、`cancelOnce()`
    - `emit(_ effect: String)`；`step()`；`snapshot() -> ActorSnapshot`；`ticksUntilChange() -> Int`（≥ 1）

规则（照预览 `Actor` 类）：
- 播放优先级：单次 > 模式 > 基础（spec §4.1）。单次播完：先切回“模式 ?? 基础”的开头，再以 `true` 调完成回调；被 `play` 替换或 `cancelOnce` 时以 `false` 调。回调里可以再调 `play`（状态必须先更新好）。
- `step()` 顺序：`clock += 1` → 粒子 `step(dt: tickMs/1000)` 并移除死掉的 → 当前关键格 `kt += 1`，用完则进入下一格（到尾：单次结束或循环回头）→ 新关键格开始时触发它的特效。之后的任务会在最前面插入跟随和大脑（Task 4、5）。
- 关键格开始时触发特效；`reduceMotion` 时不发粒子。每个特效名各自记一个 `cycle` 轮次。
- 生成：`count` 重复；数值取 `rng.value`，`life` 取 `rng.integer`；`colors` 按展开后的序号 `i % colors.count`；`ay`、`sway` 缺省 0，`vx`、`vy` 缺省 0。
- 粒子绘制（spec §4.6）：`x = jsRound(p.x + sway项)`，`sway项 = Double(jsRound(sin(Double(age) * 0.5) * sway))`；`y = jsRound(p.y) + (pop && age < 2 ? -1 : 0)`；`age > 0.65·life` → alpha 0.5；`shrinkTo` 且 `age > life/2` → 换字形、x、y 各 +1。
- 快照：`accessory`、`badge` 为 nil，`props` 为空（Task 4 填）；`bodyX = dx + lag`，`bodyY = dy + lift`；`shadowWidth`：`air = dy + lift`，≤ 0 → 0，≤ 2 → 10，≤ 5 → 6，否则 2；粒子的 `GlyphDraw` 再加 `dx + lag`、`−lift`。
- `ticksUntilChange`：有粒子 → 1；否则当前关键格剩余格数。

- [ ] **Step 1: 写失败的测试**

`ParticleTests`：
```swift
@Test func dustParticleMovesAndDies() {
    var p = ParticleSpawner.spawn(SkinLoader.builtin().effects["dust"]!, cycleIndex: 0, rng: MotionRNG(seed: 1))[0]
    p.step(dt: 0.06); #expect(p.draw().x == 1)          // 2 - 12*0.06 = 1.28
    for _ in 0..<3 { p.step(dt: 0.06) }; #expect(!p.isAlive)   // life 4
}
@Test func confettiHasSixteenCyclingColors() { /* 16 个；第 i 个颜色 = colors[i % 6]；x ∈ [5,12]；life ∈ 13...19 且为整数 */ }
@Test func drawRules() { /* pop：age 0、1 时 y-1，age 2 时不偏；sway；age > 0.65·life → 0.5；twinkle 过半寿命 → "dot" 且 x、y 各 +1 */ }
@Test func jsRoundMatchesMathRound() { #expect(jsRound(-2.5) == -2); #expect(jsRound(27.5) == 28); #expect(jsRound(-17.5) == -17) }
@Test func rngIsDeterministicPerSeed() { /* 同种子两串 10 个 unit() 相等，不同种子不等 */ }
```
`MotionPlaybackTests`（`let a = MotionActor(skin: SkinLoader.builtin(), rng: MotionRNG(seed: 7))`）：
```swift
@Test func onceResumesLoopAndCompletesTrue()      // setLoop("idle"); play("blink"){ok=$0}; step()×2 → ok == true, currentClipName == "idle", currentKeyIndex == 0
@Test func replacingOnceCompletesFalse()
@Test func modeTakesOverBaseUntilCleared()       // setMode("held") → "held"; setMode(nil) → "idle"
@Test func onceOverModeResumesMode()             // setMode("pet"); play("notice") 播完 → "pet"
@Test func effectFiresAtKeyStart()               // play("jump") 后不 step：particles.count == 2（dust）
@Test func reduceMotionEmitsNoParticles()
@Test func completionMayStartAnotherClip()       // 回调里 play("wink") → currentClipName == "wink"
@Test func bodyYFollowsKeyAndLift()              // play(clip: [ClipKey(pose:"base",ticks:3,dx:1,dy:-2,effect:nil)], name: nil) → bodyX 1, bodyY -2；lift = 3 → bodyY 1
@Test func shadowWidthByHeight()                 // dy 2 → 10，4 → 6，5 → 6，6 → 2，0 → 0；lift 3 dy 0 → 6
@Test func ticksUntilChangeIsRemainingKeyTicks() // setLoop("idle") → 40；step×10 → 30；emit("dust") → 1
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter "ParticleTests|MotionPlaybackTests"`
Expected: 编译失败

- [ ] **Step 3: 实现四个文件**

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/CritterCore/Motion Tests/CritterCoreTests/ParticleTests.swift Tests/CritterCoreTests/MotionPlaybackTests.swift
git commit -m "feat(core): motion actor playback, particles and render snapshot"
```

---

### Task 4: 状态切换、大脑、工作变体、头顶标记、减少动态效果

**Files:**
- Create: `Sources/CritterCore/Motion/MotionActor+State.swift`
- Modify: `Sources/CritterCore/Motion/MotionActor.swift`（存储属性、`step` 前插大脑、`snapshot`、`ticksUntilChange`）
- Test: `Tests/CritterCoreTests/MotionStateTests.swift`

**Interfaces:**
- Consumes: Task 3 的 `MotionActor`
- Produces（`MotionActor` 上）：
  - 只读：`state: PetState`（初始 `.idle`）、`variant: String`（初始 `defaultVariant`）、`asleep: Bool`、`badgeVisible: Bool`
  - 可写：`brainEnabled: Bool`（默认 true）
  - `enterState(_ s: PetState, quiet: Bool = false)`、`setActivity(_ activity: String?)`、`wake()`
  - `stateLoopName() -> String`：睡着 → `sleep.loop`；running → 当前变体 loop；等待且已着急 → `impatient.loop`；其他 → `loop`

规则（spec §4.2–4.5、§4.12；预览 `enterState`、`brainStep`、`drawAcc`）：
- `enterState`：离开 running 时取当前变体的 `exit`；设循环、`tint`、头顶标记、道具；`quiet` → 只设循环、`badgeVisible = true`；否则进场 = `变体.enter ?? 状态.enter`（running），有 exit 时在 exit 的完成回调里（`ok` 且状态没再变）播进场；从 done 进 idle 且没有 enter → 播 `done.seen`；都没有 → `cancelOnce()`。等待状态：进场动作开始的那一刻 `badgeVisible = true`、`badgeAge = 0`；`reduceMotion` 时立即可见。计数器清零，小动作倒计时 `rng.integer(in: 40...90)`。
- 大脑（`step` 开头，`brainEnabled` 且无模式；Task 5 再加上“移动、跟随中暂停”）：空闲醒着计时满 `sleep.after` → 睡着（`setLoop(sleep.loop)`、`play(sleep.doze)`）；等待计时恰好到 `impatient.after` → `setLoop(impatient.loop)`；有 `fidget`、不在单次动作、没睡着、非 `reduceMotion` → 倒计时到 0 时按权重挑一个播放并重取 `every` 区间；running 的变体防抖（spec §4.4）。
- `setActivity`：nil 或不在 `variants` 里 → `defaultVariant`。不在 running 时只记住，进入 running 时直接用（不防抖）。在 running 时：新值持续 ≥ 20 格且当前变体已显示 ≥ 40 格才切：播旧 `exit`（若有），完成后换循环并播新变体自己的 `enter`（若有）；`reduceMotion` 时直接换循环。
- `wake()`：睡着时 → 醒、计时清零、`setLoop(loop)`、`play(sleep.wake)`。
- 头顶标记、常驻 `!`、twinkle、juggle 道具、隐藏条件、坐标：spec §4.5、§4.7 原文。`spinner` 帧号 `jsRound((1 − cos(2π · clock·tickMs / periodMs)) / 2 × 5)`，横坐标 `jsRound(9 − w/2)`（再加 lag），纵向顶行 `−7 + (5 − h)/2`（整除），`q`/`check`/`bang` 顶行 `−2 − h`；`q` 在 `(clock / bobEvery) % 2 == 1` 时上移 1；`check` 在 `clock % twinkleEvery == 0` 时（非 reduce、非 `noAccessory`）触发 `twinkle`；常驻 `!` 在 `x = badge.x + lag`，顶行 `−2 − h`，`badgeAge < 2` 或 `clock % 周期 < 2` 时上移 1（reduce 不动）。
- `reduceMotion` 快照：姿势 = 模式是 `held` → `heldStill`；否则睡着 → `sleep.still`，否则 `still`；`bodyY = (stillDy ?? 0) + lift`，`bodyX = lag`；`spinner` 画 `reduced`。
- `ticksUntilChange` 再取以下的最小值：`spinner` 下次换帧的格数（往后试算最多 34 格）、`q` 的 `bobEvery − clock % bobEvery`、`check` 的 `twinkleEvery − clock % twinkleEvery`、常驻 `!` 下次上/下的格数、juggle 道具 → 1、小动作倒计时、离睡着的格数、离着急的格数、变体防抖还差的格数。

- [ ] **Step 1: 写失败的测试**（`MotionStateTests`，固定种子）

```swift
@Test func quietEnterSetsLoopOnly()               // enterState(.waiting, quiet: true) → currentClipName "ask", !isPlayingOnce, snapshot().badge?.x == 16
@Test func enterPlaysEnterThenLoop()              // enterState(.done) → "celebrate"；推进到它播完 → "content"
@Test func leavingLaptopClosesBeforeAlert()       // 安静进 running(laptop)；enterState(.waiting) → "lap_close"、badge 为 nil；7 格后 → "alert"，badge 可见且 y 比静止时小 1
@Test func staleEnterIsDropped()                  // running→waiting（正在 lap_close）→ 立刻 →done：之后永远不出现 "alert"，最终 "content"
@Test func doneToIdlePlaysSeen()
@Test func fallsAsleepAfter2000TicksAndWakes()    // brain 开，step×2000 → asleep，循环 "sleep"，accessory nil；wake() → "wake"，循环 "idle"
@Test func waitingTurnsImpatientAt500()           // step×500 → stateLoopName() == "impatient"，常驻 ! 每 8 格一跳
@Test func fidgetPlaysAPickAndReschedules()       // 用 @testable 读倒计时；到 0 时播的是 pick 里的动作，新倒计时 ∈ 60...160
@Test func noFidgetDuringMode()
@Test func activityDebounce()                     // laptop 显示中 setActivity("think")：前 39 格不切；第 40 格开始 "lap_close"，之后循环 "think"
@Test func briefActivityFlickerIgnored()          // setActivity("think") 10 格后 setActivity("laptop") → 始终没有 "lap_close"
@Test func runningEntryUsesDesiredVariant()       // setActivity("read"); enterState(.running) → "work_enter"，循环 "read"
@Test func spinnerFollowsCosine()                 // clock 0/5/10/17/25/33 → s0/s1/s3/s5/s3/s0；s5 宽 5 → x == 7，顶行 -7
@Test func accessoryHiddenWhenAsleepHeldOrMerged()       // asleep、setMode("held")、noAccessory = true 时 accessory 和 badge 都为 nil
@Test func checkTwinklesEvery43Ticks()
@Test func qBobsEvery7Ticks()
@Test func juggleBallsFollowFormula()             // variant juggle，clock = 0 时第 0 颗球 x == 3（再加 dx+lag），y == -2
@Test func reduceMotionShowsStills()              // 各状态 still；error bodyY == -1；睡着 "shut"；spinner "dotbig"；enterState(.done) 后无粒子
@Test func ticksUntilChangeCountsBrainAndAccessories()
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter MotionStateTests`
Expected: 编译失败

- [ ] **Step 3: 实现**

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/CritterCore/Motion Tests/CritterCoreTests/MotionStateTests.swift
git commit -m "feat(core): motion states, fidgets, sleep, work variants and accessories"
```

---

### Task 5: 移动、入座、跟随、目光、来回蹭

**Files:**
- Create: `Sources/CritterCore/Motion/MotionTravel.swift`、`Motion/MotionActor+Interaction.swift`、`Motion/MotionGaze.swift`
- Modify: `Sources/CritterCore/Motion/MotionActor.swift`（存储属性；`step` 最前面加跟随；快照里的跟随姿势和目光；`reduceMotion` 的 `didSet`）
- Test: `Tests/CritterCoreTests/MotionInteractionTests.swift`

**Interfaces:**
- Consumes: Task 3、4
- Produces:
  - `public enum MotionTravel { static func keys(fromDx: Int, fromDy: Int, toDy: Int, delay: Int, hopLength: Int, names: InteractionNames) -> MotionClip }`：预览 `travelKeys` 的逐字移植；`toDy > 0` 时最后一格的特效是引擎内部名 `"@seat"`。
  - `public struct Seat: Equatable, Sendable { row: Int; alpha: Double; z: Int }`
  - `public enum PileSeating { static func backRows(total: Int) -> Int /* max(0, min(2, total − 1)) */; static func seats(departureOrder: [String], lead: String, total: Int) -> [String: Int] /* lead → 0，其余依次 nb, nb−1, …, 不够时都是 1 */; static func seat(row: Int) -> Seat /* row 2 → alpha 0.55，否则 0.75；z = 2 − row */ }`
  - `MotionActor`：`traveling: Bool`（只读）；`travel(fromDx: Int, fromDy: Int, delay: Int, hopLength: Int = 14, seat: Seat? = nil, completion: ((Bool) -> Void)? = nil)`；`unseat()`（alpha 1、z 2、`tint` 回到状态的、`noAccessory = false`、`setLoop(stateLoopName())`）；`following: Bool`（只读）；`startFollow(lookLeft: Bool)`；`followShift(dx: Double, dy: Double)`（u，y 向上）；`releaseFollow()`；`setGaze(_ zone: GazeZone?)`
  - `public enum GazeZone: Equatable, Sendable { case left, right, up, down, center }`
  - `public enum MotionGaze { static func zone(pointer: CGPoint, center: CGPoint, unit: CGFloat) -> GazeZone? }`（AppKit 坐标，y 向上；规则 spec §4.11）
  - `public struct RubDetector: Sendable { init(); mutating func move(x: CGFloat, at t: TimeInterval) -> Bool /* 现在算不算在蹭 */; func shouldEnd(at t: TimeInterval) -> Bool; mutating func reset() }`

规则：
- `travel`：`traveling = true`；有 `seat` 时先把基础循环设成 `[[land, 9999, 0, row]]`（名字 nil），最后一格的 `"@seat"` 把 `tint = .dim`、`alpha`、`z` 设成 seat 的值；完成时 `traveling = false` 再调回调。`reduceMotion` 时直接套用 seat、同步以 `true` 回调。移动中把 `reduceMotion` 打开 → 立即结束：套用 seat、`traveling = false`、回调 `true`。
- 移动中、跟随中：大脑暂停（不计时、不挑小动作、不切变体）；移动中不画头顶标记和常驻 `!`。
- 跟随（spec §4.10，预览 `followShift`/`followStep`）：`startFollow` 在移动中或隐藏时无效；`followShift` 先减再夹到 ±12 / ±8；`step` 最前面追赶；竖直追平那一格触发 `landDust`；`releaseFollow` 后都追平 → `following = false` 并 `play(blink)`（reduce 不播）。reduce：偏移立即清零。
- 快照：跟随中（非 reduce）姿势按 spec §4.10，走路帧 `(clock / (小跑 ? 1 : 2)) % 2 == 1` → 数组第 0 个，否则第 1 个；dx、dy 记 0；`offsetX = jsRound(offX)`，`offsetY = jsRound(offY)`。目光：`setGaze` 记住对应 `look*` 姿势；只在“空闲醒着或做完了”、无单次动作、无模式、不跟随时替换姿势；reduce 也替换。
- `RubDetector`：|Δx| ≥ 3 才算一次移动；方向反转记时刻，只保留 1 秒内的；≥ 3 次 → true；`shouldEnd`：距上次计入的移动 > 0.7 秒。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func travelKeysMatchPreview() {
    let names = SkinLoader.builtin().interactions
    let k = MotionTravel.keys(fromDx: 30, fromDy: 0, toDy: 0, delay: 2, hopLength: 14, names: names)
    #expect(k.map { [$0.pose, "\($0.ticks)", "\($0.dx)", "\($0.dy)", $0.effect ?? ""] } == [
        ["base","2","30","0",""], ["air","1","28","2",""], ["air","1","25","3",""], ["air","1","23","2",""], ["base","1","20","0",""],
        ["air","1","17","2",""], ["air","1","15","3",""], ["air","1","12","2",""], ["base","1","10","0",""],
        ["air","1","8","2",""], ["air","1","5","3",""], ["air","1","3","2",""], ["base","1","0","0",""],
        ["base","2","0","-2","dust_small"], ["base","1","0","0",""], ["shut","1","0","0",""]])
}
@Test func seatKeysEndRaised() {
    // keys(fromDx: -20, fromDy: 0, toDy: 2, delay: 0, hopLength: 14) ==
    // air 1 -17 2 | air 1 -15 4 | air 1 -12 3 | base 1 -10 1 | air 1 -7 3 | air 1 -5 5 | air 1 -2 4 | base 1 0 2 | base 1 0 1 dust_small | base 1 0 2 @seat
}
@Test func travelCompletesAndClearsTraveling()   // 移动中 traveling == true、snapshot().accessory == nil；完成后 false
@Test func noBrainWhileTravelingOrFollowing()     // 移动、跟随期间 step 不推进小动作倒计时和空闲计时
@Test func seatAppliesDimAlphaZAtLastKey()        // seat(row: 2) → 最后一格开始时 tint .dim、alpha 0.55、z 0；之后停在 dy 2
@Test func unseatRestoresStateLook()
@Test func travelUnderReduceMotionCompletesImmediately()
@Test func enablingReduceMotionFinishesTravel()   // Review Focus 5
@Test func followWalksThenJogs()                  // startFollow；followShift(dx: 10, dy: 0) → offsetX -10；每格 -10,-8,-6,-5,…,0；姿势 walk_r_*；小跑时每格换帧
@Test func followCapsAt12And8()
@Test func verticalCatchUpHopsAndLandsWithDust()
@Test func followEndsAfterReleaseAndBlinks()
@Test func followIgnoredWhileTraveling()          // Review Focus 3
@Test func gazeZones()                            // unit 3：距离 200 → nil；正上方 40 → up；左 30 → left；右 30 → right；下方 20 → down；其余 → center
@Test func gazeOnlyWhenCalm()                     // waiting 时 setGaze(.left) 不改姿势；idle 醒着时改成 "look_l"
@Test func rubNeedsThreeReversalsInOneSecond()
@Test func rubIgnoresSmallMovesAndEndsAfter700ms()
@Test func pileSeatsFarthestBackFirst()           // seats(departureOrder: ["d","c","b","a"], lead: "b", total: 4) == ["b":0,"d":2,"c":1,"a":1]；total 2 → 另一只坐 1
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter MotionInteractionTests`
Expected: 编译失败

- [ ] **Step 3: 实现**

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/CritterCore/Motion Tests/CritterCoreTests/MotionInteractionTests.swift
git commit -m "feat(core): hops, pile seating, drag-follow, gaze and rub detection"
```

---

### Task 6: 编排分类与排队

**Files:**
- Create: `Sources/CritterCore/FlockTransition.swift`
- Test: `Tests/CritterCoreTests/FlockTransitionTests.swift`

**Interfaces:**
- Produces:
  - `public struct FlockStructure: Equatable, Sendable { enum Kind { case empty, expanded, merged }; kind: Kind; ids: [String] /* expanded：列顺序；merged：[lead]；empty：[] */; init(_ p: FlockPresentation) }`
  - `public enum FlockTransition: Equatable, Sendable { case update, expand, collapse, join(added: [String]), leave(removed: [String]), leaveThenJoin(removed: [String], added: [String]), reorder, reuse(from: String, to: String), snap }`
  - `static func between(_ old: FlockStructure, _ new: FlockStructure) -> FlockTransition`
  - `public struct ChoreographyQueue<Item> { init(); private(set) var isBusy: Bool; mutating func submit(_ item: Item) -> Item?; mutating func finish() -> Item? }`

分类（spec §5.3）：相同结构 → `update`；merged→merged、empty→empty → `update`；merged→expanded → `expand`；expanded→merged → `collapse`；expanded→expanded：只有新增 → `join`，只有减少 → `leave`，都有 → `leaveThenJoin`，同一组 id 顺序变了 → `reorder`；empty→expanded(1) → `reuse(from: "", to: id)`；expanded(1)→empty → `reuse(from: id, to: "")`；其余涉及 empty 的 → `snap`。

队列：空闲时 `submit` 变忙并原样返回；忙时存为待办（替换旧的）返回 nil；`finish` 有待办 → 返回它、保持忙；没有 → 变空闲、返回 nil。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func classification()        // 按上面每一行各一个断言
@Test func stateOnlyChangeIsUpdate()   // Review Focus 1：同样的 id 和顺序，只有状态不同 → .update
@Test func idleSubmitRunsImmediately()
@Test func latestPendingWins()         // Review Focus 2：忙时 submit A、B → finish() 返回 B
@Test func finishRunsPendingThenGoesIdle()
@Test func removeThenReAddSameIdWhileBusy()  // 忙时先 submit 少了 x 的，再 submit 又有 x 的 → 只剩后者
```

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FlockTransitionTests`
Expected: 编译失败

- [ ] **Step 3: 实现**

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 5: Commit**

```bash
git add Sources/CritterCore/FlockTransition.swift Tests/CritterCoreTests/FlockTransitionTests.swift
git commit -m "feat(core): classify and queue flock choreography"
```

---

### Task 7: 布局：正方形像素行高、错位、窗口留白

**Files:**
- Modify: `Sources/CritterCore/FlockLayout.swift`、`Sources/CritterApp/PetController.swift`
- Test: `Tests/CritterCoreTests/FlockLayoutTests.swift`

**Interfaces:**
- Produces（`FlockLayout`）：
  - `Metrics.unit: CGFloat`（`3 * scale`）；`accessoryHeight` 默认 `8 * unit`（`init` 的参数改成 `accessoryHeight: CGFloat? = nil`，nil 时取默认）；`pileStep` = `(4 * unit, 1 * unit)`；`Metrics.overscan: Insets` = 上 `12u`、左 `12u`、下 `8u`、右 `12u`
  - `public struct Insets: Equatable, Sendable { top, left, bottom, right: CGFloat }`
  - `Result.content: CGRect`（不含留白的区域，窗口坐标）；`size`、`slots`、`handle`、`chips`、`hitRects` 都整体偏移 `(overscan.left, overscan.bottom)`
  - `Result.windowFrame(contentFrame: CGRect) -> CGRect`、`Result.contentFrame(windowFrame: CGRect) -> CGRect`
  - `fitted` 改为比较 `content.width`
- `PetController`：定位用 `layout.content.size` 算内容框，再 `windowFrame(contentFrame:)`；放下时 `PositionModel.anchor(for: layout.contentFrame(windowFrame: panel.frame), …)`；`canExpand` 比较 `content.width`。

- [ ] **Step 1: 写失败的测试**

```swift
@Test func metricsUseSquarePixelUnit() { let m = FlockLayout.Metrics(scale: 1); #expect(m.unit == 3); #expect(m.accessoryHeight == 24); #expect(m.pileStep == CGSize(width: 12, height: 3)) }
@Test func overscanSurroundsContent() { /* scale 1：size.width == content.width + 72，size.height == content.height + 60，content.origin == (36, 24)；scale 2 时这些留白都加倍 */ }
@Test func everyRectLiesInsideContent()
@Test func windowContentRoundTrip()
@Test func fittedComparesContentWidth()
```
其余已有测试按新的行高和偏移改写断言。

- [ ] **Step 2: 运行，确认失败**

Run: `swift test --filter FlockLayoutTests`
Expected: FAIL / 编译失败

- [ ] **Step 3: 实现 `FlockLayout` 和 `PetController` 的改动**

- [ ] **Step 4: 运行全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 5: 实机看一眼**

`make app`，退出已装的 Critter，`open dist/Critter.app`，`scripts/demo-sessions.sh 3`：宠物位置和以前一样贴在右下角，能拖动、松手后位置保持，透明区域点击穿透。`scripts/demo-sessions.sh clean`。

- [ ] **Step 6: Commit**

```bash
git add Sources/CritterCore/FlockLayout.swift Sources/CritterApp/PetController.swift Tests/CritterCoreTests/FlockLayoutTests.swift
git commit -m "feat(layout): square-pixel rows and transparent overscan around the flock"
```

---

### Task 8: App 渲染：精灵图层、时钟、FlockView 驱动运动引擎

**Files:**
- Create: `Sources/CritterApp/SpriteAtlas.swift`、`Sources/CritterApp/CritterSpriteLayer.swift`、`Sources/CritterApp/MotionClock.swift`
- Delete: `Sources/CritterApp/CritterLayer.swift`
- Modify: `Sources/CritterApp/FlockView.swift`、`Sources/CritterApp/PetController.swift`

**Interfaces:**
- Consumes: Task 1–5、7
- Produces（App 内部）：
  - `final class SpriteAtlas { init(skin: SkinManifest); func pose(_ name: String, dim: Bool) -> (image: CGImage, grid: PixelGrid)?; func glyph(_ name: String, color: String) -> CGImage? }`（都缓存）
  - `final class CritterSpriteLayer: CALayer { init(atlas: SpriteAtlas, unit: CGFloat); var groundOrigin: CGPoint /* 视图坐标：基准框第 0 列与地面的交点 */; func render(_ s: ActorSnapshot) }`
  - `@MainActor final class MotionClock { init(tickMs: Int); var onTick: ((Int) -> Int)?; func start(); func stop(); func poke() }`：`onTick(n)` 先推进 n 格并渲染，返回“还要几格才有变化”；`poke()` 立即 `onTick(0)` 并重排；`Timer` 容差 10 ms；`start`/`stop` 幂等。
  - `FlockView.update(_ presentation: FlockPresentation, layout: FlockLayout.Result, sessions: [PetSession])`（替换原来的两参数版本）、`FlockView.setRunning(_ running: Bool)`、`setReduceMotion(_:)`（保留）

渲染换算（u = `metrics.unit`，B = `groundOrigin + (offsetX·u, offsetY·u)`）：
- 身体：放在一个 `masksToBounds` 的裁切层里，裁切层底边 = B.y（地面），向上 40 u、左右各留 12 u；身体层 `x = B.x + (bodyX + grid.minX)·u`，`y = B.y + (10 − grid.minY − grid.height + bodyY)·u`，大小 `grid.width·u × grid.height·u`。
- 字形（头顶标记、常驻 `!`、粒子、道具）：不裁切；`x = B.x + gx·u`，`y = B.y + (10 − gy − h)·u`，`opacity = alpha`；用复用的小图层池。
- 影子：宽 `w·u`、高 `max(2, u/2)`，`x = B.x + (bodyX + 9 − w/2)·u`，紧贴在地面下方，黑色不透明度 0.28。
- `zPosition = z`、`opacity = alpha`、`isHidden = hidden`；全部在关闭隐式动画的 `CATransaction` 里；快照和上次相等就跳过。

`FlockView` 行为（本任务还没有编排：布局变化直接跳到位）：
- 为 `sessions` 里每个会话维护一个 `MotionActor`（新建：先 `setActivity(session.activity)` 再 `enterState(session.state, quiet: true)`；已有：activity 变了 `setActivity`，状态变了 `enterState`）；空状态用 id `""` 的占位 Critter。不在 `sessions` 里的移除。
- 展开：每只的 `groundOrigin` = 它那列 `slot.critter.origin`；合并：只有 lead 可见，在那一堆的前面（`slot.critter.origin`），其余 `hidden`；后面那一堆是两个静态图层（`base` 调暗，第 k 排右移 4k u、上移 k u，不透明度 0.75 / 0.55，第 k 排在 `(clock + 23k) % 80 < 2` 时换成 `blinkPose`），只画 `PileSeating.backRows(total:)` 排。
- 头顶不再用 `CATextLayer`；合并时计数小标签仍是 `ChipsView`。
- 时钟：`onTick(n)` 对每只 `step()` n 次，渲染，返回所有 Critter 的 `ticksUntilChange()` 与那一堆眨眼的最小值。
- `PetController`：`setVisible` 时 `flockView.setRunning(visible)`；“减少动态效果”变化时 `setReduceMotion`；`render()` 调新的 `update(_:layout:sessions:)`。

- [ ] **Step 1: 实现三个新文件，改 `FlockView`、`PetController`，删 `CritterLayer`**

- [ ] **Step 2: 编译和测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 3: 实机验证**

```bash
osascript -e 'quit app "Critter"'; make app && open dist/Critter.app
scripts/demo-sessions.sh 4 running waiting done idle
D=$(mktemp -d); for i in 1 2 3 4 5 6; do screencapture -x "$D/s$i.png"; sleep 0.5; done; echo "$D"
```
Expected（逐张看截图里右下角的宠物）：运行中那只抱着笔记本敲（几张截图里手的位置不同），头顶是橙色指示符；等确认那只举手、头顶 `?`、右上角常驻橙色 `!`；做完了那只眯眼笑、`✓`；空闲那只调灰、偶尔有小动作。`scripts/demo-sessions.sh set 1 done` 后能看到欢呼和彩纸。

- [ ] **Step 4: Commit**

```bash
git add -A Sources/CritterApp
git commit -m "feat(app): render the motion engine with sprite layers and an on-demand clock"
```

---

### Task 9: 编排：展开、合并入座、加入、离开、显示/隐藏

**Files:**
- Create: `Sources/CritterApp/FlockChoreographer.swift`
- Modify: `Sources/CritterApp/FlockView.swift`、`Sources/CritterApp/PetController.swift`

**Interfaces:**
- Consumes: Task 5（`travel`、`unseat`、`PileSeating`）、Task 6（`FlockStructure`、`FlockTransition`、`ChoreographyQueue`）、Task 8
- Produces：
  - `FlockView.present(_ presentation: FlockPresentation, layout: FlockLayout.Result, sessions: [PetSession], anchorSide: Anchor.Side, place: @escaping () -> Void)`（替换 Task 8 的 `update`）
  - `FlockView.playAppear()`、`FlockView.playVanish(completion: @escaping () -> Void)`
  - `PetController.render()` 改为把“设窗口位置、点击区域、写日志”放进 `place` 闭包；`setVisible(false)` → `playVanish { orderOut }`，`setVisible(true)` → `orderFrontRegardless()` 后 `playAppear()`（减少动态效果时直接显示/收起）

规则（spec §5.3、§4.8、§4.9）：
- `present` 先把状态和文字立刻套到所有 Critter（`setActivity`/`enterState`，气泡、标签文字），再把 `(presentation, layout, place)` 交给 `ChoreographyQueue`；轮到执行时用 `FlockTransition.between(已显示的结构, 新结构)` 选做法，做完调 `finish()` 接着做待办。
- 跳到新位置一律 `travel(fromDx:fromDy:delay:hopLength: 14)`，错开 2 格，离终点（或那一堆）最近的先跳；`fromDx = jsRound((旧 x − 新 x) / u)`。
- 窗口位移换算：调用 `place()` 前后各读一次 `window.frame.origin`，差值加到旧坐标上。
- 那一堆在展开布局里的位置：`anchorSide == .right` 时按两个布局的 `content.maxX` 对齐，否则按 `content.minX` 对齐；y 按 `content.minY` 对齐。
- 合并：按 `PileSeating.seats` 入座（`travel(…, seat:)`），先到的坐最后排、后到的盖住先到的同排那只（先到的设 `hidden`）；lead 的 z 设 3；全部完成后 `place()`、切换成静态那一堆、`unseat` 并隐藏非 lead。展开：先 `place()`，按座位从那一堆起跳（lead `fromDy 0`，第 k 排 `fromDy k`），起跳前 `unseat()`。
- 加入：先 `place()`；新的在自己的列播 `interactions.join`；原有的跳到新位置。离开：窗口不动，离开的播 `interactions.leave`，播完移除，再 `place()`，剩下的跳。`leaveThenJoin` 两段接着做；`reuse` 直接改 id 对应；`snap`、`update`（列位置变了的跳过去）立即 `place()`。
- 气泡、标签：所属 Critter `traveling` 或正在播 join/leave 时隐藏；结束时用 0.18 s 淡入（`NSAnimationContext`）。在 `DiagnosticLog` 记 `choreo <kind> start` / `choreo <kind> end`。
- 显示：每只错开 90 ms 播 `appear`；隐藏：错开 60 ms 播 `vanish`，全部完成再回调。

- [ ] **Step 1: 实现**

- [ ] **Step 2: 编译和测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 3: 打开调试开关，造 4 个会话**

```bash
defaults write local.critter.pet debugEnabled -bool true
osascript -e 'quit app "Critter"'; make app && open dist/Critter.app
scripts/demo-sessions.sh 4 running waiting done idle
```

- [ ] **Step 4: 合并 / 展开**

`open "critter://debug-click?target=handle"`，每 0.3 秒截一张图共 8 张，再 `open "critter://debug-click?target=chips"` 同样截图。Expected：合并时每只落地就坐进那一堆（中途没有哪只消失），最后的那一堆和静态的一模一样；展开时它们从座位上跳出来；标签和气泡在落地后才出现，没有闪烁。`~/.critter/app.log` 里有成对的 `choreo collapse start/end`、`choreo expand start/end`。

- [ ] **Step 5: 加入 / 离开 / 自动合并**

`scripts/demo-sessions.sh 3` → 有一只挥手沉下去，剩下的跳到新位置；再 `scripts/demo-sessions.sh 5` → 新来的从地下探头；多于阈值时自动合并。

- [ ] **Step 6: 显示 / 隐藏**

`open critter://hide`、`open critter://show`：沉下去再收起，显示时从天上掉下来。

- [ ] **Step 7: Review Focus 1、2、4**

合并途中 `scripts/demo-sessions.sh set 4 waiting`：那只立刻换成举手，合并完成后它站在最前面。离开动画播放中马上 `scripts/demo-sessions.sh 4`：最终只显示 4 只、没有残影，日志里 `choreo` 成对出现。合并途中 `open critter://hide`：收起后 `open critter://show`，显示的是最新状态。最后 `scripts/demo-sessions.sh clean`。

- [ ] **Step 8: Commit**

```bash
git add Sources/CritterApp
git commit -m "feat(app): choreograph expand, collapse, join, leave and show/hide"
```

---

### Task 10: 交互：目光、悬停、来回蹭、按下、拎起与跟随、放下

**Files:**
- Modify: `Sources/CritterApp/ClickThrough.swift`、`Sources/CritterApp/FlockView.swift`、`Sources/CritterApp/PetController.swift`

**Interfaces:**
- Consumes: Task 5（`MotionGaze`、`RubDetector`、`startFollow`/`followShift`/`releaseFollow`、`setGaze`）、Task 8、9
- Produces：`ClickThroughController.onPointerMoved: ((NSPoint) -> Void)?`（屏幕坐标，全局和本地监听都调用）；`FlockView.pointerMoved(screenPoint: NSPoint)`

规则（spec §4.10、§4.11）：
- 目光：每只用 `MotionGaze.zone(pointer:center:unit:)`，中心 = 锚点 + (9u, 7u)（AppKit y 向上）；只有某只的区域变化时才 `setGaze` 并 `clock.poke()`。
- 悬停：指针进入某只的区域（横向锚点右侧 1u…17u，纵向地面下 2 pt 到地面上 11u，都含跟随偏移）→ 睡着的 `wake()`，否则无单次、无模式时 `play(interactions.notice)`；来回蹭用 `RubDetector`，成立 → `setMode(interactions.pet)`，离开或 `shouldEnd` → `setMode(nil)` + `play(interactions.petEnd)`（`shouldEnd` 在时钟里检查）。
- 按下：命中的那只 `cancelOnce()`、`setMode(interactions.press)`；松开没拖 → `setMode(nil)`、`play(interactions.boopEnd)`，并立即执行原来的点击（跳回会话 / 展开）。
- 拖动（超过 3 pt）：被按的那只 `setMode(interactions.held)`、`lift = 3`、`lag = clamp(jsRound(−Δx/3), −3, 3)`（Δx 是这次鼠标事件的水平位移，pt），没有移动时每格向 0 收 1；其余可见的 `startFollow(lookLeft: 被按那只在左边)`，每次窗口移动 `followShift(dx: Δx/u, dy: Δy/u)`；它们的气泡、标签每格按 `offsetX·u, offsetY·u` 平移。松开：被按的 `lift = 0`、`lag = 0`、`setMode(nil)`、`play(interactions.drop)`；其余 `releaseFollow()`。合并时只有 lead 被拎。
- `simulateClick` 走同一条按下/松开路径。

- [ ] **Step 1: 实现**

- [ ] **Step 2: 编译和测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 3: 实机：目光和悬停**

`scripts/demo-sessions.sh 3 idle done idle`，把鼠标从宠物左边慢慢移到右边、再移到上方：空闲和做完了的会转眼睛；指针停到某只身上它抬一下手；在身上左右快速晃 → 眯眼脸红冒爱心，停手后结束。

- [ ] **Step 4: 实机：点击**

点一只：先眯眼蹲下、往左看一眼，同时跳回会话（演示会话会打开 Terminal 或记录跳转方案，看 `app.log` 的 `event jump`）。

- [ ] **Step 5: 实机：拖动**

按住中间那只左右拖、上下拖：只有它被拎起蹬腿；其余两只先落后再迈步追上，追平后看着它；气泡、标签跟着各自的 Critter；松手后它落地扬尘，其余眨眼。

- [ ] **Step 6: Review Focus 3**

`open "critter://debug-click?target=handle"` 后立刻按住拖动：窗口跟手，正在跳的那几只不跟随，落地位置正确。`scripts/demo-sessions.sh clean`。

- [ ] **Step 7: Commit**

```bash
git add Sources/CritterApp
git commit -m "feat(app): gaze, hover, rub, boop, lift-and-follow and drop interactions"
```

---

### Task 11: 性能与收尾

**Files:**
- Modify: `README.md`（“开发”里的实测数字、“品牌说明”里关于清单的描述、新增“动画”一小节：状态 → 动作对照、交互列表、`activity` 字段）
- Modify（仅当测量不达标时）：`Sources/CritterApp/MotionClock.swift`、`Sources/CritterApp/CritterSpriteLayer.swift`、`Sources/CritterCore/Motion/MotionActor*.swift`

- [ ] **Step 1: 测量**

```bash
osascript -e 'quit app "Critter"'; make app && open dist/Critter.app
scripts/measure.sh --sessions 5                       # 5 个会话（默认状态循环）
scripts/demo-sessions.sh 5 idle idle idle idle idle; sleep 5; scripts/measure.sh
scripts/demo-sessions.sh 5 running running running running running; sleep 5; scripts/measure.sh
```
Expected：内存 ≤ 50 MB；全空闲时 CPU 平均 ≤ 0.3%；全部敲笔记本时平均 < 1%。不达标时先用 `sample` 找热点，再改（常见：快照比较前就创建了数组、每格重建图层、时钟没有按 `ticksUntilChange` 睡）。

- [ ] **Step 2: 减少动态效果**

打开“系统设置 › 辅助功能 › 显示 › 减少动态效果”（或请用户代为打开），看宠物：每只停在代表姿势、没有粒子、合并展开直接到位；关掉后恢复。验证不了时在汇报里写明。

- [ ] **Step 3: 更新 README，跑全部测试**

Run: `swift build --build-tests && swift test`
Expected: 全部通过

- [ ] **Step 4: 收尾**

`scripts/demo-sessions.sh clean`；`defaults delete local.critter.pet debugEnabled`；`osascript -e 'quit app "Critter"'`；`open ~/Applications/Critter.app`。

- [ ] **Step 5: Commit**

```bash
git add README.md Sources
git commit -m "docs: describe the v2 animations and record measured footprint"
```
