# Critter 手机端 · 计划 5：台账剩余（连接、提醒、核心库、Mac 端）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修掉 `docs/critter-phone-backlog.md` 第三部分里计划 4 没做的条目：Android 的连接、提醒、线程和核心库问题，以及 Mac 端的那一批。都不改画面。

**Architecture:** 每条问题先核对（台账说“部分条目可能已在后来的修复波次里顺带解决”），还在的写一条能失败的测试再修；已经不在的只在台账里注明“已不复现”和证据，不改代码。Android 的修复尽量落在 `:core`（能跑 JVM 单测），app 层只做接线。

**Tech Stack:** 同计划 2–4；Mac 端 Swift 5 + XCTest（`swift test`）。

**Spec:** `docs/critter-phone-backlog.md` 第三部分（每条就是需求）；协议以 `docs/critter-bridge-protocol.md` 为准；Android 原设计 `docs/superpowers/specs/2026-10-18-critter-android-design.md` 的 §8.3（连接与保活）、§8.7（提醒）、§9（省电）、§10（安全）、§11（稳定性）。

**前提**：计划 4 已完成（它改过 `BridgeRepository`、`BoardActivity`、`BoardTriggerService`、`Alerts`、`NotificationActionReceiver`）。

## Global Constraints

- 不改协议的线上格式；Mac 和手机必须继续和对方的旧版本互通。协议文档里的行为描述要和代码一致，改了行为就改文档。
- Android 原设计 §9 的省电要求有效：不加轮询、不加周期任务；心跳和重连规则只按本计划写的改。
- 原设计 §2 的反目标有效：手机没连上、Critter.app 没运行、手机功能关着时，Claude Code 的行为必须和现在完全一样；hook 不能让终端里的对话框晚出现，不能多输出任何东西。
- 一条台账一个提交（同一个函数里的几条可以合并），提交说明写清是台账哪一条。
- Android 测试：`cd android && ./gradlew :core:test :app:testDebugUnitTest`；Mac 测试：在仓库根目录 `swift test`（全部通过，包括并行运行）。
- 每个任务的第一步是核对：读代码确认问题还在；不在了就在台账那一条后面写“已不复现：<证据，文件:行>”，跳过它的修复步骤。

## Review Focus

1. **手机在 Wi‑Fi 之间切换、Mac 睡眠又醒来时连续触发重连**：`reconnectNow`、`ensureConnected`、网络回调可能在同一秒里各来一次，不能同时开两条连接，也不能把退避弄乱。由 Task 1 的 `rapidReconnectsKeepOneSocket` 覆盖。
2. **看板打开着、心跳从 3 分钟换成 30 秒时正在作答**：为了换心跳而重连，不能让正在等回复的作答失败。由 Task 1 的 `shorterPingWaitsForInFlightRequests` 覆盖。
3. **悬浮球可见时来了请求，用户没理它就锁屏了**：锁屏后要发出通知，而且只发一次；用户解锁时请求已经在电脑上答完了，就不该再发。由 Task 3 的 `requestSeenOnlyOnThePileIsPostedWhenThePileGoes` 和 `answeredWhileVisibleIsNotPostedLater` 覆盖。
4. **Mac 上 `settings.json` 有非 UTF-8 字节或很长**：安装、卸载不能把它写坏或丢内容。由 Mac 部分对应任务的测试覆盖。
5. **旧手机连新 Mac、新手机连旧 Mac**：本计划的改动都不能要求对方升级。每个改了收发行为的任务都要在测试里用旧格式的帧跑一遍。

---

## 批次 F：Android

### Task 1: `BridgeClient` 的启停、重连、心跳、超时

**Files:**
- Modify: `android/core/src/main/kotlin/local/critter/core/net/BridgeClient.kt`
- Test: `android/core/src/test/kotlin/local/critter/core/net/BridgeClientTest.kt`（用现有的 `FakeMac`）

台账条目：`stop()` 后马上 `start()` 的竞争、`stop()` 不重置离线时间和退避、`pingIntervalMs` 不是 `@Volatile`、旧 OkHttpClient 连接池不关、`reconnectNow()` 在连接中留下过期唤醒标记、看板的 30 秒心跳要到下次重连才生效、通知上点允许最坏约 36 秒才提示失败（连接这一半）、缺 `reconnectNow`/`setPingInterval`/`stop`/形象回复的测试。

**Interfaces:**
- Produces:
  - `fun close()`：`stop()` 之后关掉自己的 OkHttpClient（`dispatcher.executorService.shutdown()`、`connectionPool.evictAll()`）；之后不能再 `start()`。
  - `reconnectNow()`：只在 `Offline`（跳过退避）或 `Connected`（断开重连）时起作用；`Connecting`、`AwaitingApproval`、`Idle`、`NeedsRepair` 时什么都不做，也不留唤醒标记。
  - `setPingInterval(ms)`：变短且当前 `Connected` 时，等手上的请求都回来（最多 `requestTimeoutMs`）再断开重连；变长时照旧等下一次连接。
  - `request(...)` 超时（`requestTimeoutMs` 内没有 `result`）时断开当前连接：Mac 正常几十毫秒内就回，超时说明这条连接已经坏了，让状态马上离开 `Connected`。

- [ ] **Step 1: 核对**：`pingIntervalMs` 已经是 `@Volatile`；`setPingInterval` 用 `newBuilder()` 共用连接池（不新建池）。这两条在台账写“已不复现”。其余几条确认还在。
- [ ] **Step 2: 写测试**（`BridgeClientTest`）：
  - `stopThenStartKeepsTheNewSocket`：连上 → `stop()` → 立刻 `start()` → 等 `Connected` → 发一条命令能拿到 `result`（旧任务的 `finally` 没清掉新 socket）。
  - `stopResetsOfflineSinceAndBackoff`：断两次（退避到 4 s）→ `stop()` → `start()` 连不上时第一次 `Offline.retryInMs == 2000`、`since` 是这次的时间。
  - `reconnectNowWhileConnectingLeavesNoWake`：`FakeMac` 不接受连接时，在 `Connecting` 里调 `reconnectNow()`；这次失败后状态是 `Offline(retryInMs = 2000)`，并且 1 秒内没有第二次连接尝试。
  - `reconnectNowSkipsTheBackoff`：`Offline(retryInMs = 2000)` 时调 `reconnectNow()`，200 ms 内出现新的连接尝试。
  - `timeoutDropsTheLink`：`FakeMac` 吞掉一条命令不回；`request` 返回 `ok = false`、`message = "超时"`，之后状态离开 `Connected` 并重新连上。
  - `shorterPingReconnects`：连着时 `setPingInterval(180_000)` → `setPingInterval(30_000)`：`FakeMac` 看到第二条连接，`nextPingIntervalMs == 30_000`；`longerPingWaitsForTheNextConnection`：反过来不重连。
  - `shorterPingWaitsForInFlightRequests`：有一条命令在等回复时缩短心跳，命令照常拿到 `ok = true`，回复之后才重连。
  - `skinReplySettlesTheRequest`：`requestSkin` 收到 `skin` 帧时返回它；收到没有这个形象的回复（看 `FakeMac` 怎么表示）返回 null。
  - `rapidReconnectsKeepOneSocket`：100 ms 内调三次 `reconnectNow()`，`FakeMac` 最多同时只有一条连接。
- [ ] **Step 3: 跑测试，确认失败**（照现有实现，前五条和缩短心跳几条会失败）。
- [ ] **Step 4: 实现**：`connectOnce` 的 `finally` 只在 `socket === link.ws` 时清 `socket`，只让这条连接上发出去的请求失败（`inFlight` 记下每个请求用的是哪个 socket）；`stop()` 里 `offlineSince = null`、`backoff.reset()`；`reconnectNow`、`setPingInterval`、超时照 Interfaces。
- [ ] **Step 5: 跑测试**，全部通过（多跑两遍确认不抖）。
- [ ] **Step 6: 提交**（可以按台账条目分成两三个提交）。

### Task 2: 仓库、服务和界面的接线

**Files:**
- Modify: `android/app/src/main/kotlin/local/critter/phone/bridge/BridgeRepository.kt`, `ui/board/BoardActivity.kt`, `board/BoardSounds.kt`, `AndroidManifest.xml`, `CritterApp.kt`
- Test: 现有测试照旧通过（这一层没有 JVM 单测；靠 Task 1 的 core 测试和装机核对）

台账条目：`ensureConnected` 在正在连接时也会触发 `reconnectNow`；通知上点允许最坏约 36 秒（仓库这一半）；`startClient()` 没有同步；`CritterApp.onCreate`、配对和取消配对在主线程读写磁盘；`BoardSounds.prepare` 在主线程；`injectSnapshotForDebug` 在正式版里是公开的；多个卡片窗口共用 `taskAffinity=""`；用 Home 键离开看板后看板一直活到拔电；点会话可能根据离线缓存的快照打开卡片。

- [ ] **Step 1: 核对**每一条。`startClient()` 现在是 `@Synchronized` 且 `client != null` 时直接返回：确认配对成功和服务启动不会各起一个客户端（`pair()` 的 `stopClient()`/`startClient()` 也在同一把锁里）就写“已不复现”。“点会话可能根据离线缓存打开卡片”：`AnswerActivity` 会等活的快照再核对（计划 4 还加了“未连接，连上后才能作答”），确认后写“按设计如此：卡片自己核对”。
- [ ] **Step 2: 实现**：
  - `ensureConnected()`：只在 `_state.value is ConnState.Offline` 时调 `client?.reconnectNow()`（连接中的不打断，连着的不断开）。
  - `answerWhenLive`：第一次是本地失败（`unknown`）时，第二次之前等到一条**新的**连接（`state` 先离开 `Connected`；Task 1 的超时断开保证会离开）再 `awaitRequest`；整段最多 `requestTimeoutMs + LIVE_WAIT_MS`（约 18 秒），在函数说明里写清楚。
  - 磁盘：`pair()` 里的 `pairingStore.save`、`unpair()` 里的删除、快照缓存的读写都放到 `Dispatchers.IO`。启动时读配对和缓存（第一帧就要用）保留在 `onCreate` 里同步读：文件只有几百字节，换成异步会让首页先闪一下配对页【Claude 定】。
  - `BoardSounds.prepare` 在 `Dispatchers.IO` 里调（`SoundPool.load` 读文件），`play` 留在原处。
  - `injectSnapshotForDebug`：正式版（`ApplicationInfo.FLAG_DEBUGGABLE` 为 0）里直接返回。
  - 清单：`AnswerActivity` 的 `taskAffinity` 改成 `local.critter.phone.answer`，`DetailActivity` 改成 `local.critter.phone.detail`，`BoardActivity` 改成 `local.critter.phone.board`（每种窗口各占一个任务，互不顶掉）。
  - `BoardActivity.onStop`：被判定为手动离开（`byHand`）且没在 finishing 时 `finish()`，看板不再在后台活到拔电；手动离开后这次充电不再自动打开的规则不变。
- [ ] **Step 3: 跑测试和构建**，全部通过。
- [ ] **Step 4: 装机核对**：断开 Mac 的 Wi‑Fi 后在锁屏通知上点「允许」，记下多久提示失败（应在 18 秒内）；打开看板按 Home，确认看板没了（`adb shell dumpsys activity activities | grep BoardActivity` 为空）；从悬浮球打开作答卡片再打开详情，两个窗口在最近任务里是两个。
- [ ] **Step 5: 提交**（按条目分提交）。

### Task 3: 悬浮球可见时看过的提醒

**Files:**
- Modify: `android/core/src/main/kotlin/local/critter/core/logic/AlertPlanner.kt`, `android/app/src/main/kotlin/local/critter/phone/service/BridgeService.kt`, `overlay/OverlayController.kt`
- Test: `android/core/src/test/kotlin/local/critter/core/logic/AlertPlannerTest.kt`

台账条目：悬浮堆可见时看过的提醒，之后不会再发通知；缺 `AlertPlanner` 新会话情形的测试。

**Interfaces:**
- Produces:
  - `AlertTracker.next(current: SnapshotBody, prefs: AlertPrefs, notify: Boolean = true): AlertPlan`：`notify = false` 时要发的请求不进 `alerted`，记进 `shownOnPile`；`post` 为空。
  - `AlertTracker.pileHidden(current: SnapshotBody): AlertPlan`：`shownOnPile` 里仍在 `current.pending` 的请求放进 `post`（不震动），然后移进 `alerted`。
  - `OverlayController.onHidden: (() -> Unit)?`：悬浮球从“能看见”变成“看不见”（熄屏、锁屏、被隐藏）时调一次；`BridgeService` 用它对最新的 `repo.live` 调 `pileHidden` 再 `Alerts.apply`。

- [ ] **Step 1: 写测试**：
  - `requestSeenOnlyOnThePileIsPostedWhenThePileGoes`：`next(有请求 r1, notify = false)` 的 `post` 为空；`pileHidden(同一个快照)` 的 `post == [r1]`、`vibrate == false`；再调一次 `pileHidden` 的 `post` 为空。
  - `answeredWhileVisibleIsNotPostedLater`：`next(有 r1, notify = false)` → `next(没有 r1, notify = false)` → `pileHidden(没有 r1)` 的 `post` 为空。
  - `newSessionAlreadyDoneDoesNotAlert`：前一个快照里没有的会话第一次出现就是 `done`/`error`（打开了“做完了时通知”），`sessionAlerts` 为空（只在“刚进入”时提醒）；新会话一出现就带权限请求时照常 `post`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 实现**上面的 Interfaces 和接线。
- [ ] **Step 4: 跑测试和构建**，全部通过。
- [ ] **Step 5: 装机核对**：悬浮球开着、亮屏时让电脑发一个权限请求（不理它），锁屏，确认锁屏上出现通知。
- [ ] **Step 6: 提交**。

### Task 4: 看板静止判断、配对链接、核心库

**Files:**
- Modify: `android/core/src/main/kotlin/local/critter/core/board/BoardTrigger.kt`（`Stillness`），`core/protocol/PairingUri.kt`，`core/skin/Skin.kt`，`core/skin/SkinLibrary.kt`，`core/motion/MotionMath.kt`（只加说明），`android/core/build.gradle.kts`，`app/.../critter/SkinStore.kt`
- Test: `BoardTriggerTest.kt`，`PairingUriTest.kt`，`SkinTest.kt`，新增 `SkinLibraryTest.kt`

台账条目：看板的静止判断只看一次采样；`PairingUri` 里的 `+` 缺测试；`SkinManifest` 是可变数据类、被多个角色共享；`intOrNull` 不接受 `3.0`；`jsRound` 溢出时饱和而 Swift 会崩；核心测试类路径加了整个 `Skins/` 目录；收到自定义形象会把所有角色重建一次。

**Interfaces:**
- Produces:
  - `Stillness.add` 只有在窗口里的读数覆盖了至少 `windowMs`（最早一条不晚于 `nowMs - windowMs`）时才可能返回 true。
  - `SkinLibrary(assetReader, pushed, forced, clockSkin, reuse: SkinLibrary? = null)`：`reuse` 里源 JSON 和时钟形象都没变的清单，直接沿用同一个对象；`SkinStore.build()` 传入上一个库。

- [ ] **Step 1: 核对**：`intOrNull`（或等价的整数读取）现在对 `3.0` 返回什么；`SkinManifest` 和它的子类型里哪些字段是 `var`、有没有地方在解码后改它；`PairingUri.parse` 对 `+` 的处理，以及 Mac 端生成链接时会不会把 `+` 转义（`Sources/CritterCore/Bridge/Pairing.swift`，`URLComponents` 不转义查询里的 `+`）。
- [ ] **Step 2: 写测试**：
  - `BoardTriggerTest.oneReadingIsNotStill`：只有一条读数时 `add` 返回 false；`stillAfterAFullWindow`：1.5 s 内每 200 ms 一条相同读数，最后一条返回 true。
  - `PairingUriTest.plusInTheNameStaysAPlus`：名字参数是 `A+B` 时 `name == "A+B"`；`%20` 是空格。（如果 Mac 那边其实会转义 `+`，按 Mac 的实际编码写断言，并在测试旁注明。）
  - `SkinTest.wholeNumberDoublesReadAsInts`：清单里 `"tickMs": 60.0`、`"ticks": 3.0` 能解码，等于 `60`、`3`；`3.5` 仍然被拒。
  - `SkinTest.manifestsAreNotSharedMutably`：照“核对”的结论二选一：字段改成 `val`（测试只需编译通过并断言解码结果相等），或者 `SkinLoader.decode` 每次返回独立的深拷贝（断言两次解码的 clip 列表不是同一个对象）。
  - `SkinLibraryTest.rebuiltLibraryKeepsUnchangedManifests`：`lib2 = SkinLibrary(…, pushed = lib1 的 + 一个新形象, reuse = lib1)`，`lib2.manifest("sprig") === lib1.manifest("sprig")`；新推送的形象是新对象；时钟形象换了就不沿用。
- [ ] **Step 3: 跑测试，确认失败。**
- [ ] **Step 4: 实现**。`jsRound` 只加一句说明：校验把所有会进 `jsRound` 的数限制在 Int 范围内，所以饱和和 Swift 的崩溃都到不了（写上是哪条校验）。`core/build.gradle.kts` 的测试资源只收 `*/manifest.json`。
- [ ] **Step 5: 跑测试**，全部通过（包括 `GoldenTest`）。
- [ ] **Step 6: 提交**（按条目分提交）。

## 批次 G：Mac 端

批次 G 和批次 F 改的文件不重叠，可以同时做。核对的起点是文末的“附录：Mac 端调查结论”（文件和行号是 2026-10-19 `f7cabcf` 的，动手前以当时的代码为准）。“配对「允许」来得太晚时可能批准另一台手机”已经修好（`BridgeController` 的 `lastClientNumber` 从不归零，`5030481`）：Task 5 第一步在台账里注明。

### Task 5: 待答请求、答案和收件箱的文件安全

**Files:**
- Modify: `Sources/CritterCore/StateStore.swift`（`atomicWrite`）、`Sources/CritterCore/PendingRequest.swift`（`PendingStore`）、`Sources/CritterCore/Inbox.swift`、`Sources/CritterCore/HookCommand.swift`（备份）、`Sources/CritterApp/Bridge/BridgeController.swift`（`startWatchers`、`submitAnswer`）
- Test: `Tests/CritterCoreTests/StateStoreTests.swift`、`PendingStoreTests.swift`、`InboxTests.swift`、`StatusLineInstallerTests.swift`

台账条目：`atomicWrite` 在 `setAttributes` 抛错时留下临时文件；`settings.json` 备份用默认 0644 权限；目录只在创建时 chmod 0700；inbox token 在 chmod 前短暂是 0644；答案已被取走后再收到第二个答案会短暂返回 ok。

**Interfaces:**
- Produces:
  - `atomicWrite(_:to:permissions:)`：临时文件一开始就以目标权限创建（`FileManager.createFile(atPath:contents:attributes:)`，和 `writeAnswer` 一样），任何一步失败都删掉临时文件（`defer`）。
  - `PendingStore.writeAnswer(...)` 写完后再读一次请求文件：请求已经没了（hook 刚取走答案并清理），就删掉刚写的答案、返回“已被回答”（Mac 回 `resolved`），和协议文档“之后的回答一律 `resolved`”一致。
  - 私有目录（`pending`、`answers`、`inbox`、桥接用的监视目录）每次写之前都确保是 0700（已有的 0755 目录会被改回 0700）。
  - `settings.json` 的备份用原文件的权限，读不到时 0600；备份目录 0700。

- [ ] **Step 1: 核对**各条（附录 M2、M4、M9、M12），台账写上 M12 已修。
- [ ] **Step 2: 写测试**：
  - `StateStoreTests.atomicWriteNeverLeavesATempFile`：目标目录可写、但目标路径是一个已有的目录（重命名必失败）时，调用抛错，目录里没有残留的临时文件；`atomicWriteCreatesWithTheFinalMode`：用 0600 写，写完立刻是 0600（检查最终文件；临时文件的权限由实现保证，测试里注明）。
  - `PendingStoreTests.answerAfterTheRequestWasTakenIsRefused`：写请求 → 写答案 A → 模拟 hook 删掉请求（不删答案前先删请求，照 `remove` 的顺序）→ 写答案 B 返回“已被回答”，答案目录里没有 B。
  - `PendingStoreTests.existingLooseDirectoryIsTightened`、`InboxTests.existingLooseInboxIsTightened`：先建 0755 的目录，写一次之后是 0700。
  - `StatusLineInstallerTests.cliInstallWritesBackupAndSettings` 加断言：备份文件权限等于原 `settings.json` 的权限（测试里原文件是 0600）。
- [ ] **Step 3: 跑测试，确认失败**：`swift test --filter 'StateStoreTests|PendingStoreTests|InboxTests|StatusLineInstallerTests'`。
- [ ] **Step 4: 实现**；`BridgeController.submitAnswer` 只把 `PendingStore` 的新结果映射成 `alreadyAnswered`，逻辑都在 `CritterCore`（`CritterApp` 没有测试目标）。
- [ ] **Step 5: 跑全部测试**：`swift test`，全部通过。
- [ ] **Step 6: 提交**（按条目分提交）。

### Task 6: 状态栏、`settings.json` 的字节和安装卸载

**Files:**
- Modify: `Sources/CritterCore/HookCommand.swift`、`Sources/CritterCore/StatusLineCommand.swift`、`Sources/critter-hook/main.swift`、`Sources/CritterCore/StatusLineInstaller.swift`、`scripts/uninstall.sh`、`README.md`（卸载一节、包装格式一节）
- Test: `Tests/CritterCoreTests/StatusLineTests.swift`、`StatusLineInstallerTests.swift`

台账条目：状态栏命令的输出经过 `String(decoding:)`，非法 UTF-8 变成 U+FFFD；`settings.json` 也是有损解码；安装对改过路径的 hook 不幂等（会嵌套包装）；卸载时包装脚本还在但 hook 已经没了，会停下来打印手动步骤。（`uninstall.sh` 写死 `$HOME/.critter/bin`：安装脚本同样不认 `CRITTER_HOME`、README 写明“总是 ~/.critter”，两边一致，台账写“按设计如此”。）

**Interfaces:**
- Produces:
  - `HookResult` 加 `rawStdout: Data?`（默认 nil）；`statusline` 把原始命令的输出原样放在这里，`critter-hook` 的 `main` 有它就写它、没有才写 `stdout`。其余用到 `HookResult(stdout:)` 的地方不动。
  - `settings.json` 不是有效 UTF-8 时，`statusline-install` / `statusline-uninstall` 不做任何改动，退出码非 0，提示“settings.json 不是有效的 UTF-8，没有改动”。
  - `StatusLineInstaller.unwrap(_:)` 认出任何路径的 Critter 包装（引号里的路径以 `/critter-hook` 结尾、后面紧跟 ` statusline`，格式同 README 的包装说明）；`install` 遇到别的路径的包装时换成当前路径重新包，不嵌套。
  - `uninstall.sh`：hook 不在时，在仓库里 `swift build -c release --product critter-hook`，用 `.build/release/critter-hook statusline-uninstall` 解包后继续卸载；编译也失败时才停下并打印手动步骤（现有文案）。

- [ ] **Step 1: 核对**各条（附录 M1、M3、M5）。
- [ ] **Step 2: 写测试**：
  - `StatusLineTests.statusLinePassesInvalidUTF8Through`：`FakeShell` 输出 `Data([0x41, 0xFF, 0x42])`，结果的 `rawStdout` 逐字节相等。
  - `StatusLineInstallerTests.invalidUTF8SettingsAreLeftAlone`：`settings.json` 含 `0xFF` 字节时安装返回非 0，文件字节不变，没有备份。
  - `StatusLineInstallerTests.wrapperForAnotherHookPathIsReplacedNotNested`：命令是 `/old/home/.critter/bin/critter-hook` 的包装时，用新路径安装后命令只包一层、指向新路径、原始命令不变；`unwrapRecognisesAnyHookPath`；现有 `unwrapRejectsHandEditedWrappers` 照旧通过。
- [ ] **Step 3: 跑测试，确认失败。**
- [ ] **Step 4: 实现**；`uninstall.sh` 的改动在一个装好、再删掉 `~/.critter/bin/critter-hook` 的环境里手动跑一次（用临时 `HOME`，不碰真实的 `~/.claude/settings.json`），把输出贴进报告。README 的卸载说明和包装格式说明照改。
- [ ] **Step 5: 跑全部测试**，通过。
- [ ] **Step 6: 提交**（按条目分提交）。

### Task 7: 事件 hook 的开销、作答文本、上下文用量

**Files:**
- Modify: `Sources/CritterCore/HookCommand.swift`（`runEvent`）、`Sources/CritterCore/PendingResolution.swift`、`Sources/CritterCore/AskDecision.swift`、`Sources/CritterCore/ContextUsage.swift`
- Test: `Tests/CritterCoreTests/PendingResolutionTests.swift`、`AskDecisionTests.swift`、`ContextUsageTests.swift`、`HookCommandTests.swift`

台账条目：event hook 每个事件都重新解析 stdin、列出 pending 目录并计算哈希；问题答案先 trim 再判长度但输出原值；计划退回的意见不 trim；用量全为 0 的一行得出 0 token。

**Interfaces:**
- Produces:
  - `runEvent`：stdin 只解析一次（`HookInput` 里带上 `PendingResolution` 需要的字段，或者解析成一个 `[String: Any]` 后两处共用）；`PendingResolution.apply` 在 pending 目录不存在或为空时直接返回，不算哈希、不读文件。SessionStart 写收件箱照旧（无条件）。
  - `AskDecision.output`：问题答案和“让它改”的意见都输出 trim 之后的文本（和协议文档“trim 之后至多 4000 字”一致）。
  - `ContextUsage.lastUsage`：从后往前跳过三项之和为 0 的用量行；全部为 0 时返回 nil。

- [ ] **Step 1: 核对**各条（附录 M6、M7、M8）。
- [ ] **Step 2: 写测试**：
  - `PendingResolutionTests.emptyPendingDirectoryDoesNoWork`：pending 目录不存在时 `apply(PostToolUse…)` 不创建目录、不读任何文件（用一个计数的文件系统替身，或断言目录仍不存在）；`eventStillPrintsNothing` 照旧。
  - `AskDecisionTests.answersAreTrimmedInTheOutput`：答案 `"  好  "` 输出 `"好"`；4000 个字两边各加 10 个空格能通过且输出 4000 字；4001 个字被拒。`planReviseMessageIsTrimmed`：`"  改一下  "` 输出 `"改一下"`。
  - `ContextUsageTests.zeroUsageLineFallsBackToAnEarlierTurn`：最后一行用量全 0、前一行 1234 时返回 1234；`allZeroGivesNil`。
- [ ] **Step 3: 跑测试，确认失败。**
- [ ] **Step 4: 实现。**
- [ ] **Step 5: 跑全部测试**，通过；`HookBinaryTests` 里“event 什么都不输出”的测试照旧通过。
- [ ] **Step 6: 提交**（按条目分提交）。

### Task 8: 设备列表、「发一句」长度、`expired`

**Files:**
- Modify: `Sources/CritterCore/Bridge/Pairing.swift`（`DeviceRegistry`）、`Sources/CritterCore/Bridge/BridgeConnection.swift`、`Sources/CritterCore/Bridge/BridgeProtocol.swift`（如有需要）、`Sources/CritterApp/Bridge/BridgeController.swift`（`pendingRequest`）、`docs/critter-bridge-protocol.md`
- Test: `Tests/CritterCoreTests/PairingTests.swift`、`BridgeConnectionTests.swift`

台账条目：`DeviceRegistry.load` 把损坏的设备文件当成空列表，下一次添加会覆盖它；未知设备 id 提前返回，时间差能看出 id 是否存在；「发一句」的长度 Mac 按字符数、手机按 UTF-16 计；`ResultReason.expired` 定义了但从不产生。（“不 trim 就转发”：`BridgeController.say` 已经 trim 后再发，台账写“已不复现”。）

**Interfaces:**
- Produces:
  - `DeviceRegistry.load()`：文件存在但读不出或解不开时，把它改名为 `devices.json.corrupt-<毫秒>` 放在旁边，记一条日志，返回空列表（之后的添加写新文件，坏文件保留可查）。
  - `DeviceRegistry.verify(id:token:)`：不管 id 存不存在都算一次 token 的哈希、做一次定长比较（不存在时和一个固定的假哈希比），再返回结果。
  - 「发一句」按 UTF-16 码元计数（`text.utf16.count`），和手机一致；协议文档写明“至多 4000 个 UTF-16 码元（trim 之后）”。手机发得出的 Mac 都收，旧手机不受影响。
  - `expired`：回答一个 `expiresAt` 已过的请求时，Mac 回 `ok: false, reason: expired`（检查放在 `CritterCore` 的 `BridgeConnection` 里，或 `BridgeServices.pendingRequest` 把过期的当成不存在但带上过期标记——取能在 `BridgeConnectionTests` 里测的那种）。协议文档的 `expired` 说明照实写。

- [ ] **Step 1: 核对**各条（附录 M10、M11）。
- [ ] **Step 2: 写测试**：
  - `PairingTests.corruptRegistryIsSetAside`：写一个坏的 `devices.json` → `add` 一台设备 → 新文件里只有这一台、目录里有一个 `devices.json.corrupt-*` 内容和原来一样。
  - `PairingTests.unknownIdStillHashes`：用一个注入的哈希计数器（或把哈希函数作为参数）断言未知 id 时也算了一次哈希。
  - `BridgeConnectionTests.sayCountsUTF16Units`：2000 个 emoji（每个 2 个 UTF-16 码元，共 4000）通过；再加一个就被拒（`invalid`）。
  - `BridgeConnectionTests.answerToAnExpiredRequestSaysExpired`：`expiresAt` 在过去的请求，回答得到 `reason == .expired`，答案没有写入。
- [ ] **Step 3: 跑测试，确认失败。**
- [ ] **Step 4: 实现**，更新协议文档；手机端已经能处理 `expired`（`ResultReason.expired`），确认 `AnswerActivity` 对它显示 `message`（没有就“这个请求已经过期了”）。
- [ ] **Step 5: 跑全部测试**（Swift 和 Android 两边），通过。
- [ ] **Step 6: 提交**（按条目分提交）。

### Task 9: 拆 `BridgeController`、去重、开发用客户端

**Files:**
- Create: `Sources/CritterCore/Bridge/SnapshotAssembler.swift`、`Sources/CritterCore/Bridge/LANAddress.swift`、`Sources/CritterCore/Hex.swift`
- Modify: `Sources/CritterApp/Bridge/BridgeController.swift`、`Sources/CritterApp/Bridge/BridgeServer.swift`、`Sources/CritterApp/Bridge/BridgeIdentity.swift`、`Sources/CritterCore/PendingRequest.swift`、`Sources/CritterCore/Bridge/Pairing.swift`、`Sources/CritterApp/AppDelegate.swift`、`Sources/critter-bridge-client/main.swift`
- Test: 新增 `Tests/CritterCoreTests/SnapshotAssemblerTests.swift`、`LANAddressTests.swift`、`HexTests.swift`

台账条目：`BridgeController` 混了生命周期、快照组装和缓存、配对和 `getifaddrs`（现在 560 行），可拆出 SnapshotAssembler 和 LANAddress；SHA-256 十六进制、`inet_ntop`、版本字符串的代码有重复；开发用客户端从两个线程退出。行为一律不变。

**Interfaces:**
- Produces:
  - `SnapshotAssembler`（`CritterCore`）：接手 `buildSnapshot`、分支缓存、用量估算缓存和 `tail`（现在 `BridgeController.swift` 324–395 行），输入是会话列表、状态栏记录、待答请求和偏好，依赖（读分支、读用量文件、取文件修改时间、现在几点）作为参数注入。`BridgeController` 只持有一个实例并转调。
  - `LANAddress.current(interfaces:)`（`CritterCore`）：接手 `getifaddrs` 那一段（530–551 行），把“从接口列表里挑地址”的规则做成可传入假接口列表的纯函数。
  - `Hex.sha256(_ data: Data) -> String`：四处 SHA-256 十六进制都改用它；`IPAddress.string(_ addr:)`：两处 `inet_ntop` 改用它；`AppVersion.current`（`CritterApp`）：两处版本字符串改用它。
  - `critter-bridge-client`：所有退出走同一个 `finish(_ code: Int32)`，第一次调用生效，之后的调用直接返回（用锁或原子标志）。

- [ ] **Step 1: 写测试**：`SnapshotAssemblerTests` 把 `BridgeController` 现在的组装行为固定下来（同一组输入得到和现在一样的快照：分支来自缓存、文件没变时不重读、用量估算按大小和修改时间缓存）；`LANAddressTests.prefersAPrivateIPv4OnAnActiveInterface`（跳过回环、跳过非私有段、多个时按现有顺序取第一个）；`HexTests.sha256OfABC`：`"abc"` → `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`。
- [ ] **Step 2: 跑测试，确认失败。**
- [ ] **Step 3: 搬代码**：只搬不改逻辑；搬完 `BridgeController` 少于 400 行。
- [ ] **Step 4: 跑全部测试**，通过；`swift build` 无新警告；`make app` 能打包，装上后手机能连上、能作答（手动核对一次）。
- [ ] **Step 5: 提交**（拆分、去重、客户端各一个提交）。

### Task 10: 偏弱和不稳的测试、协议文档示例

**Files:**
- Modify: `Tests/CritterCoreTests/AskDecisionTests.swift`、`StatusLineTests.swift`、`Tests/CritterHookTests/HookBinaryTests.swift`
- Create: `Tests/CritterCoreTests/ProtocolDocExamplesTests.swift`、`android/core/src/test/kotlin/local/critter/core/protocol/ProtocolDocExamplesTest.kt`

台账条目：缺测试或测试偏弱：`matchKeyIgnoresKeyOrder`、`statusLineRejectsBadSessionId`、超长输入截断、`binaryAskWithoutAppExitsFast` 的 1 秒时限在并行测试下不稳；没有测试把协议文档里的示例和解码器对上。

- [ ] **Step 1: 改测试**：
  - `matchKeyIgnoresKeyOrder`：用 8 个以上的键、嵌套对象和数组，两种顺序由 JSON 文本（而不是字典字面量）解析得到，断言键相同。
  - `statusLineRejectsBadSessionId`：断言 `critterHome` 下（而不是它的上一级）没有出现任何 `x.json` 或子目录，并加一个合法 id 的对照，证明同样的写法在合法时确实会写文件。
  - 截断：`displayInputTruncatesLongContentButNotCommand` 旁边加 4096/4097 字边界、嵌套对象和数组里的长字符串、由多个 Unicode 标量组成的字（例如带肤色的 emoji）不被切开。
  - `binaryAskWithoutAppExitsFast`：时限放宽到 5 秒（仍远小于 590 秒的等待），并断言退出码和“没有等待”的输出，而不是只看时间。
- [ ] **Step 2: 协议文档示例**：两个测试都读 `docs/critter-bridge-protocol.md`（Swift 用 `#filePath` 找仓库根；Kotlin 用相对 `android/core` 的 `../../docs/…`），取出每个单行 JSON 示例和多行的快照示例，按 `type` 交给对应的解码器（客户端发的给 `ClientMessage`，Mac 发的给 `ServerMessage`），断言都能解出、再编码后键集合相同。解不开的示例说明文档或解码器有一边错了：改对的那一边，并在提交说明里写清楚。
- [ ] **Step 3: 跑全部测试**（`swift test` 跑两遍、`./gradlew :core:test`），全部通过。
- [ ] **Step 4: 提交**。

### Task 11: 台账收尾

- [ ] **Step 1**：`docs/critter-phone-backlog.md` 第三部分每一条后面写上处理结果：提交号，或“已不复现：<证据>”，或“按设计如此：<理由>”。
- [ ] **Step 2: 提交**：`docs: phone backlog closed out`

---

## 附录：Mac 端调查结论（2026-10-19，`f7cabcf`，只读调查）

- M1 uninstall.sh stops when wrapper present but hook gone: present, deliberate (README:129); scripts/uninstall.sh:16-40; still_wrapped greps "critter-hook' statusline".
- M2 second answer after first taken briefly ok: present; BridgeConnection.swift:116-128 → BridgeController.submitAnswer 482-488 → PendingStore.writeAnswer PendingRequest.swift:138-154; hook removes request then answer (106-111). Fix in PendingStore: after write, if request gone → remove answer, return alreadyAnswered. Test model PendingStoreTests.secondAnswerIsRefused (44).
- M3 lossy UTF-8: StatusLineCommand.swift:59 String(decoding:) → HookResult.stdout String (main.swift:37-39 writes utf8); HookCommand.swift:125 settings.json String(decoding:) then splice & write Data(updated.utf8). HookResult(stdout) used ~25 places; option: add raw Data field for statusline only. settings: refuse if not valid UTF-8 ("不是有效的 UTF-8，没有改动"). Tests StatusLineTests (FakeShell Data) statusLinePassesOriginalExitCode (90); StatusLineInstallerTests cliInstallWritesBackupAndSettings (193).
- M4 atomicWrite StateStore.swift:13-30: setAttributes throw leaves temp; temp written default mode. Backup HookCommand.swift:141-142 no permissions → 0644; settings mode read at 143. Fix: create temp with attributes (like writeAnswer) + defer cleanup; backup uses original mode or 0600. Test: assert backup mode in cliInstallWritesBackupAndSettings.
- M5 install not idempotent for changed hook path: StatusLineInstaller.unwrap (32-49) only recognises current hookPath → nests. uninstall CRITTER_HOME half: consistent/fixed (install.sh also ignores CRITTER_HOME, README:403). Need path-agnostic recogniser; tests near unwrapRejectsHandEditedWrappers (46), installIsIdempotent (118); README 227-234.
- M6 ContextUsage.swift:19-33 lastUsage returns zero-sum usage; should skip to earlier; all zero → nil. Tests ContextUsageTests usageFromLastAssistantLine (5).
- M7 AskDecision.swift: answers validated trimmed (42-45) but output untrimmed (67-70); plan revise message untrimmed in output (75) vs trimmed check (49). Doc protocol:108 says "at most 4000 characters (after trimming)". Fix: trim in output. Tests AskDecisionTests planReviseNeedsMessage (89), questionAnswerMustCoverEveryQuestion (67).
- M8 HookCommand.runEvent 153-203: second JSON parse (187), PendingResolution.apply every event (MatchKey SHA-256, readAll listing). Fix: pending dir missing/empty → return early; parse only for relevant events. Tests PendingResolutionTests postToolUseResolvesMatchingRequestOnly (39), otherEventsLeavePendingAlone (99), eventStillPrintsNothing (108).
- M9 createDirectory attributes only on create (PendingRequest.swift:178-182, Inbox.swift:33-36, BridgeController.startWatchers 315-317); temp file 0644 window (M4). Fix: chmod 0700 on each write; temp mode fix. Tests storeRoundTripAndPermissions (24), InboxTests sessionStartWritesInboxFromEnvironment (28) + pre-created 0755 dir.
- M10 DeviceRegistry Pairing.swift:147-150 load() returns [] on corrupt → add/update overwrite. verify (124-128) early return on unknown id (timing). Fix: move corrupt file aside (devices.json.corrupt-<ts>), verify always hashes + constant-time compare against a dummy. Tests PairingTests registryAddVerifyRevoke (30).
- M11 say length unit: Mac grapheme count (BridgeConnection.swift:132-136), Android UTF-16 (stricter) — doc protocol:124 no unit. Trim before forward: partly fixed (controller trims). ResultReason.expired never produced (BridgeProtocol.swift:35, Android Messages.kt:70, doc 263); pendingRequest (BridgeController 471-473) ignores expiresAt. Test model BridgeConnectionTests sayValidatesLengthAndMapsOutcome (158).
- M12 late pairing allow approving another phone: FIXED (lastClientNumber never reset, BridgeController 64-66, 222-225; BridgeServer 36-38, 232; commit 5030481).
- M13 BridgeController 560 lines; SnapshotAssembler candidate 324-395, LANAddress 530-551 (getifaddrs); SHA-256 hex dup in PendingRequest.swift:72-73, Pairing.swift:158, BridgeIdentity.swift:71, critter-bridge-client/main.swift:113; inet_ntop dup BridgeController 542-544 & BridgeServer 391-398; version string dup BridgeController 106 & AppDelegate 526. critter-bridge-client exits from several threads (fail() from timer/URLSession delegates vs main exit). CritterApp has no test target (Package.swift: CritterCoreTests, CritterHookTests only).
- M14 weak tests: matchKeyIgnoresKeyOrder (AskDecisionTests:101) weak (same-process dict order); statusLineRejectsBadSessionId (StatusLineTests:79) vacuous; truncation tests lack boundaries; binaryAskWithoutAppExitsFast (HookBinaryTests:83, <1.0 s at 118) flaky under parallel runs → widen to 5 s; no doc-example decoder test (docs ~17 JSON examples lines 63-260 + snapshot ~165; model BridgeProtocolTests serverSnapshotEncodesDocumentedShape 62).
