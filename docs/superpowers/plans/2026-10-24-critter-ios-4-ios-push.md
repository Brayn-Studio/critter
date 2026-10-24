# Critter 手机端 · iOS 计划 4：iOS 推送、实时活动和首次引导 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 iPhone 在 App 没开着、手机锁着时也能收到 Mac 推来的"等你确认"，并且可以直接在通知上允许或拒绝。具体包括：
- 灵动岛、锁屏和待机模式里的实时活动；
- 首次引导；
- 设置里补上推送、实时活动、提醒三组。

另外做掉两样东西：
- `docs/critter-ios-backlog.md` 里"iOS 推送与扩展计划（App Group）"一组；
- 计划 3 的最终审查留下、明确指派给这份计划的 Mac 端修复（见 Task 1）。

**这份计划只在模拟器上做和验证。** 下面这些都放在装真机那份计划（计划 5），每一步都要先征得用户同意：
- 在 Apple 开发者账号里登记 App ID、打开推送能力；
- 拿 `.p8` 真的经过 APNs 发推送；
- 装到用户的 iPhone。

模拟器上用 `xcrun simctl push` 直接投递本地构造的推送载荷来验证；它不经过 APNs，也不需要账号。

**Architecture:**
- **纯逻辑放 `CritterClient`**（在 Mac 上 `swift test`）：
  - 什么时候发推送登记、上次 Mac 确认过什么；
  - 从通知按钮到 `answer` 的转换；
  - 后台一次性连接送答案、结果怎么写成通知；
  - App 在前台时哪些推送不显示横幅；
  - 回到前台时撤回哪些通知。
- **平台代码放 App 和两个新扩展**：
  - `CritterNotify`：通知服务扩展，解密；
  - `CritterWidgets`：小组件扩展，只放实时活动。
- **共享存储**：
  - 配对信息、快照、自定义形象、扩展也要读的设置，放 App Group 容器 `group.com.braynlabs.critter`；
  - 设备令牌和推送密钥放共享钥匙串，可访问性为"首次解锁后、仅本机"。
- 推送载荷、加密、实时活动内容的格式全在 `CritterKit/Push/`（计划 3 已建好），App 和扩展直接用，不另写一份。

**Tech Stack:** Swift 6、SwiftUI；UserNotifications、ActivityKit、WidgetKit、Security、CryptoKit。不加第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-23-critter-ios-design.md` §2、§3（目标 5、6）、§4、§6.2、§6.5、§6.6、§8.1、§8.3（后台作答、推送登记的重发）、§8.5、§8.7、§8.8、§9、§10、§11、§12、§13、§14 第 5 步。

视觉以视觉设计 `docs/superpowers/specs/2026-10-19-critter-phone-visual-design.md` §8.2（引导、种子进度）、§8.4（"一堆"的画法，实时活动沿用）、§8.8（设置）和草图为准。

协议以 `docs/critter-bridge-protocol.md` 为准，尤其是"iOS push registration"一节：
- 字段；
- 撤销登记只能发空 token；
- 推送载荷的键；
- 加密时的关联数据是 `k|r|s`；
- `LiveActivityContent`；
- 实时活动的 `attributes-type` 叫 `CritterActivity`。

**参考实现：** 首次引导和设置照 Android（`android/app/src/main/kotlin/local/critter/phone/onboarding/`、`ui/settings/SettingsScreen.kt`）。通知文案照 Android `service/Alerts.kt` 和 spec §8.7。

**前提：** 计划 3（分支 `ios-mac-push`）已经合回 `main`。

## Global Constraints

- 计划 1、2 的全局约束继续有效：iOS 17.2、只支持 iPhone、Swift 6、没有第三方依赖、文案逐字照抄 Android；Mac 端在没配置推送时行为不变；`swift test` 原有测试全过（已知的两个 Codex 发现测试除外）；`make app` 照常构建。
- **不登记、不下载任何东西到开发者账号**：
  - 构建只用模拟器目标；
  - 不加 `-allowProvisioningUpdates`；
  - 不用 Xcode 的"自动管理签名"去注册 App ID、App Group 或推送能力。
  - entitlements 文件写进工程（`aps-environment = development`、App Group、钥匙串共享组），模拟器构建用本地签名。
  - 如果某样能力在模拟器上不登记就用不了，停下来报告，不要自己去登记。
- **通知内容只在扩展里解密**：
  - 推送的明文只有"Critter / 有会话需要你"，解密失败就保留它；
  - 密钥只在共享钥匙串里，不写进 App Group 文件，不打日志。
- **通知按钮都要先解锁**（`.authenticationRequired`）。
- **后台作答整个过程最多 20 秒**（连接、`hello`、`answer`、`result`），然后断开。送不到时，结果通知写"没送到：连不上 Mac（要和电脑在同一个 Wi‑Fi）"，原来的按钮保留。
- **实时活动的内容里没有任何文字**（只有形象、状态、数量、百分比、时间），界面上的固定字（"点开查看"、"可能不是最新的"）写在小组件里，不来自推送。
- **省电**（spec §9）：
  - 不用后台刷新、后台定位、静音音频保活；
  - 后台作答只在用户点按钮时连一次；
  - 实时活动只在内容变化时由 Mac 更新，App 不在后台更新它。
- 只用命令行操作模拟器（`xcrun simctl`：`boot`、`install`、`launch`、`push`、`io screenshot`、`ui appearance`、`spawn … log`），不用任何驱动窗口的办法。模拟器 iPhone 17 Pro · iOS 27.0，UDID `CEE21FEB-932A-4463-92C6-5BE5A48E0584`。
- 不碰用户正在运行的 Critter（不重启、不替换、不改 `~/.critter`）。要连真的 Mac 时，照计划 1、2 的做法临时打开 `debugEnabled`、跑完删掉。
- 每个新画面、新状态都要有 DEBUG 启动参数能直接打开（写进 `DebugLaunch.swift` 的文件注释）。Release 构建不含 DEBUG 代码。

## Review Focus

1. **通知按钮作答时 Mac 连不上**（手机在外面、Mac 睡了）。20 秒内一定给出结果通知"没送到…"，原来的按钮还能再点，App 不会一直挂在后台。由 Task 2 的 `backgroundAnswerGivesUpAfter20Seconds` 覆盖。
2. **请求已经在电脑上处理了，用户才点通知上的「允许」。** 结果通知写"已在电脑上处理"，绝不能显示"已允许"。由 Task 2 的 `aResolvedRequestReadsAsHandledElsewhere` 覆盖。
3. **推送密钥或令牌在锁屏时读不到**（扩展在设备锁着时运行）。钥匙串可访问性必须是"首次解锁后"，读不到时显示通用文字，不能崩溃。由 Task 4 的存储测试和 Task 5 的 `undecryptableShowsTheGenericText` 覆盖。
4. **旧版 Mac 不认识推送登记。** 手机等 10 秒没回复，设置里写"这台 Mac 上的 Critter 版本太旧，收不到推送"，连接不断开，下次连上不再反复发（同一个 Mac 版本只试一次）。由 Task 2 的 `anOldMacIsTriedOncePerVersion` 覆盖。
5. **取消配对或关掉推送后，Mac 还在推。** 取消配对前先尽量发空 token 撤销登记，关掉所有提醒和实时活动时也发空 token。由 Task 2 的 `everythingOffSendsAnEmptyToken` 和 Task 10 的接线覆盖。

## 执行分批

| 批次 | 任务 | 验证方式 |
|---|---|---|
| P1 Mac 遗留与手机逻辑 | 1–2 | `swift test`、`make app` |
| P2 存储与扩展骨架 | 3–4 | `swift test`、`make ios-sim`、能力实测 |
| P3 通知 | 5–6 | `make ios-sim`、`simctl push` |
| P4 实时活动 | 7–8 | 模拟器截图 |
| P5 引导与设置 | 9–10 | 模拟器截图 |
| 收尾 | 11 | 走查、联机、文档 |

---

## 文件结构

```
Sources/CritterCore/Push/…、Sources/CritterApp/Bridge/…   Task 1 的 Mac 端修复
Sources/CritterClient/Push/
  PushRegistrar.swift          何时发登记、上次确认的内容、旧 Mac 的判断（Task 2）
  BackgroundAnswer.swift       一次性连接送答案、20 秒、结果文字（Task 2）
  NotificationAnswer.swift     通知按钮 → AnswerPayload（Task 2）
  NotificationRules.swift      前台不显示横幅、回前台撤回（Task 2）
Sources/CritterClient/Store/…  存储接口按需调整（Task 4）
ios/Config/
  Critter.entitlements CritterNotify.entitlements CritterWidgets.entitlements   （Task 3）
  CritterNotify-Info.plist CritterWidgets-Info.plist                          （Task 3）
ios/Critter/Platform/
  SharedContainer.swift        App Group 路径、共享钥匙串（Task 4）
  KeychainPairingStorage.swift 改：搬进共享位置；先写令牌再写配对（Task 4）
  PushSetup.swift              通知权限、设备 token、推送密钥（Task 6）
  NotificationCenterDelegate.swift  类别、按钮、前台展示、撤回、点开（Task 6）
  LiveActivityManager.swift    启动、token、结束（Task 8）
ios/CritterNotify/NotificationService.swift          （Task 5）
ios/CritterWidgets/CritterWidgets.swift CritterActivityViews.swift   （Task 7）
ios/Shared/CritterActivity.swift   App 和小组件共用的 ActivityAttributes（Task 7）
ios/Critter/Onboarding/…           欢迎页、步骤、种子（Task 9）
ios/Critter/Settings/SettingsView.swift  改：推送、实时活动、提醒（Task 10）
scripts/dev/push-payloads/…  给 simctl push 用的载荷生成脚本（Task 5、6）
```

---

## 批次 P1：Mac 遗留与手机逻辑

### Task 1: 计划 3 指派过来的 Mac 端修复

**Files:** `Sources/CritterCore/Push/{PushFanout,LiveActivityPlanner}.swift`、`Sources/CritterCore/Bridge/{Pairing,BridgeConnection}.swift`、`Sources/CritterApp/Bridge/{PushCoordinator,BridgeController}.swift`、`docs/critter-bridge-protocol.md`；测试在 `Tests/CritterCoreTests/`

计划 3 的台账（主仓库 `.superpowers/sdd/2026-10-24-critter-ios-3-mac-push/progress.md`，不进 git）里标了"parked → plan 4"的几条：

- **（必须先做）写不进 `devices.json` 时无限递归。**
  - 调用链：`keepRegistryEdits` → `onRegistryChanged` → `refreshDevices` → `sync` → `noteStarts` → `keepRegistryEdits`。
  - 只在写入成功时刷新；失败时丢掉这次修改并记日志，不要重新排队。
  - 加测试：注入一个写入总是失败的设备表，调用不会递归、不会崩溃。
- 送不出去的"启动实时活动"被 APNs 拒收后，要马上把"等 token 的启动"清掉并写盘，不要等下一份快照。
- 实时活动的启动规则和协议文档对齐：
  - 关掉手机连接时，也算放开"等 token 的启动"，在文档里写上；
  - 因为配置错误、网络错误没送出去的启动，不应挡住后面的启动 8 小时，改成和被拒收一样处理，并补测试；
  - 7.5 小时时 `forget()` 之后，给 8 小时那一刻排一个期限。
- **推送登记的 `result` 带上 Mac 的推送状态**（新增，spec §8.8"Mac 是否配置好了推送"）：
  - `ok` 回复的 `message` 写"已登记"或"已登记；这台 Mac 还没配置推送"；
  - 写进协议文档，并补编解码测试；
  - 手机端按 `message` 显示（Task 2）。

- [ ] **Step 1:** 每条先写失败的测试，再修。
- [ ] **Step 2: Run** `swift test`、`make app`。Expected: 通过；只有那两个 Codex 测试失败。
- [ ] **Step 3: Commit**（可以分几次提交）。

### Task 2: 手机端的推送逻辑

**Files:** `Sources/CritterClient/Push/{PushRegistrar,BackgroundAnswer,NotificationAnswer,NotificationRules}.swift`、`Sources/CritterClient/Store/BridgeStore.swift`（接线）；测试 `Tests/CritterClientTests/{PushRegistrar,BackgroundAnswer,NotificationAnswer,NotificationRules}Tests.swift`

**Interfaces:**
- `PushRegistrar`（纯值类型 + 一个保存"上次确认"的协议）：
  - 输入：本机设备 token（可能还没有）、环境、bundle id、推送密钥、提醒开关（做完了、出错）、实时活动（开关、push-to-start token、当前活动 id 和 token）。
  - `registration() -> PushRegistration`：通知和实时活动全关时返回空 token。
  - `shouldSend(acked:macVersion:)`：和上次 Mac 确认过的不同才发；同一个 Mac 版本已经 `.noReply` 过就不再发。
  - `record(reply:macVersion:)`：记下结果，`.stored` 时保存这次的登记。
  - 状态文字：
    - "已登记"，或者 Mac 回的那句；
    - "这台 Mac 上的 Critter 版本太旧，收不到推送"；
    - "还没登记（要连上 Mac）"；
    - "通知被关掉了，去系统设置打开"。
- `NotificationAnswer.payload(action:text:kind:acceptsDenyMessage:) -> AnswerPayload?`：
  - 「允许」、「拒绝」、「拒绝并写理由…」（带输入框的文字）对应权限请求；
  - Codex 的请求没有写理由（spec §8.7），收到写理由的动作也只当「拒绝」；
  - 提问和计划没有按钮作答，返回 nil，只能打开卡片。
- `BackgroundAnswer.send(_ payload:, requestId:, pairing:, transport:, clock:) async -> BackgroundAnswerResult`：
  - 用配对信息开一条新连接，`hello` 后发 `answer`，等 `result`；
  - 整个过程最多 20 秒，结束后一定断开；
  - 和前台的 `BridgeClient` 互不影响，前台连着时也照样走这条。
- `BackgroundAnswerResult.notificationText -> (title, body)`：
  - 成功是"已允许"或"已拒绝"；
  - `resolved` 是"已在电脑上处理"；
  - `expired` 是"已经过期了"；
  - 送不到是"没送到：连不上 Mac（要和电脑在同一个 Wi‑Fi）"，并带 `keepButtons = true`。
- `NotificationRules`：
  - `showBanner(requestId:snapshot:isForeground:) -> Bool`：前台、而且快照里已经有这个请求时不显示横幅，改成轻震一下；
  - `staleNotificationIds(delivered:snapshot:) -> [String]`：回到前台时要撤回的通知。按 `PushPayload.notificationId` 的规则：请求不在快照里了；`done:`、`error:`、`waitingElsewhere:` 的会话不在那个状态了。
- `BridgeStore` 接线：
  - 每次连上（`welcome` 之后），交给 `PushRegistrar` 判断是否发送；
  - 对外暴露 `pushStatus: String`，给设置显示；
  - `unpair()` 之前，在线时先发一次空 token，最多等 3 秒，然后照常取消配对。

- [ ] **Step 1: 写测试**（用计划 1 的 `FakeMac`、可控时钟）：
  - `registrationChangesAreSentOnce`；
  - `everythingOffSendsAnEmptyToken`；
  - `anOldMacIsTriedOncePerVersion`；
  - `theMacsStatusLineIsShown`；
  - `allowDenyAndReasonMapToAnswers`；
  - `codexHasNoReasonButton`；
  - `questionsAndPlansHaveNoNotificationAnswer`；
  - `backgroundAnswerSendsAndCloses`；
  - `backgroundAnswerGivesUpAfter20Seconds`；
  - `aResolvedRequestReadsAsHandledElsewhere`；
  - `anExpiredRequestSaysSo`；
  - `nothingIsSentBeforeWelcome`（后台连接同样遵守）；
  - `aRequestAlreadyOnScreenDoesNotBanner`；
  - `staleNotificationsAreWithdrawnOnForeground`；
  - `unpairUnregistersFirstWhenOnline`。
- [ ] **Step 2: Run** `swift test --filter 'PushRegistrar|BackgroundAnswer|NotificationAnswer|NotificationRules|BridgeStore'`。Expected: 新测试 FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 完整的 `swift test`。Expected: 通过。
- [ ] **Step 5: Commit** `git commit -m "feat(client): push registration, answers from notifications, background answers"`

---

## 批次 P2：存储与扩展骨架

### Task 3: 两个扩展和 entitlements

**Files:** `ios/Critter.xcodeproj/project.pbxproj`、`ios/Config/*.entitlements`、`ios/Config/{CritterNotify,CritterWidgets}-Info.plist`、`ios/Config/*.xcconfig`、`ios/CritterNotify/`、`ios/CritterWidgets/`、`ios/Shared/`

- 新 target：
  - `CritterNotify`：Notification Service Extension，bundle id `com.braynlabs.critter.notify`；
  - `CritterWidgets`：Widget Extension，只放实时活动，bundle id `com.braynlabs.critter.widgets`。
  - 两者都嵌进 App，依赖 `CritterKit`（`CritterWidgets` 还要 `SkinRenderer` 画图；`CritterNotify` 只要 `Push/`）。
  - 扩展的最低系统同 App（17.2）。
- `ios/Shared/` 用文件夹同步分组，加进 App 和 `CritterWidgets` 两个 target，放 `CritterActivity.swift`（Task 7）。
- entitlements：
  - App：`aps-environment = development`、App Group、钥匙串访问组；
  - `CritterNotify`：App Group、钥匙串访问组；
  - `CritterWidgets`：App Group。
- App 的 Info.plist：`NSSupportsLiveActivities = YES`、`NSSupportsLiveActivitiesFrequentUpdates = YES`、`UIBackgroundModes = [remote-notification]`（只用于撤回推送，spec §8.7）。
- 签名：照现有 xcconfig 的做法，模拟器构建本地签名；不加 `-allowProvisioningUpdates`，不让 Xcode 去账号里注册东西。
- `make ios-sim` 构建全部三个 target。

- [ ] **Step 1: 实现**（工程文件小心改：唯一的 24 位 ID，沿用现有写法）。
- [ ] **Step 2: Run** `make ios-sim`、Release 构建。Expected: 成功；`Critter.app/PlugIns/` 里有 `CritterNotify.appex`、`CritterWidgets.appex`；`codesign -d --entitlements :- <各个 bundle>` 显示上面的 entitlements。
- [ ] **Step 3: Commit** `git commit -m "feat(ios): notification service and widget extensions, entitlements"`


### Task 4: 存储搬到 App Group 和共享钥匙串

**Files:** `ios/Critter/Platform/{SharedContainer,KeychainPairingStorage,PhoneSettings}.swift`、`ios/Critter/Critter/SkinStore.swift`、`Sources/CritterClient/Store/*`（如需）；测试放在 `CritterClient`（能抽成纯逻辑的部分）

台账"iOS 推送与扩展计划（App Group）"一组的前五条，加上搬家：

- **先实测（Step 1）：** 在模拟器上，不登记任何东西、只靠工程里的 entitlements 和本地签名，能不能做到这两件事：
  - App 和通知服务扩展读写同一个 App Group 容器；
  - 读到同一个钥匙串访问组里的条目。

  用 Task 3 建好的扩展写一个最小的 DEBUG 检查（`-critterSharedCheck`），App 和扩展各写一个标记、互相读。做不到就停下来，报告 BLOCKED 和具体的错误，不要换成别的存储方式。
- `SharedContainer`：
  - App Group 容器的目录：`Pairing/`、`Snapshot/`（不进备份）、`Skins/`；
  - 共享的 `UserDefaults(suiteName:)`，给扩展也要读的设置用；
  - 钥匙串访问组 `$(AppIdentifierPrefix)com.braynlabs.critter.shared`。
- 配对令牌和推送密钥放钥匙串，可访问性 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。配对记录（地址、端口、指纹、Mac 名字、deviceId）放 App Group。
- 快照缓存最多约 30 秒写一次，退到后台时补写（Android 也是每 30 秒最多一次）。
- 重新配对时删旧缓存要同步完成，或者和写入排在同一个队列里，保证不会读到上一台 Mac 的快照。
- 写令牌：先写新令牌，成功了再写配对记录，失败就不动旧的。
- `BridgeStore.pair` 在 store 里防重入：配对进行中再调用，直接返回"正在配对"。
- 设置里扩展要读的几项（实时活动开关、提醒开关）搬到共享的 `UserDefaults`，其余照旧。
- 还没有装到真机过，所以不做旧数据迁移，模拟器里旧的位置直接不再读。

- [ ] **Step 1:** 实测（见上）。
- [ ] **Step 2: 写测试**：`snapshotWritesAreThrottledTo30Seconds`、`backgroundFlushesThePendingSnapshot`、`repairingNeverShowsTheOldMacsSnapshot`、`aFailedTokenWriteKeepsTheOldPairing`、`pairIsNotReentrant`。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** `swift test`、`make ios-sim`、Release 构建，再用 `-critterFixture home-mixed` 和真的配对流程（`-critterPairURI` 配一台临时设备，见计划 1）各跑一次。Expected: 配对、重启后仍是已配对、首页显示快照。
- [ ] **Step 5:** 台账里删掉做完的条目。
- [ ] **Step 6: Commit** `git commit -m "feat(ios): pairing, snapshot and keys live in the App Group and the shared keychain"`

---

## 批次 P3：通知

### Task 5: 通知服务扩展解密

**Files:** `ios/CritterNotify/NotificationService.swift`、`scripts/dev/push-payloads/`（生成测试载荷的小脚本，可以是一个 `swift` 脚本或 `critter-bridge-client` 的新子命令）

- `didReceive`：
  - 用 `PushPayload.parse` 读出类别、请求 id、会话 id 和密文；
  - 从共享钥匙串取推送密钥；
  - 用 `PushCrypto.open(_:key:)` 解开（关联数据 `k|r|s`），换掉标题、副标题和正文；
  - 设 `threadIdentifier` = 会话 id、`categoryIdentifier` = 类别；
  - 等你确认的请求用 `interruptionLevel = .timeSensitive`。
  - 解不开、没有密钥、格式不对时，保持原来的"Critter / 有会话需要你"，类别照设，按钮照样能用（spec §11）。
- `serviceExtensionTimeWillExpire`：交出当前最好的版本。
- 载荷脚本：给定会话 id、请求 id、类别和文字，用一个测试密钥封出和 Mac 完全一样的 APNs JSON（`mutable-content: 1`），写成 `simctl push` 能用的 `.apns` 文件（带 `Simulator Target Bundle`）。用 DEBUG 参数 `-critterTestPushKey <base64url>` 把同一个测试密钥写进共享钥匙串。

- [ ] **Step 1: 写测试**：解密和类别选择抽成 `CritterClient` 或 `CritterKit` 里的纯函数，测 `opensWhatTheMacSealed`、`undecryptableShowsTheGenericText`、`aMovedCiphertextDoesNotOpen`。
- [ ] **Step 2: 实现。**
- [ ] **Step 3: 模拟器验证：**
  - `xcrun simctl push <UDID> com.braynlabs.critter <file>.apns`，每种类别一条，加一条密文是坏的；
  - App 退到后台和锁屏（`xcrun simctl spawn <UDID> notifyutil -p com.apple.springboard.lockcomplete` 不一定管用，做不到就只测后台），各截图。
  - Expected: 显示解密后的标题和正文；坏的那条显示通用文字。
  - 如果这个模拟器上 `simctl push` 不调起通知服务扩展，就在报告里写明，靠 Step 1 的测试，并把"真机上解密"写进计划 5 的检查点。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the notification service extension decrypts pushes"`

### Task 6: 通知类别、按钮、点开、撤回、推送登记

**Files:** `ios/Critter/Platform/{PushSetup,NotificationCenterDelegate}.swift`、`ios/Critter/CritterApp.swift`、`ios/Critter/Home/HomeView.swift`（从通知打开卡片）

- **类别**（spec §8.7，类别 id 用 `PushCategory` 的原始值）：
  - `permission`：「允许」「拒绝」「拒绝并写理由…」（`UNTextInputNotificationAction`），三个都 `.authenticationRequired`；
  - `permissionNoReason`：「允许」「拒绝」；
  - `question`、`plan`：「打开」（`.foreground`）；
  - `waitingElsewhere`、`done`、`error`、`test`：没有按钮。
- **权限和 token**：
  - 首次引导里请求通知权限（Task 9），设置里能补；
  - 有权限后调 `registerForRemoteNotifications`；
  - 设备 token 转成十六进制；
  - 推送密钥第一次用时生成（`PushCrypto.makeKey()`），存共享钥匙串；
  - 环境：DEBUG 构建是 `sandbox`。
  - 拿到或改变 token 时交给 `PushRegistrar`。模拟器拿不到 token 时，在报告里写明，用 DEBUG 参数 `-critterFakeDeviceToken <hex>` 走完登记流程。
- **按钮作答**：
  - 在 `userNotificationCenter(_:didReceive:)` 里用 `NotificationAnswer` 得到答案，交给 `BackgroundAnswer` 发送；
  - 系统给的后台时间内用 `beginBackgroundTask` 撑住；
  - 结束后用同一个通知 id 换一条结果通知。送不到时保留原来的类别，按钮还能再点。
- **点通知正文或「打开」**：App 回到前台，打开对应 requestId 的作答卡片（卡片仍按 requestId 从快照取，请求不在了就显示"已在电脑上处理"）。会话通知（做完了、出错、请在电脑上处理）打开那个会话的详情。
- **前台**：`willPresent` 里用 `NotificationRules.showBanner`。不显示横幅时轻震一下（`UIImpactFeedbackGenerator`）。
- **撤回**：
  - 收到 `content-available` 的撤回推送（`w` 键）时，在 `didReceiveRemoteNotification` 里删掉对应的已送达通知；
  - 每次回到前台，并且快照到了以后，用 `NotificationRules.staleNotificationIds` 再撤一遍。
- **自动打开看板与配对页**（台账最后一条）：从通知进入时，如果配对页开着，看板的自动打开不报 `.blocked`，等首页出来再试一次。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`、Release 构建。
- [ ] **Step 3: 模拟器验证**（用 Task 5 的载荷脚本）：
  - 权限请求通知：截图下拉后的按钮；
  - 点「允许」：用 DEBUG 参数 `-critterNotificationAction <requestId>:allow` 直接走一遍处理函数，因为命令行点不了按钮；后台连接用计划 1 的 fixture 假连接，或者连真的 Mac 时用一个已经了结的请求 id，看到"已在电脑上处理"；
  - 撤回推送：通知消失；
  - 前台时同一个请求的推送：不出横幅。
  - 每一项都截图或贴日志。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): notification categories, answering from a notification, withdrawals, push registration"`

---

## 批次 P4：实时活动

### Task 7: 实时活动的样子

**Files:** `ios/Shared/CritterActivity.swift`、`ios/CritterWidgets/{CritterWidgets,CritterActivityViews}.swift`

- `struct CritterActivity: ActivityAttributes`：
  - 名字必须是 `CritterActivity`（Mac 的 push-to-start 写的就是它）；
  - `ContentState` 就是 `LiveActivityContent`，加 `Hashable` 包一层也行，但 JSON 形状不能变；
  - 属性部分为空，能从 `{}` 解码（push-to-start 时 Mac 发 `attributes: {}`）。
- **锁屏和横幅**（spec §8.5）：
  - 一小块草地上站着"一堆"小宠物：领头的在前，后两只升高、调暗，画法同视觉设计 §8.4 的悬浮球收起时；
  - 旁边是各状态的数量（状态符号加数字）；
  - 下面两条 5 小时、7 天额度的小分格条；
  - 右下角是更新时间（`Text(date, style: .relative)`）。
- **灵动岛**：
  - 紧凑：左边领头那只的代表姿势，右边最急那个状态的符号和数量；
  - 最小：只有领头那只；
  - 展开：锁屏那一块，加"点开查看"。
- **待机模式**：锁屏版式，纯黑背景，颜色用视觉设计 §5 的"看板"那套（`activityBackgroundTint`、`isLuminanceReduced` 时调暗）。
- **过期**：超过 `staleDate`（Mac 设的 15 分钟）时，界面变灰，写"可能不是最新的"。
- **宠物图片**：
  - 在扩展里用 `SkinRenderer` 画成静态图，代表姿势按状态；
  - 内置形象随扩展打包（`Skins/` 文件夹引用也加进扩展）；
  - 自定义形象从 App Group 的 `Skins/` 读，读不到用小芽；
  - 注意小组件扩展的内存上限，图片按需要的尺寸画，不缓存大图。
- 点实时活动打开 App（`widgetURL` 用 `critter://home`，不是配对链接）。

- [ ] **Step 1: 实现。** 加一个 DEBUG 参数 `-critterActivityDemo <many|waiting|idle|stale>`：App 在前台用本地数据启动一个实时活动，方便截图。
- [ ] **Step 2: Run** `make ios-sim`。
- [ ] **Step 3: 截图：** 锁屏（`xcrun simctl` 让模拟器锁屏做不到的话，截通知中心里的实时活动）、灵动岛的紧凑和展开（iPhone 17 Pro 有灵动岛），浅色和深色各一套，加一张过期的。和视觉设计的悬浮球"一堆"对照。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the Live Activity on the lock screen and in the Dynamic Island"`

### Task 8: 实时活动的启动、token 和结束

**Files:** `ios/Critter/Platform/LiveActivityManager.swift`、`ios/Critter/CritterApp.swift`、`Sources/CritterClient/Push/PushRegistrar.swift`（实时活动那部分）

- App 在前台、开着实时活动、快照里有会话、但没有正在运行的 `CritterActivity` 时，用快照组出 `LiveActivityContent`（和 Mac 同一个规则，函数从 `CritterCore` 搬到 `CritterKit` 共用，或者在 `CritterKit` 里补一个同名函数并测试两边一致），本地启动一个。
- 监听 `Activity<CritterActivity>.pushToStartTokenUpdates`（iOS 17.2+）和每个活动的 `pushTokenUpdates`、`activityStateUpdates`。token 变了交给 `PushRegistrar`，在线时立刻重发登记。
- 关掉设置里的实时活动开关时，结束所有 `CritterActivity`（`.immediate`），登记里写 `enabled = false`。
- App 在前台、连着 Mac 时，本地也按快照更新活动内容；内容没变就不更新。在后台时完全交给 Mac 的推送。
- 活动被系统结束或用户划掉时（`activityStateUpdates` 变成 `.dismissed` 或 `.ended`），登记里的活动 id 和 token 清掉。

- [ ] **Step 1: 测试**：`PushRegistrar` 的实时活动部分（token 变化触发重发、关掉时 enabled=false、活动结束清 token）；内容组装和 Mac 一致（同一份快照两边得到相同的 `LiveActivityContent`）。
- [ ] **Step 2: 实现。**
- [ ] **Step 3: 模拟器验证**：
  - `-critterFixture many` 启动后有实时活动；切到 `offline-idle` 内容跟着变；
  - 关掉开关后活动消失；
  - 日志里打出 push-to-start token 和活动 token，模拟器给不出就写明。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the app starts its Live Activity and hands its tokens to the Mac"`

---

## 批次 P5：引导与设置

### Task 9: 首次引导

**Files:** `ios/Critter/Onboarding/{OnboardingView,WelcomePage,StepLayout,Seeds}.swift`、`ios/Critter/RootView.swift`、`Sources/CritterClient/Presentation/OnboardingSteps.swift`（步骤和种子的纯逻辑，带测试）

**参考：**
- Android：`android/app/src/main/kotlin/local/critter/phone/onboarding/{WelcomePage,StepLayout,Seeds,OnboardingActivity}.kt`；
- 视觉设计 §8.2；
- 草图"引导"一节。

内容（spec §8.8）：
- 步骤：欢迎 → 配对 → 通知权限 → 实时活动说明 → 看板自动打开（可选，快捷指令的图解步骤）。
- 种子进度 `n / 5`：走过的发芽，当前的冒花苞，没到的是种子。
- 欢迎页：
  - 清晨草地上五只宠物用 `interactions.join` 钻出来，间隔 260 ms；
  - Logo；
  - 文案照 Android `WelcomePage.kt`（"电脑上的会话，在手机上也看得到"等）；
  - 主按钮「开始配对」，下面一行"要先在 Mac 的 Critter 里打开「允许手机连接」"。
- 每一步：一小块草地插图 + 大标题 + 一句说明 + 主按钮 + 跳过 + 跳过的后果。
- 配对步骤就是现有的配对画面，嵌进步骤外壳。本地网络的系统弹窗在第一次连接时出现，所以没有单独的一步。
- 实时活动说明：画一个锁屏和灵动岛的样子，说明它在 App 没开时也会更新，可以在设置里关掉。
- 看板自动打开：
  - 用图解步骤教用户在"快捷指令"里建个人自动化："充电器已连接 → 打开 App「Critter」"，设成立即运行；
  - 说明不建的话，充电横放时待机模式会显示实时活动；
  - 一个按钮打开快捷指令 App（`shortcuts://`）。
- 引导做完记在设置里（`onboardingDone`），之后不再出现；设置里有一行"重新看一遍引导"。
- 已经配对过的用户（模拟器里现在的状态）启动后直接到首页，不进引导。

- [ ] **Step 1: 测试** `OnboardingSteps`：步骤顺序、`n / 5`、种子三态、跳过后的位置。
- [ ] **Step 2: 实现。** 加 DEBUG 参数 `-critterOnboarding <step>` 直接打开某一步。
- [ ] **Step 3: 截图对照** 草图"引导"：每一步浅色、深色各一张。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): first-run onboarding"`

### Task 10: 设置里的推送、实时活动、提醒

**Files:** `ios/Critter/Settings/SettingsView.swift`、`ios/Critter/Platform/PhoneSettings.swift`

spec §8.8 的设置分组里计划 2 没做的三组：
- **推送**：
  - 本机登记状态（`BridgeStore.pushStatus`，含 Mac 回的状态句）；
  - 系统通知权限被关掉时，一行橙色提示和「去打开」（`UIApplication.openNotificationSettingsURLString`）；
  - "发一条测试通知"：在说明里写"在 Mac 的 Critter 设置里点「发送测试通知」"。手机没有让 Mac 发推送的协议消息，这一条不新增协议。
- **实时活动**：开关，默认开。
- **提醒**：做完了、出错，默认关，改了之后立刻重发登记。
- **连接**：「取消配对」先尽量撤销推送登记（Task 2 的接线）。
- 每组标题前一个像素图标，部件用计划 2 的那套。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: 截图对照** 草图"设置"：浅色、深色；推送状态的四种文字各一张（用 DEBUG 参数切换）。
- [ ] **Step 3: Commit** `git commit -m "feat(ios): push, Live Activity and alert settings"`

---

## 收尾

### Task 11: 走查、联机、文档

- [ ] **Step 1: 全量验证**：`swift test`、`make app`、`make ios-sim`（三个 target）、Release 构建。
- [ ] **Step 2: 走查**：新画面浅色、深色各一张；用载荷脚本把每一种推送都投一遍；截图和日志放进报告。
- [ ] **Step 3: 联机**（`debugEnabled` 打开、跑完删掉）：
  - 模拟器里的 App 用 `-critterPairURI` 配一台临时设备；
  - 拿到（或用 `-critterFakeDeviceToken` 伪造）设备 token 后，看 `~/.critter/bridge/devices.json` 里这台设备有推送登记、权限 0600，设置里写着 Mac 回的状态句（"这台 Mac 还没配置推送"）；
  - 在 App 里取消配对后，登记先被撤销；
  - 最后确认 `devices.json` 里没有留下临时设备。
- [ ] **Step 4: 文档**：
  - `docs/critter-ios-backlog.md`：删掉做完的；把只能在真机上验证的写进"装到真机的计划"，包括：
    - 真的 APNs；
    - 代理（spec §13.6）；
    - push-to-start 的 token 能不能在后台送回（§13.1）；
    - 更新预算（§13.2）；
    - 后台作答的耗时（§13.3）；
    - 时效性通知在专注模式下的表现（§13.4）；
    - 机型（§13.5）；
    - 锁屏时解密；
    - 面容 ID 后点按钮。
  - README 的 iOS 一节：通知、实时活动、首次引导、`simctl push` 的用法。
  - 协议文档如有补充。
- [ ] **Step 5: Commit** `git commit -m "docs: iOS plan 4 walkthrough, backlog and README"`
