# Critter 手机端 · iOS 计划 3：Mac 推送 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Mac 上的 Critter 在 iPhone 没开 App 时，也能通过 Apple 的推送服务（APNs）把"等你确认"、做完了、出错送到手机上，并维护灵动岛和锁屏上的实时活动。具体包括：
- 手机通过连接登记推送；
- Mac 按 Android 的提醒规则决定推什么；
- 推送内容端到端加密；
- 用 `.p8` 密钥签名发给 APNs；
- `critter-hook ask` 的门槛跟着放宽；
- Mac 设置里新增"iPhone 推送"一节。

另外做掉 `docs/critter-ios-backlog.md` 里"Mac 推送计划"一组的三条（这三条改的是手机端的连接库 `CritterClient`）。

iOS App 这边（拿设备 token、通知服务扩展解密、点通知按钮作答、实时活动的小组件扩展、首次引导）在计划 4。真的往 APNs 发推送，要用户提供 `.p8` 密钥并在开发者账号里给 App ID 开推送，所以联机验证留到计划 4。这份计划用假的传输层测完整个发送流程。

**Architecture:**
- **共享格式放 `CritterKit`**：推送登记的消息体、推送载荷的键和类别、AES-GCM 加解密、实时活动的内容（`ContentState`）、通知文字。Mac 负责编码，手机和两个扩展负责解码，两边用同一份代码。
- **Mac 的推送逻辑放 `CritterCore`**：决定推什么（`PushTracker`，照 Android 的 `AlertTracker`）、实时活动的启停和节流（`LiveActivityPlanner`）、APNs 请求的组装和签名（`APNsRequest`、`APNsToken`）。全是纯逻辑，有单元测试。
- **接线放 `CritterApp`**：`PushCoordinator` 在 bridge 的串行队列上跑，接在现有 250 ms 合并之后；`URLSession` 走 HTTP/2 发送；设置界面。
- **只加东西**：没配置推送、或者没有设备登记推送时，Mac 的行为和现在完全一样。

**Tech Stack:** Swift 6、Swift Testing；CryptoKit（`AES.GCM`、`P256.Signing`）、URLSession（HTTP/2）。不加依赖。

**Spec:** `docs/superpowers/specs/2026-10-23-critter-ios-design.md` §5、§6.2–§6.7、§7、§9（Mac 端一条）、§10、§11、§12（Mac 端单元测试）、§14 第 4 步。提醒规则照 `android/core/src/main/kotlin/local/critter/core/logic/AlertPlanner.kt`；通知文字照 `android/app/src/main/kotlin/local/critter/phone/service/Alerts.kt`。协议以 `docs/critter-bridge-protocol.md` 为准，这份计划给它加一节。

**这份计划在独立的 git worktree 里执行**（用户 2026-10-24 同意），和在 `main` 上进行的 iOS 计划 2 并行。做完后在本地合回 `main`，不推送。

## Global Constraints

- **Mac 端只加东西**：没配置推送，或者没有一台设备登记了推送时，不新增任何定时器、文件读写、快照组装和网络请求；`BridgeController.changed()` 在没有手机连着时照旧直接返回。现有测试全过（已知在这台机器上失败的两个 Codex 发现测试除外），`make app` 照常构建，Android 版和 `scripts/dev/e2e-phone.sh` 不受影响。
- **协议版本仍是 1**。推送登记是可选扩展，旧手机不发也照常工作；旧 Mac 收到会忽略（协议文档："A frame the Mac cannot decode is ignored once the connection is ready"）。
- **推送里不许有明文的会话内容**：命令、路径、问题、计划、会话名、回复、目录、分支、Mac 的名字都只能出现在密文里。明文里只允许：请求 id、会话 id、通知类别、`thread-id`（= 会话 id）、各状态的数量、形象名、额度百分比、时间戳，以及固定的"Critter / 有会话需要你"。
- **加密**：AES-GCM，256 位密钥（手机生成的 32 个随机字节，base64url 不带填充）；密文字段是 base64 编码的 `nonce ‖ ciphertext ‖ tag`（CryptoKit 的 `combined`）；明文是 JSON `{"title":…,"subtitle":…,"body":…}`。整条推送的 JSON 不超过 4096 字节，超了先截短正文再截副标题。
- **`.p8` 只放在 `~/.critter/bridge/apns/`**，权限 0600，不进仓库，不离开这台 Mac，不写进日志。
- `devices.json` 新增的字段全是可选的，旧文件照常读，权限仍是 0600；撤销设备和"重置配对"会一起删掉它的推送登记。
- **APNs**：token 认证，ES256 JWT（header `{"alg":"ES256","kid":<Key ID>}`，claims `{"iss":<Team ID>,"iat":<秒>}`），缓存 50 分钟后换新；sandbox `https://api.sandbox.push.apple.com`，正式 `https://api.push.apple.com`，按设备登记的环境选。
- **通知规则照 Android**：同一个请求只推一次；请求了结就撤回；Mac 刚启动、刚配好推送、某台设备刚登记时的第一份快照只记下现状，不推；做完了、出错要设备打开对应的开关才推。判断随快照的 250 ms 合并一起做，不另开定时器。
- **实时活动的内容里没有任何文字**（只有数量、形象名、状态、百分比、时间）。
- 所有推送工作都在 bridge 的串行队列 `local.critter.pet.bridge` 上做，不碰主线程。
- 文案逐字照 Android（出处写在各任务里）。
- 不加 capability、不碰 iOS 工程的签名；不用任何 GUI 自动化。

## Review Focus

1. **Mac 没配推送时，什么都不能变。** 由 Task 7 的 `nothingRunsWithoutPushConfigured` 覆盖：没有配置、或者没有设备登记时，没有手机连着就不组快照、不排定时器、不发请求。
2. **推送 JSON 里出现明文。** 由 Task 5 的 `noSessionTextInThePlainPayload` 覆盖：用带特殊字符串的会话和请求（名字、命令、目录、分支、问题、计划都不同）组出每一种推送，断言整条 JSON 里一个都找不到。
3. **设备 token 失效（App 被删）后一直重试。** 收到 410 或 `BadDeviceToken` 要删掉这台设备的 token 并停止给它发。由 Task 6 的 `goneTokenIsDropped` 覆盖。
4. **`.p8` 或 Team ID 错了（403）。** 标成配置错误，在设置里显示原因，配置改了之前一条都不再发（不能每份快照都打一次 APNs）。由 Task 6 的 `forbiddenStopsUntilTheConfigChanges` 覆盖。
5. **重连、重启不重复推。** 同一个请求只推一次，Mac 重启后的第一份快照不推任何东西。由 Task 4 的 `firstSnapshotOnlyRecords`、`aRequestIsPushedOnce` 覆盖。

## 执行分批

| 批次 | 任务 | 验证方式 |
|---|---|---|
| M1 共享格式与登记 | 1–3 | `swift test` |
| M2 决策、内容、发送 | 4–6 | `swift test` |
| M3 接线与设置 | 7–9 | `swift test`、`make app`、联机检查 |

---

## 文件结构

```
Sources/CritterKit/Push/
  PushRegistration.swift        登记的消息体（Task 1）
  PushPayload.swift             推送载荷的键、类别、组装和解析（Task 1）
  PushCrypto.swift              AES-GCM 加解密、密钥格式（Task 1）
  LiveActivityContent.swift     实时活动的 ContentState 和 Attributes 的共享部分（Task 1）
  NotificationText.swift        通知标题、正文、副标题（从 CritterClient 移来，Task 5）
Sources/CritterKit/Bridge/BridgeProtocol.swift   改：ClientMessage.push、DenyReason.unknown（Task 1、3）
Sources/CritterCore/Bridge/Pairing.swift         改：DeviceRecord.push、DeviceRegistry 的登记读写（Task 2）
Sources/CritterCore/Bridge/BridgeConnection.swift 改：处理 push（Task 2）
Sources/CritterCore/Push/
  PushTracker.swift             推什么、撤回什么（Task 4）
  PushContent.swift             每条推送的明文和密文载荷（Task 5）
  LiveActivityPlanner.swift     实时活动的启动、更新、结束（Task 5）
  APNsToken.swift APNsRequest.swift APNsConfig.swift APNsResponse.swift   （Task 6）
Sources/CritterCore/AskCommand.swift  AppStatus.swift   改：pushReachable（Task 7）
Sources/CritterClient/BridgeClient.swift Pairing.swift Store/BridgeStore.swift   改：registerPush、welcome.version、unknown（Task 3）
Sources/CritterApp/Bridge/PushCoordinator.swift  PushSender.swift   新（Task 7）
Sources/CritterApp/Bridge/BridgeController.swift BridgeController+Services.swift  改（Task 7）
Sources/CritterApp/Bridge/PushSettingsSection.swift   新（Task 8）
Sources/critter-bridge-client/main.swift   改：push 子命令（Task 3）
docs/critter-bridge-protocol.md            改：新增一节（Task 1）
Tests/…                                     各任务的测试
```

---

## 批次 M1：共享格式与登记

### Task 1: 推送登记消息和共享格式

**Files:**
- Create: `Sources/CritterKit/Push/{PushRegistration,PushPayload,PushCrypto,LiveActivityContent}.swift`
- Modify: `Sources/CritterKit/Bridge/BridgeProtocol.swift`、`docs/critter-bridge-protocol.md`
- Test: `Tests/CritterKitTests/{PushRegistration,PushPayload,PushCrypto,LiveActivityContent}Tests.swift`；现有核对协议文档例子的测试（`grep -rn "critter-bridge-protocol" Tests` 找到它）加上新例子

**Interfaces（全部 `public`、`Codable`、`Sendable`）:**
- `PushRegistration`：`token: String`（APNs 设备 token，小写十六进制，空串 = 撤销）、`environment: PushEnvironment`（`sandbox` / `production`）、`bundleId: String`、`key: String`（推送密钥，base64url 不带填充，解出来必须正好 32 字节）、`notifyDone: Bool`、`notifyError: Bool`、`activity: ActivityRegistration?`。`ActivityRegistration`：`enabled: Bool`、`startToken: String?`（push-to-start token）、`activityId: String?`、`activityToken: String?`。`var isEmpty: Bool`（token 空，或者 `key` 无效）。
- 线上格式：`{"type":"push","id":"p1","registration":{…}}`，键名就用上面的属性名（JSONEncoder 默认），键排序。`ClientMessage.push(id: String?, registration: PushRegistration)`，编解码和现有消息同一套。Mac 回 `result`。
- `PushCategory: String`：`permission`、`permissionNoReason`（Codex，没有"拒绝并写理由"）、`question`、`plan`、`waitingElsewhere`（请在电脑上处理）、`done`、`error`、`test`。iOS 的通知类别 id 就用这些原始值。
- `PushPayload`：
  - 键：`aps`；自定义的 `c`（密文）、`r`（请求 id）、`s`（会话 id）、`k`（类别）、`w`（要撤回的通知 id 数组）。
  - `static func alert(category:requestId:sessionId:sealed:timeSensitive:) -> [String: Any]`：`aps` 里是 `alert: {title: "Critter", body: "有会话需要你"}`、`mutable-content: 1`、`category`、`thread-id`（= 会话 id）、`sound: "default"`，等你确认的加 `interruption-level: "time-sensitive"`；
  - `static func withdraw(ids:) -> [String: Any]`：`aps: {"content-available": 1}` 加 `w`；
  - 通知 id 规则：请求用 requestId，会话通知用 `"<类别>:<会话 id>"`；
  - `static func parse(_ userInfo: [AnyHashable: Any]) -> ParsedPush?`（给手机和扩展用）。
- `PushCrypto`：`static func makeKey() -> String`、`static func seal(_ text: PushText, key: String) throws -> String`、`static func open(_ sealed: String, key: String) throws -> PushText`。`PushText { title, subtitle, body }`。
- `LiveActivityContent`（实时活动的 `ContentState`，iOS 的小组件直接用它）：`counts: [StateCount]`（按 `PetState` 优先级排，只放数量大于 0 的）、`lead: PetBadge?`、`back: [PetBadge]`（最多 2 个）、`total: Int`、`fiveHour: Int?`、`sevenDay: Int?`（百分比，0–100）、`updatedAt: Int64`。`PetBadge { skin: String, state: PetState }`。`StateCount` 用 `CritterKit/FlockValues.swift` 里现成的（计划 2 移过去的）。`LiveActivityAttributesName = "CritterActivity"`（push-to-start 的 `attributes-type`）。

- [ ] **Step 1: 写测试**：
  - `registrationRoundTrips`（编码后键排序，和协议文档里的例子逐字相同）；
  - `anEmptyTokenIsAnUnregistration`；
  - `aKeyThatIsNot32BytesIsInvalid`；
  - `sealThenOpenGivesTheText`、`openWithTheWrongKeyThrows`、`aTamperedCiphertextThrows`；
  - `alertPayloadHasOnlyTheAllowedPlainKeys`（`aps.alert` 只有 Critter / 有会话需要你，其余键只有 c/r/s/k）；
  - `withdrawPayloadIsBackground`；
  - `parseReadsWhatAlertWrote`；
  - `activityContentHasNoTextFields`（编码后的 JSON 里只有上面列的键）。
- [ ] **Step 2: Run** `swift test --filter 'PushRegistration|PushPayload|PushCrypto|LiveActivityContent'`。Expected: FAIL（未定义）。
- [ ] **Step 3: 实现**，并在协议文档 `## Codex control extensions` 后面加一节 `## iOS push registration (protocol 1, optional)`，内容包括：
  - 消息例子、字段表、`result` 的含义（`ok` = 已存下；`invalid` = 格式不对）；
  - "全量替换、token 为空即撤销"；
  - 旧 Mac 会忽略这条消息，手机 10 秒内收不到回复时不要断开连接，而是提示"这台 Mac 上的 Critter 版本太旧，收不到推送"；
  - 推送载荷的格式和加密方式（给手机端实现者看）。
- [ ] **Step 4: Run** 同上，再跑完整的 `swift test`。Expected: 新测试通过，只有那两个 Codex 测试失败。
- [ ] **Step 5: Commit** `git commit -m "feat(kit): push registration, payload, encryption and live activity formats"`

### Task 2: Mac 存下推送登记

**Files:**
- Modify: `Sources/CritterCore/Bridge/Pairing.swift`（`DeviceRecord`、`DeviceRegistry`）、`Sources/CritterCore/Bridge/BridgeConnection.swift`（`BridgeServices` 加一个方法）、`Sources/CritterApp/Bridge/BridgeController+Services.swift`
- Test: `Tests/CritterCoreTests/` 下现有的设备表和连接测试文件（`grep -rln "DeviceRegistry\|BridgeConnection" Tests/CritterCoreTests`）

**Interfaces:**
- `DeviceRecord.push: PushRegistration?`（可选，旧文件没有这个键照常解码）。
- `DeviceRegistry`：
  - `setPush(deviceId:_:)`：空登记存成 nil；
  - `dropPushToken(deviceId:)`：APNs 说 token 失效时用，删掉整份登记；
  - `setActivity(deviceId:activityId:activityToken:)`：清掉实时活动的 id 和 token 时用；
  - `pushDevices() -> [DeviceRecord]`：有登记的设备。
  - 都走现有的加锁、原子写、0600。
- `BridgeServices.registerPush(deviceId: String, _ registration: PushRegistration) -> Bool`；`BridgeConnection` 收到 `.push` 时调它：成功回 `result ok`，`key` 无效回 `invalid`（message "推送登记无效"）。旧的 `default` 分支不能把它吞掉。
- `BridgeController+Services` 实现：存进 `registry`，刷新设备列表，然后通知 Task 7 的 `PushCoordinator`（这一任务先留一个 `pushRegistrationChanged(deviceId:)` 钩子，空实现）。

- [ ] **Step 1: 写测试**：
  - `oldDevicesFileStillDecodes`（不带 `push` 的 JSON）；
  - `pushRegistrationIsStoredAndReplaced`；
  - `anEmptyRegistrationClearsIt`；
  - `revokeAndResetDropTheRegistration`；
  - `devicesFileStaysPrivate`（0600）；
  - `connectionAnswersPushWithResult`（ok 和 invalid 两种）；
  - `pushBeforeHelloIsAProtocolError`（照现有规则：第一帧不是 hello/pair 就 `denied protocol`）。
- [ ] **Step 2: Run** `swift test --filter 'DeviceRegistry|BridgeConnection'`。Expected: 新测试 FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上，再跑完整的 `swift test` 和 `make app`。Expected: 通过。
- [ ] **Step 5: Commit** `git commit -m "feat(bridge): the Mac stores each device's push registration"`

### Task 3: 手机端连接库：登记推送、Mac 版本、不认识的拒绝原因

**Files:**
- Modify: `Sources/CritterKit/Bridge/BridgeProtocol.swift`（`DenyReason.unknown`，宽松解码）、`Sources/CritterClient/{BridgeClient,Pairing}.swift`、`Sources/CritterClient/Store/{BridgeStore,StoreProtocols}.swift`、`Sources/critter-bridge-client/main.swift`
- Test: `Tests/CritterClientTests/{BridgeClient,Pairing,BridgeStore}Tests.swift`、`Tests/CritterKitTests/LenientDecodingTests.swift`

台账"Mac 推送计划"一组的三条（`docs/critter-ios-backlog.md`），外加给开发用客户端加一个子命令：

**Interfaces:**
- `DenyReason` 加 `unknown`。解码时不认识的值都变成它（照 `LenientDecodingTests` 里别的枚举的做法）；Mac 端永远不发它。
  - `BridgeClient` 的 `deniedText(.unknown)` = "连接被电脑拒绝"（Android `BridgeClient.kt` 的 `deniedText`），状态进 `.needsRepair`，不再重试；
  - 配对时 `pairFailure(denied: .unknown, …)` 和 `protocolMismatch` 一样处理（Android `PairOutcome.kt` 第 42 行）。
- `BridgeClient.macVersion: String?`：最近一次 `welcome.version`，断开后保留；`BridgeStore.macVersion` 跟着它。
- `BridgeClient.registerPush(_ r: PushRegistration) async -> PushRegistrationReply`：
  - `PushRegistrationReply` 有四种：`.stored`、`.rejected(String?)`、`.noReply`（10 秒内没回复：旧 Mac）、`.offline`；
  - **10 秒内没有回复时不断开连接、不触发重连**，这一点和别的请求不同。
- `BridgeStore.registerPush(_:) async -> PushRegistrationReply`：只在在线时发。`BridgeLink` 协议和所有假连接跟着改；如果 `ios/` 里的 DEBUG 假连接也实现了 `BridgeLink`，同样补上（返回 `.offline`），并确认 `make ios-sim` 能编译。
- 开发用客户端：`critter-bridge-client push --token <hex> [--env sandbox] [--bundle com.braynlabs.critter] [--done] [--error] [--activity]`，用随机的密钥登记，打印 `result`；`push --clear` 撤销。Task 9 联机时用它。

- [ ] **Step 1: 写测试**：
  - `unknownDenyReasonDecodes`；
  - `helloDeniedWithAnUnknownReasonStopsWithItsText`；
  - `pairingDeniedWithAnUnknownReasonReadsAsAVersionProblem`；
  - `welcomeVersionIsKept`；
  - `registerPushReturnsStoredOnOk`；
  - `registerPushWithoutAReplyKeepsTheConnection`（10 秒后 `.noReply`，连接还在、没有重连、之后的快照照常收到）；
  - `registerPushOfflineReturnsOffline`。
- [ ] **Step 2: Run** `swift test --filter 'BridgeClient|Pairing|BridgeStore|LenientDecoding'`。Expected: 新测试 FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上，再跑完整的 `swift test`，以及 `make ios-sim`（改到了 `BridgeLink` 的话）。Expected: 通过。
- [ ] **Step 5:** 在 `docs/critter-ios-backlog.md` 里删掉做完的三条。
- [ ] **Step 6: Commit** `git commit -m "feat(client): register for push, keep the Mac's version, an unknown denied reason stops"`

---

## 批次 M2：决策、内容、发送

### Task 4: 推什么、撤回什么 `PushTracker`

**Files:**
- Create: `Sources/CritterCore/Push/PushTracker.swift`
- Test: `Tests/CritterCoreTests/PushTrackerTests.swift`

**参考：** `android/core/src/main/kotlin/local/critter/core/logic/AlertPlanner.kt`（`AlertPlanner`、`AlertTracker`）和 `AlertPlannerTest.kt`。悬浮球（pile）和震动的部分 iOS 用不到，去掉；其余规则逐条照搬。

**Interfaces:**
- `PushPrefs { notifyDone: Bool, notifyError: Bool }`。
- `PushPlan`：`post: [BridgePending]`（新请求）、`withdraw: [String]`（通知 id）、`results: [(BridgeSession, PetState)]`（做完了、出错）、`withdrawResults: [String]`、`waitingNotices: [BridgeSession]`（"请在电脑上处理"）、`withdrawWaiting: [String]`。
- `final class PushTracker`：每台设备一个；`init(prefs:)`；`var prefs`；`func next(_ snapshot: SnapshotBody) -> PushPlan`；`func reset()`。第一份快照（刚建的 tracker、`reset()` 之后）只记下现状，返回空计划；这一点和 Android 不同（Android 第一份快照照样发通知），按 spec §6.3。

- [ ] **Step 1: 翻测试**：`AlertPlannerTest.kt` 里和悬浮球、震动无关的每个测试，名字照抄。另加：
  - `firstSnapshotOnlyRecords`；
  - `aRequestIsPushedOnce`（连续三份快照都有同一个请求，只推一次）；
  - `aResolvedRequestIsWithdrawn`；
  - `doneAndErrorFollowThePrefs`；
  - `waitingWithNothingToAnswerOnThePhoneGetsANotice`（VS Code 会话，没有请求）；
  - `aSessionThatEndsWithdrawsItsNotices`。
- [ ] **Step 2: Run** `swift test --filter PushTracker`。Expected: FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上。Expected: 通过。
- [ ] **Step 5: Commit** `git commit -m "feat(push): what to push and withdraw, ported from Android's AlertTracker"`

### Task 5: 推送内容和实时活动的计划

**Files:**
- Create: `Sources/CritterKit/Push/NotificationText.swift`、`Sources/CritterCore/Push/{PushContent,LiveActivityPlanner}.swift`
- Modify: `Sources/CritterClient/Presentation/{RequestText,SessionText}.swift`（相关函数改成转调 `NotificationText`，对外接口不变）
- Test: `Tests/CritterKitTests/NotificationTextTests.swift`、`Tests/CritterCoreTests/{PushContent,LiveActivityPlanner}Tests.swift`

**Interfaces:**
- `NotificationText`：把 `RequestText.title`、`RequestText.permissionBody`、`SessionText.folderName`、`SessionText.place`、`SessionText.source` 原样移进 `CritterKit`（`CritterClient` 的同名函数转调它们，iOS App 不用改），加上：
  - `requestBody(_:session:)`：Android `Alerts.requestText`，权限请求是命令或路径，否则是目录名；
  - `waitingNoticeTitle(_:)`：Android `"<名字> 等你确认（请在电脑上处理）"`；
  - `resultTitle(_:state:)`：Android `"<名字> <状态名>"`。
- `PushContent`：
  - `static func request(_ p: BridgePending, session: BridgeSession?, key: String) throws -> APNsMessage`：标题 `NotificationText.title`、副标题 `place`、正文 `requestBody`；类别按 `kind` 和 `acceptsDenyMessage` 选；等你确认的是时效性通知；`collapseId` = requestId；`expiration` = 请求的 `expiresAt`（秒），没有就不设。
  - 还有 `waitingNotice`、`result`、`withdraw`、`test` 四种。
  - `APNsMessage { pushType: .alert/.background/.liveActivity, priority: 10/5, collapseId, expiration, payload: Data }`。
  - 正文截短：整条 payload 超过 4096 字节时，先截正文、再截副标题（截在字符边界，末尾加"…"），标题最多 60 个字。
- `LiveActivityPlanner`（每台设备一个，纯逻辑，时间由调用方传）：
  - `func content(from: SnapshotBody) -> LiveActivityContent`（形象名用每个会话自己的 `skin`）：领头和后两只的选法同 Mac 的合群（最急的在前，`PhoneFlock` / `FlockModel.mostUrgent` 的规则）；额度取快照的 5 小时、7 天百分比，四舍五入成整数。
  - `func next(content:now:activityEnabled:hasStartToken:activityToken:) -> [LiveActivityAction]`，`LiveActivityAction` 有三种：`.start(content)`、`.update(content, priority: Int)`、`.end(dismissAt: Int64)`。规则：
    - 有会话、开着、有 start token、没有 activityToken → `start`；
    - 内容变了才 `update`：等你确认的数量增加时优先级 10、立即发，其它变化优先级 5，同一台设备最多 10 秒一次（10 秒内有多次变化，只在期满时发最后那份）；
    - 所有会话结束 5 分钟后 `end`；
    - 活动开了 7.5 小时就先 `end` 再 `start`；
    - 关掉时 `end`。
  - `func nextDeadline() -> Int64?`：给调用方排一次性的定时器（10 秒节流期满、5 分钟、7.5 小时）。
  - `staleDate` = 发送时间 + 15 分钟。
- `PushContent.liveActivity(_ action:, now:) -> APNsMessage`：载荷照 Apple 的格式（`aps.timestamp`、`event: start|update|end`、`content-state`、`stale-date`；`start` 带 `attributes-type: "CritterActivity"`、`attributes: {}` 和一条 `alert`（"Critter" / "有会话需要你"）；`end` 带 `dismissal-date`）。

- [ ] **Step 1: 写测试**：
  - `NotificationText` 的标题、正文、副标题，用 Android `PresentationTest.kt` 里对应的例子；
  - `noSessionTextInThePlainPayload`（Review Focus 2：每一种推送，打开密文前，整条 JSON 里找不到会话名、命令、目录、分支、问题、计划、Mac 名）；
  - `sealedTextOpensToTheNotification`；
  - `aLongCommandIsCutToFit4KB`（10 万字的命令）；
  - `codexPermissionHasNoReasonCategory`；
  - `waitingIsTimeSensitive`；
  - `activityStartsWhenThereAreSessionsAndAStartToken`；
  - `activityUpdatesOnlyWhenTheContentChanges`；
  - `moreWaitingIsUrgentOtherChangesAreThrottledTo10s`；
  - `activityEndsFiveMinutesAfterTheLastSession`；
  - `activityIsRestartedBefore8Hours`；
  - `activityContentNeverCarriesText`。
- [ ] **Step 2: Run** `swift test --filter 'NotificationText|PushContent|LiveActivityPlanner'`。Expected: FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上，再跑完整的 `swift test`。Expected: 通过（`RequestText`、`SessionText` 原有测试不变）。
- [ ] **Step 5: Commit** `git commit -m "feat(push): encrypted notification content and the live activity plan"`

### Task 6: APNs 请求：签名、组装、处理回复

**Files:**
- Create: `Sources/CritterCore/Push/{APNsConfig,APNsToken,APNsRequest,APNsResponse}.swift`
- Test: `Tests/CritterCoreTests/APNsTests.swift`

**Interfaces:**
- `APNsConfig { keyId: String, teamId: String, bundleId: String, keyFile: URL }`；`static func keyId(fromFileName:) -> String?`（`AuthKey_<KeyID>.p8`）。
- `APNsToken`：`init(config:pem:)`，用 `P256.Signing.PrivateKey(pemRepresentation:)` 读 `.p8`，读不了就 throw；`func bearer(now: Date) -> String`，50 分钟内复用同一个 JWT。
- `APNsRequest.make(_ m: APNsMessage, deviceToken:, environment:, config:, bearer:) -> URLRequest`：
  - 请求是 `POST /3/device/<token>`；
  - 头有 `authorization: bearer …`、`apns-push-type`、`apns-priority`、`apns-topic`（alert 和 background 用 bundleId，实时活动用 `<bundleId>.push-type.liveactivity`）、`apns-collapse-id`、`apns-expiration`；
  - background 推送的优先级必须是 5。
- `APNsResponse.classify(status:body:) -> APNsOutcome`，`APNsOutcome` 有四种：
  - `.sent`；
  - `.dropToken`：410，或 400 加 `BadDeviceToken` / `DeviceTokenNotForTopic`；
  - `.configError(String)`：403；`InvalidProviderToken` 写"密钥或 Team ID 不对"，其它原因原样写；
  - `.retry`：429、5xx、网络错误。
- `PushDelivery`（重试逻辑，纯的，时间和传输由调用方注入）：`.retry` 最多重试 3 次，间隔 1、2、4 秒，然后放弃并记日志；`.configError` 之后 `isBlocked` 为真，直到 `configChanged()`；`.dropToken` 交给调用方删 token。

- [ ] **Step 1: 写测试**：
  - `jwtVerifiesWithThePublicKey`（测试里现场生成一把 P256 私钥，导出成 PEM，签出来的 JWT 用公钥验签；header 和 claims 的内容逐项对）；
  - `jwtIsReusedFor50Minutes`；
  - `aBadP8Throws`；
  - `requestHeadersForEachPushType`；
  - `liveActivityTopicHasTheSuffix`；
  - `goneTokenIsDropped`（Review Focus 3）；
  - `forbiddenStopsUntilTheConfigChanges`（Review Focus 4）；
  - `retriesThreeTimesThenGivesUp`；
  - `keyIdComesFromTheFileName`。
- [ ] **Step 2: Run** `swift test --filter APNs`。Expected: FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同上。Expected: 通过。
- [ ] **Step 5: Commit** `git commit -m "feat(push): APNs token signing, requests and responses"`

---

## 批次 M3：接线与设置

### Task 7: 接进 bridge，放宽 `ask` 的门槛

**Files:**
- Create: `Sources/CritterApp/Bridge/{PushCoordinator,PushSender}.swift`
- Modify: `Sources/CritterApp/Bridge/{BridgeController,BridgeController+Services}.swift`、`Sources/CritterApp/AppDelegate.swift`（写 `app.json` 的地方）、`Sources/CritterCore/{AppStatus,AskCommand}.swift`
- Test: `Tests/CritterCoreTests/` 里 `AskGate` 的测试；新建 `Tests/CritterCoreTests/PushCoordinatorRulesTests.swift`（`PushCoordinator` 里能抽成纯函数的部分）

内容：
- **`PushCoordinator`**（bridge 队列上）：
  - 持有 `APNsConfig?`、每台设备的 `PushTracker` 和 `LiveActivityPlanner`、`PushDelivery`；
  - `var isActive: Bool` = bridge 开着、配置有效且没被 403 拦下、至少一台设备登记了 token；
  - `snapshotChanged(_ body: SnapshotBody)`：每台设备跑一遍 tracker 和 planner，把要发的交给 `PushSender`；
  - 收到 `.dropToken` 就调 `registry.dropPushToken`；
  - 一台设备新登记或改了登记，就重建它的 tracker，下一份快照只记下现状；
  - Mac 启动、配置刚生效时，所有 tracker 都从头来。
- **`PushSender`**：`URLSession(configuration: .ephemeral)`（HTTP/2 由系统协商，走系统代理设置）；按 `APNsRequest` 发、按 `APNsResponse` 分类、按 `PushDelivery` 重试；完成回调回到 bridge 队列。记下"上次发送时间 / 出错原因"给设置界面显示。日志里不写 token 全文（只写前 8 位）、不写密文、不写 `.p8` 内容。
- **`BridgeController.changed()`**：
  - 没有手机连着、`pushCoordinator.isActive` 为假时照旧直接返回；
  - 为真时照样在 250 ms 后组一份快照：有连着的手机就广播，同时交给 `PushCoordinator`；
  - 实时活动的期限（`nextDeadline`）用一个一次性的 `asyncAfter`，只在有活动时排。
- **`ask` 的门槛**（spec §6.7）：
  - `AppStatus.pushReachable: Bool?`（可选，旧文件照常读），由 App 写，值 = `pushCoordinator.isActive`；
  - `AskGate.shouldStart` 改成"最近 10 分钟有手机连过，或者 `pushReachable == true`"，`shouldKeepWaiting` 不变；
  - "只对终端会话开启"的限制不变。
- 撤销设备、重置配对时，结束这台设备的实时活动（尽力发一条 `end`），然后删掉登记。

- [ ] **Step 1: 写测试**：
  - `AskGate`：`startsWhenPushIsReachableEvenWithoutARecentPhone`、`doesNotStartWhenPushIsNotReachableAndNoRecentPhone`、`oldAppJsonWithoutTheFieldStillDecodes`；
  - `nothingRunsWithoutPushConfigured`（Review Focus 1）：把 `changed()` 的判断抽成纯函数 `BridgeController.shouldAssemble(hasReadyClients:pushActive:)` 并测它；
  - `PushCoordinatorRules`：`isActive` 的三个条件、新登记的设备从头开始。
- [ ] **Step 2: Run** `swift test --filter 'AskGate|PushCoordinatorRules'`。Expected: FAIL。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 完整的 `swift test`、`make app`。Expected: 通过。
- [ ] **Step 5: Commit** `git commit -m "feat(push): the bridge pushes snapshots to registered iPhones; ask waits for a push-reachable phone"`

### Task 8: Mac 设置里的"iPhone 推送"

**Files:**
- Create: `Sources/CritterApp/Bridge/PushSettingsSection.swift`
- Modify: `Sources/CritterApp/Bridge/PhoneSettingsSection.swift`（设备列表、挂上新的一节）、`Sources/CritterApp/SettingsWindow.swift`（如有需要）、`Sources/CritterApp/SettingsStore.swift`

内容（spec §6.4 "配置"）：
- 新的一节"iPhone 推送"，放在"手机"一节下面，只在"允许手机连接"打开时可用：
  - 「选择 .p8 文件…」（`NSOpenPanel`，只收 `.p8`）：复制到 `~/.critter/bridge/apns/AuthKey_<KeyID>.p8`（0600，目录 0700），旧文件删掉；Key ID 从文件名读出来填进输入框，可以改；
  - Team ID 输入框；bundle id 输入框（默认 `com.braynlabs.critter`）。存在 `~/.critter/bridge/apns/config.json`（0600），不放 `UserDefaults`。
  - 状态一行：
    - "未配置"；
    - "已配置 · 上次发送 <x 分钟前>"；
    - "出错：<原因>"，红色，例如"密钥或 Team ID 不对"、"读不了 .p8 文件"。
  - 「发送测试通知」：给每台登记了的设备发一条 `test` 类别的通知（密文是"Critter 推送测试 / 能看到这条，说明推送通了"）。没有设备时按钮不可用，并写"还没有 iPhone 登记推送"。
- 设备列表里，登记了推送的设备后面加一个小标签"推送"。
- 配置改了 → `PushCoordinator.configChanged()`（清掉 403 的拦截，所有 tracker 从头来）。

- [ ] **Step 1: 实现。** 文件读写和校验抽成 `CritterCore` 里的纯函数 `APNsConfigStore`（`load()`、`save(_:)`、`importKey(from:)`），给它写测试：`importCopiesWithPrivatePermissions`、`keyIdIsReadFromTheFileName`、`configRoundTrips`、`aMissingKeyFileIsReported`。
- [ ] **Step 2: Run** `swift test --filter APNsConfigStore`，再跑完整的 `swift test`、`make app`。Expected: 通过。
- [ ] **Step 3: 界面检查**：要看界面得运行这条线构建的 Critter，会替换用户正在用的那个，所以不截图。各个状态（未配置、已配置、出错、没有设备）的文字和按钮是否可用，由审查者读代码核对；合回 main 后的联机检查里再看一眼。
- [ ] **Step 4: Commit** `git commit -m "feat(push): iPhone push settings on the Mac"`

### Task 9: 联机检查、文档

**Files:**
- Modify: `README.md`、`docs/critter-bridge-protocol.md`（补漏）、`docs/critter-ios-backlog.md`

- [ ] **Step 1: 全量验证**：`swift test`（只有那两个 Codex 测试失败）、`make app`、`make ios-sim`（`CritterClient` 改了接口，iOS App 要能编译）。
- [ ] **Step 2: 联机检查不在这里做。** 它要运行这条线构建的 Critter.app，会替换用户正在用的那个。合回 `main` 后由主控先问用户，再做这几件事：
  - 用 `critter-bridge-client` 配一台临时设备，`push --token 00…00 --done`，看 `devices.json` 里有登记、权限 0600；`push --clear` 后登记消失；
  - 没有 `.p8` 时，设置显示"未配置"，`app.json` 的 `pushReachable` 为 false；
  - `scripts/dev/e2e-phone.sh` 照常通过。

  这里只需要确认 `critter-bridge-client push` 的参数解析和输出，在报告里写一个可以直接照着跑的联机步骤清单。
- [ ] **Step 3: 文档**：README 的手机一节写怎么配置 iPhone 推送（`.p8` 从哪来、放在哪、Team ID）；台账里推迟的条目按计划写进去，计划 4 要接着做的写清楚：
  - 真的发一条到 APNs，验证 sandbox 地址要不要走代理（spec §13.6）；
  - 实时活动的 token 能不能在后台送回 Mac（spec §13.1）。
- [ ] **Step 4: Commit** `git commit -m "docs: iPhone push on the Mac: README, protocol, backlog"`
