# Critter 手机端 · iOS 计划 1：共享代码与 iOS 骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能在 iOS 模拟器里运行的 Critter App，具备以下能力：
- 和 Mac 上的 Critter 配对（扫码、深链接、手动输入码）；
- App 在前台时保持连接，退到后台时断开；
- 竖屏显示会话列表和额度；
- 在作答卡片上处理权限、提问和计划；看会话详情、发一句、停止当前回合。

宠物动画、看板、视觉稿、推送、实时活动、真机安装放在后面的计划。spec §14 第 1 步里的 `BoardTrigger` 移植，以及把 `SpriteAtlas`、`CritterSpriteLayer`、`MotionClock` 移进 `CritterKit`，放到宠物与看板那份计划（这一份用不到它们）。App Group 和共享钥匙串放到加扩展的那份计划。

**Architecture:** Swift 包里新增两个库，iOS App 只放界面和平台相关的部分。
- `CritterKit`：从 `CritterCore` 拆出来的、能在 iOS 上编译的共享代码（协议、形象、动画）。`CritterCore` 用 `@_exported import` 引入它，Mac 端代码一行不改。
- `CritterClient`：手机端的全部逻辑——连接（可替换的传输层）、配对、作答草稿、显示文案、App 的状态 `BridgeStore`。全部在 Mac 上用 `swift test` 测，不需要模拟器。
- `ios/Critter.xcodeproj`：SwiftUI App，依赖上面两个库；平台相关的部分（钥匙串、后台任务、扫码、Bonjour 列表）在这里。

**Tech Stack:** Swift 6、SwiftUI、Observation、Swift Testing；URLSession WebSocket、Network.framework（`NWBrowser`、`NWConnection`）、Security、VisionKit；Xcode 27.1、iOS SDK 27.1，模拟器 iPhone 17 Pro。没有第三方依赖。

**Spec:** `docs/superpowers/specs/2026-10-23-critter-ios-design.md`，重点是 §4、§6.1、§7、§8.1–§8.4、§10、§14 的第 1、2 步。没写到的行为按 `docs/superpowers/specs/2026-10-18-critter-android-design.md` 的 §8.3–§8.5，界面文字按 `docs/superpowers/specs/2026-10-19-critter-phone-visual-design.md` 的 §8.2–§8.6。

**协议以 `docs/critter-bridge-protocol.md` 为准。** 这份计划不改协议。

## Global Constraints

- Bundle ID `com.braynlabs.critter`，显示名 `Critter`，Team `XB89283VYM`，最低 iOS 17.2，只支持 iPhone，竖屏。Swift 6 语言模式。
- 不引入第三方依赖。
- **这份计划不加任何 capability / entitlement，只在模拟器上构建和测试。** 装到用户 iPhone（会在 Apple 开发者账号里登记 App ID）放在后面的计划，要先征得用户同意。
- Mac 端行为不变：`swift test` 原有的测试全部通过，`make app` 照常构建。
- `hello.app` 写 `critter-ios/<CFBundleShortVersionString>`；`pair.deviceName` 写 `UIDevice.current.name`，DEBUG 构建可以用启动参数 `-critterDeviceName <名字>` 覆盖（Task 12 用它配对成 `critter-bridge-client`，好用调试链接撤销）。
- 连接只在 App 处于前台（scene `.active`）时存在；退到后台时，等正在等回复的请求完成（最多 10 秒）再断开。
- 断线重连从 2 秒起，每次翻倍，封顶 60 秒；连上后复位。请求 10 秒没有回复就断开这条连接并重连。配对等 Mac 批准最多 120 秒。心跳 ping 每 60 秒一次。
- **连接收到 `welcome` 之前，除了 `hello` / `pair` 什么都不发**（协议文档"Connection flow"；Android 的 `3843a30` 修的就是这个）。
- WebSocket 单条消息上限设成 64 MiB（协议文档：Mac → 手机的消息不设上限，快照可能大于 1 MiB）。
- 证书固定：叶证书 DER 的 SHA-256，64 位小写十六进制，必须和配对时的指纹完全相等。
- 只和私有网段的地址配对和连接（`PrivateNetwork.isAllowed(host:)`）。
- 作答只针对当前快照 `pending` 里还在的 `requestId`，卡片绝不按"这个会话当前的请求"去取。
- 手机上只存：配对信息（地址、端口、指纹、Mac 名字、deviceId 在 `UserDefaults` 的 `critter.pairing`，值是 `StoredPairing` 编码成的 JSON 字符串；token 在钥匙串，service `com.braynlabs.critter.pairing`，可访问性 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`）、最后一份快照（Application Support 下的 `snapshot.json`）、设置。
- 文案逐字照抄 Android（出处写在各个任务里）。下面这些全 App 通用：
  - 状态名：空闲、运行中、等你确认、做完了、出错（`PetState.label`）；
  - 卡片底部小字："电脑上也能答，谁先答算谁的"；
  - 被别处处理："已在电脑上处理"；过期的默认文字："这个请求已经过期了"；其它失败的默认文字："没有发送出去，再试一次"；
  - 没连上时请求的结果："未连接"；请求超时："超时"。

## Review Focus

1. **快照大于 1 MiB**（很长的计划原文）。连接不能因此断开、无限重连。由 Task 4 的 `transportAcceptsFramesUpTo64MiB` 覆盖。
2. **Mac 装了更新的 Critter，快照里出现手机不认识的来源、状态或请求类型。** 整份快照不能因此解码失败：不认识的来源当 `other`，不认识的状态当 `idle`，不认识类型的请求丢掉。由 Task 2 的三个测试覆盖。
3. **Mac 的 IP 变了**（换了 Wi‑Fi、DHCP 重新分配），证书没变。上次的地址连不上时，按 Bonjour 服务名找到新地址，用同一个指纹连上，不用重新配对，并记住新地址。由 Task 4 的 `fallsBackToBonjourAfterTheLastAddressFails` 和 Task 7 的 `aNewAddressIsRemembered` 覆盖。
4. **点了「允许」马上按 Home 键。** 回答必须送到并拿到回执，之后才断开。由 Task 7 的 `backgroundingWaitsForTheAnswerInFlight` 覆盖。
5. **卡片开着时，请求在电脑上被处理了。** 卡片要显示"已在电脑上处理"并在 2 秒后关闭，不能留着可点的按钮。由 Task 5 的 `cardStateWhenTheRequestLeavesTheSnapshot` 覆盖。

---

## 文件结构

```
Package.swift                                   改：iOS 平台、CritterKit、CritterClient 两个库和各自的测试
Sources/CritterKit/                             新：从 CritterCore 移过来的共享代码（Task 1）
  Bridge/BridgeProtocol.swift                   移入；Task 2 加宽松解码
  Bridge/BridgeValues.swift                     新：PendingKind、AnswerPayload、RateWindow（从原文件剪切过来）
  Bridge/PairingURI.swift                       新：PairingCode、PairingURI（从 Bridge/Pairing.swift 剪切过来）
  Bridge/PrivateNetwork.swift                   移入
  Hex.swift JSONValue.swift PetState.swift SessionSource.swift
  Skin.swift SkinRenderer.swift SkinAssigner.swift SkinLibrary.swift
  Motion/*.swift                                移入（9 个文件）
Sources/CritterCore/Exports.swift               新：@_exported import CritterKit
Sources/CritterClient/                          新：手机端逻辑
  Transport.swift                               BridgeSocket、BridgeTransport、TransportError
  URLSessionTransport.swift                     真正的传输层：固定证书、64 MiB
  PinnedCertificate.swift                       指纹计算与比对
  CertificateProbe.swift                        手动配对前读出 Mac 的证书指纹
  ConnState.swift                               ConnState、Credentials、BridgeEvent、CommandResult
  BridgeCommand.swift                           answer / seen / say / interrupt
  ReconnectBackoff.swift
  BridgeClient.swift                            连接、重连、请求与回执
  Pairing.swift                                 PairingTarget、PairFailure、PairResult、Pairer
  Endpoints.swift                               Endpoint、EndpointResolver、MacBrowser、BonjourBrowser、FallbackResolver
  Presentation/AnswerDraft.swift                作答草稿
  Presentation/RequestText.swift                请求的标题、正文、问题解析、作答结果
  Presentation/SessionText.swift                会话的各种文字
  Presentation/LimitsText.swift
  Presentation/SessionOrder.swift
  Store/BridgeStore.swift                       App 的状态（@MainActor @Observable）
  Store/StoreProtocols.swift                    PairingStorage、BridgeLink、PairingLink、BackgroundRunner
Tests/CritterKitTests/LenientDecodingTests.swift
Tests/CritterClientTests/                       FakeMac.swift + 各模块的测试
ios/
  Critter.xcodeproj/                            一个 App target，文件夹同步分组
  Config/Critter.xcconfig  Config/Info.plist
  Critter/                                      App 源码
    CritterApp.swift RootView.swift
    Platform/KeychainPairingStorage.swift Platform/UIKitBackgroundRunner.swift Platform/QRScannerView.swift
    Pairing/PairingView.swift Pairing/ManualPairView.swift Pairing/PairingProgressView.swift
    Home/HomeView.swift Home/SessionRow.swift Home/LimitsCards.swift
    Detail/DetailSheet.swift
    Answer/AnswerSheet.swift Answer/QuestionForm.swift
    Settings/SettingsView.swift
    Debug/DebugLaunch.swift Debug/Fixtures/*.json   只在 DEBUG 下生效
scripts/dev/client-live-check.sh                CritterClient 连真的 Mac（Task 4）
scripts/dev/ios-sim-live.sh                     模拟器里的 App 连真的 Mac（Task 12）
```

---

### Task 1: 拆出 `CritterKit`

**Files:**
- Modify: `Package.swift`
- Move（`git mv`，内容不改）：`Sources/CritterCore/{Hex,JSONValue,PetState,SessionSource,Skin,SkinRenderer,SkinAssigner,SkinLibrary}.swift`、`Sources/CritterCore/Motion/`（整个目录）、`Sources/CritterCore/Bridge/{BridgeProtocol,PrivateNetwork}.swift` → `Sources/CritterKit/` 下的同名路径
- Create: `Sources/CritterKit/Bridge/BridgeValues.swift`（把 `PendingKind`、`AnswerPayload` 从 `PendingRequest.swift`，`RateWindow` 从 `StatusLineRecord.swift` 原样剪切过来）
- Create: `Sources/CritterKit/Bridge/PairingURI.swift`（把 `PairingCode`、`PairingURI` 从 `Bridge/Pairing.swift` 原样剪切过来；`DeviceRecord`、`DeviceRegistry` 留在原处）
- Create: `Sources/CritterCore/Exports.swift`
- Modify: `Sources/CritterKit/Bridge/BridgeProtocol.swift`、`Sources/CritterCore/AskDecision.swift`
- Test: 现有测试；`Tests/CritterKitTests/`（新目录，Task 2 才放测试，这里先放一个 `CritterKitSmokeTests.swift`）

**Interfaces:**
- Produces: 库 `CritterKit`（macOS 14 / iOS 17.2）。原来这些文件里的 `public` 名字不变，Mac 端照样用。新增 `BridgeProtocol.multiSelectSeparator = ", "`；`AskDecision.multiSelectSeparator` 改成等于它。

- [ ] **Step 1: 记下基线。** Run: `swift test 2>&1 | tail -3`。Expected: 全部通过，记下"N tests"的 N。

- [ ] **Step 2: 改 `Package.swift`。**
  - `platforms: [.macOS(.v14), .iOS("17.2")]`；
  - products 加 `.library(name: "CritterKit", targets: ["CritterKit"])`；
  - targets 加 `.target(name: "CritterKit")`、`.testTarget(name: "CritterKitTests", dependencies: ["CritterKit"])`；
  - `CritterCore` 改成 `.target(name: "CritterCore", dependencies: ["CritterKit"])`。

- [ ] **Step 3: 移动和剪切文件**（见 Files）。`Exports.swift` 只有一行 `@_exported import CritterKit`。

- [ ] **Step 4: 写冒烟测试** `Tests/CritterKitTests/CritterKitSmokeTests.swift`：

```swift
@Test func builtinSkinLoadsFromCritterKit() {
    #expect(SkinLoader.builtin().name == "sprig")
}
@Test func multiSelectSeparatorIsCommaSpace() {
    #expect(BridgeProtocol.multiSelectSeparator == ", ")
}
```

- [ ] **Step 5: 编译并跑全部测试。** Run: `swift build && swift test 2>&1 | tail -3`。Expected: 全部通过，测试数 = N + 2。编不过的测试文件，在 `@testable import CritterCore` 下面加一行 `@testable import CritterKit`（它们用到了移走的文件里的 internal 成员）。只允许改 import，不改测试内容。`CritterCore`、`CritterApp` 的源码用到移走文件里的 internal 成员时，把那个成员改成 `public`，只改访问级别。

- [ ] **Step 6: 为 iOS 编译 `CritterKit`。** Run: `xcodebuild -scheme CritterKit -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode build -quiet`。Expected: 没有错误输出，退出码 0。

- [ ] **Step 7: Mac App 照常构建。** Run: `make app`。Expected: 成功生成 `Critter.app`。

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "refactor: move the code phones share into a CritterKit target"
```

---

### Task 2: 手机端解码要宽松

**Files:**
- Modify: `Sources/CritterKit/Bridge/BridgeProtocol.swift`
- Test: `Tests/CritterKitTests/LenientDecodingTests.swift`

**Interfaces:**
- Produces: `BridgeSession` 有手写的 `init(from:)`（编码仍是合成的，输出不变）；`ServerMessage.decode` 解快照时丢掉不认识类型的请求。

- [ ] **Step 1: 写失败的测试**（快照 JSON 用协议文档"snapshot"一节的例子改出来）：

```swift
@Test func unknownSourceDecodesAsOther()      // "source":"jetbrains" -> .other
@Test func unknownStateDecodesAsIdle()        // "state":"thinking"  -> .idle
@Test func pendingOfUnknownKindIsDropped()    // pending r1 permission + r2 "kind":"elicitation" -> ["r1"]
@Test func protocolDocSnapshotStillDecodes()  // 文档原例：sessions[0].source == .terminal, state == .waiting, pending[0].kind == .permission
@Test func sessionEncodingIsUnchanged()       // 编码一个 BridgeSession，和改动前的输出逐字节相同（先在改动前跑一次，把输出贴进测试）
```

- [ ] **Step 2: Run** `swift test --filter LenientDecodingTests`。Expected: 前三个 FAIL（整份快照解码成 nil）。

- [ ] **Step 3: 实现。** `BridgeSession.init(from:)`：`source` 用 `SessionSource(rawValue:) ?? .other`，`state` 用 `PetState(rawValue:) ?? .idle`，其余字段照常解码。`ServerMessage.Wire.pending` 换成一个"逐项解码、失败就跳过"的包装数组（`kind` 不认识时这一项解码失败）。Mac 端只编码这些类型，行为不变。

- [ ] **Step 4: Run** `swift test`。Expected: 全部通过。

- [ ] **Step 5: Commit** `git commit -m "feat: phones tolerate sources, states and request kinds they don't know"`

---

### Task 3: `CritterClient` 的连接

**Files:**
- Modify: `Package.swift`（加 `.library(name: "CritterClient", targets: ["CritterClient"])`、`.target(name: "CritterClient", dependencies: ["CritterKit"])`、`.testTarget(name: "CritterClientTests", dependencies: ["CritterClient"])`）
- Create: `Sources/CritterClient/{Transport,ConnState,BridgeCommand,ReconnectBackoff,BridgeClient}.swift`、`Sources/CritterClient/Endpoints.swift`（这里只放 `Endpoint` 和 `EndpointResolver`）
- Test: `Tests/CritterClientTests/FakeMac.swift`、`BridgeClientTests.swift`、`ReconnectBackoffTests.swift`

**Interfaces:**
- Consumes: `ClientMessage`、`ServerMessage`、`SnapshotBody`、`AnswerPayload`、`ResultReason`、`DenyReason`、`JSONValue`、`BridgeProtocol.version`（`CritterKit`）。
- Produces:

```swift
public protocol BridgeSocket: Sendable {
    func send(_ text: String) async throws
    func receive() async throws -> String          // 下一条文本消息；连接结束时抛 TransportError
    func sendPing() async throws
    func close()
}
public protocol BridgeTransport: Sendable {
    /// fingerprint 为 nil 时不固定证书（只给 CertificateProbe 用）。
    func connect(host: String, port: UInt16, fingerprint: String?) async throws -> any BridgeSocket
}
public enum TransportError: Error, Equatable, Sendable { case pinMismatch, unreachable, closed(cleanly: Bool) }

public struct Endpoint: Equatable, Sendable, Codable { public var host: String; public var port: UInt16 }
public protocol EndpointResolver: Sendable {
    /// afterFailure：上一次用解析出的地址没连上。
    func resolve(afterFailure: Bool) async -> Endpoint?
}

public struct Credentials: Equatable, Sendable { public var deviceId: String; public var token: String }
public enum ConnState: Equatable, Sendable {
    case idle, connecting, awaitingApproval
    case connected(macName: String)
    case offline(retryIn: Duration, since: Date)   // since：这一轮断线开始的时间，连上后清掉
    case needsRepair(reason: String)
}
public enum BridgeEvent: Equatable, Sendable {
    case state(ConnState)
    case snapshot(seq: Int, sentAt: Int64, body: SnapshotBody)
    case connectedTo(Endpoint)                       // 连上时用的地址（Task 7 用它记住新地址）
}
public struct CommandResult: Equatable, Sendable {
    public var ok: Bool; public var reason: ResultReason?; public var message: String?
    public static func failed(_ message: String) -> CommandResult   // ok false、reason nil
}
public enum BridgeCommand: Equatable, Sendable {
    case answer(requestId: String, payload: AnswerPayload)
    case seen(sessionId: String)
    case say(sessionId: String, text: String)
    case interrupt(sessionId: String)
    func message(id: String) -> ClientMessage
}
public struct ReconnectBackoff: Sendable {
    public init(initial: Duration = .seconds(2), max: Duration = .seconds(60))
    public mutating func nextDelay() -> Duration
    public mutating func reset()
}
public actor BridgeClient {
    public init(transport: any BridgeTransport, endpoint: any EndpointResolver, fingerprint: String,
                credentials: @escaping @Sendable () -> Credentials?, app: String,
                onEvent: @escaping @Sendable (BridgeEvent) -> Void,
                requestTimeout: Duration = .seconds(10), pingInterval: Duration = .seconds(60),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) })
    public func start()
    public func stop()
    public func reconnectNow()
    public func request(_ command: BridgeCommand) async -> CommandResult
    public func requestSkin(_ name: String) async -> JSONValue?
}
```

行为（照 Android `BridgeClient.kt` 的注释）：
- 一轮连接：没有凭据 → `needsRepair("尚未配对")`，结束；`connecting` → 解析地址 → 连接 → 发 `hello` → 等第一条消息：`welcome` → `connected(macName)`、退避复位、发 `connectedTo`；`denied` → `needsRepair(<文字>)`，结束。之后 `snapshot` 转成事件，`result` / `skin` 按 `id` 交给等待者，不认识的消息忽略。
- `denied` 的文字（照抄 Android `deniedText`）：`badToken` → "这台手机已不在电脑的配对列表里，请重新配对"；`protocol` → "协议版本不匹配，请更新 Critter"；`badCode` / `rejected` → "配对被拒绝"。证书不符 → `needsRepair("证书指纹与配对时不一致，请重新配对")`，不再重试。
- 连接断开（或连不上）：这条连接上等待中的请求都返回 `.failed("未连接")`；状态 `offline(retryIn: 退避值, since:)`，用注入的 `sleep` 等，然后下一轮；`reconnectNow()` 让正在等的这一次立刻结束；已连接时 `reconnectNow()` 断开重连。
- `request`：没连上（包括还没收到 `welcome`）→ 立刻 `.failed("未连接")`，什么都不发；id 用 `"a<递增数>"`；超时 → `.failed("超时")`，并关掉这条连接。
- 心跳：连上后每 `pingInterval` 发一次 ping，失败就关掉连接。
- 同一时间最多一个 socket。`stop()` 关掉 socket、结束循环、状态 `idle`、退避复位。

- [ ] **Step 1: 写 `FakeMac`。** 一个实现 `BridgeTransport` 的测试替身：记录每次 `connect` 的参数；可以设定下一次 `connect` 抛什么错；每个 socket 有两个方向的消息队列，测试一侧能 `await mac.nextFrame()` 读手机发来的、`mac.send(ServerMessage)` 发给手机、`mac.drop()` 断开、`mac.openSockets` 看同时开着几个。事件用一个 actor 记录，提供 `await events.waitFor { ... }`（最多等 2 秒）。

- [ ] **Step 2: 写失败的测试**（凭据 `d1`/`t1`，app `"critter-ios/test"`，Mac 名 `"Mac"`）：

```swift
// ReconnectBackoffTests
@Test func doublesFromTwoSecondsToAMinute()   // 2,4,8,16,32,60,60 秒
@Test func resetStartsOver()

// BridgeClientTests
@Test func sendsHelloFirst()                          // 第一条 == .hello(protocolVersion: 1, deviceId: "d1", token: "t1", app: "critter-ios/test")
@Test func welcomeMeansConnected()                    // 最后状态 == .connected(macName: "Mac")，并有 .connectedTo(Endpoint)
@Test func snapshotsArePassedOn()                     // seq 3 的快照 -> .snapshot(seq: 3, ...)
@Test func requestBeforeWelcomeFailsWithoutSending()  // == .failed("未连接")，Mac 只收到过 hello
@Test func requestsAreMatchedById()                   // 两个并发请求，Mac 倒序回复，各拿到自己的
@Test func requestTimesOutAndDropsTheConnection()     // requestTimeout 50ms -> .failed("超时")，随后出现第二次 connect
@Test func inFlightRequestFailsWhenTheLinkDrops()     // -> .failed("未连接")
@Test func badTokenNeedsRepairAndStops()              // needsRepair("这台手机已不在电脑的配对列表里，请重新配对")，之后没有新的 connect
@Test func pinMismatchNeedsRepairAndStops()           // needsRepair("证书指纹与配对时不一致，请重新配对")
@Test func noCredentialsNeedsRepair()                 // needsRepair("尚未配对")
@Test func retriesWithBackoffAndResetsAfterSuccess()  // 连不上 4 次：sleep 依次 2,4,8,16 秒；连上后再断：sleep 2 秒
@Test func offlineKeepsTheTimeTheStreakBegan()        // 连续两次 offline 的 since 相同
@Test func reconnectNowCutsTheWaitShort()             // sleep 一直挂着；reconnectNow 后马上有新的 connect
@Test func stopEndsTheLoopAndStartBeginsAfresh()      // stop 后状态 idle、没有新 connect；再 start 第一次等待又是 2 秒
@Test func neverMoreThanOneSocket()                   // start/reconnectNow/stop/start 交错之后 mac.maxOpenSockets == 1
@Test func failedPingDropsTheConnection()             // sendPing 抛错 -> 重连（pingInterval 20ms）
@Test func skinRequestReturnsTheManifestOrNil()
@Test func unknownFramesAreIgnored()                  // {"type":"future"} 之后快照照常到达
```

- [ ] **Step 3: Run** `swift test --filter CritterClientTests`。Expected: 编译失败（类型不存在）。

- [ ] **Step 4: 实现** Interfaces 里的类型。`BridgeClient` 是 actor，内部一个 `Task` 跑连接循环，每轮一个读消息的子任务和一个心跳子任务；等待中的请求用 `CheckedContinuation` 按 id 存，记下它属于哪个 socket。

- [ ] **Step 5: Run** `swift test --filter CritterClientTests`，连续跑 5 次（`for i in 1 2 3 4 5; do swift test --filter CritterClientTests 2>&1 | tail -1; done`）。Expected: 每次都全部通过。

- [ ] **Step 6: Commit** `git commit -m "feat(client): a reconnecting, request-matching bridge client for phones"`

---

### Task 4: 配对、真正的传输层、找 Mac

**Files:**
- Create: `Sources/CritterClient/{URLSessionTransport,PinnedCertificate,CertificateProbe,Pairing}.swift`；`Endpoints.swift` 补上 `MacBrowser`、`BonjourBrowser`、`FallbackResolver`、`StaticResolver`
- Create: `scripts/dev/client-live-check.sh`
- Test: `Tests/CritterClientTests/{PairingTests,PinnedCertificateTests,FallbackResolverTests,TransportTests,LiveBridgeTests}.swift`

**Interfaces:**
- Consumes: Task 3 的 `BridgeTransport`、`BridgeSocket`、`TransportError`、`Endpoint`、`EndpointResolver`；`PairingURI`、`PairingCode`、`Hex.sha256`、`PrivateNetwork.isAllowed(host:)`。
- Produces:

```swift
public enum PinnedCertificate {
    public static func fingerprint(der: Data) -> String          // Hex.sha256，小写
    public static func matches(der: Data, fingerprint: String) -> Bool
}
public final class URLSessionTransport: BridgeTransport {
    public static let maxMessageBytes = 64 << 20
    public init()
}
public struct CertificateProbe: Sendable {
    public init(transport: any BridgeTransport)
    /// 只做 TLS 握手、读出叶证书指纹，不发任何消息。连不上返回 nil。
    public func fingerprint(of endpoint: Endpoint) async -> String?
}
public struct PairingTarget: Equatable, Sendable {
    public var endpoint: Endpoint; public var fingerprint: String; public var code: String; public var macName: String
    public init(endpoint: Endpoint, fingerprint: String, code: String, macName: String)   // 手动输入用
    public init(uri: PairingURI)
}
public enum PairFailure: Equatable, Sendable {
    case badCode, rejected, protocolMismatch, certMismatch, noAnswer, unreachable
    public var text: String
}
public enum PairResult: Equatable, Sendable {
    case paired(deviceId: String, token: String, macName: String)
    case failed(PairFailure)
}
public func pairFailure(denied: DenyReason?, pinMismatch: Bool, timedOut: Bool, closedCleanly: Bool) -> PairFailure
public struct Pairer: Sendable {
    public init(transport: any BridgeTransport, timeout: Duration = .seconds(120))
    public func pair(_ target: PairingTarget, deviceName: String,
                     onAwaitingApproval: @escaping @Sendable () -> Void) async -> PairResult
}
public struct DiscoveredMac: Equatable, Sendable { public var name: String; public var endpoint: Endpoint }
public protocol MacBrowser: Sendable { func discover() async -> [DiscoveredMac] }
public struct BonjourBrowser: MacBrowser { public init(window: Duration = .seconds(3)) }
public struct StaticResolver: EndpointResolver { public init(_ endpoint: Endpoint) }
public struct FallbackResolver: EndpointResolver {
    public init(lastGood: Endpoint?, macName: String, browser: any MacBrowser)
}
```

行为：
- `URLSessionTransport`：每次 `connect` 一个 ephemeral `URLSession`，委托里做证书固定（照 `Sources/critter-bridge-client/main.swift` 的 `PinningDelegate`，不符时取消并让 `connect` 抛 `.pinMismatch`）；`fingerprint` 为 nil 时接受任何证书，但把看到的指纹记在 socket 上（`CertificateProbe` 读它）；`maximumMessageSize = maxMessageBytes`；等 `didOpenWithProtocol` 才算连上；正常关闭 → `receive` 抛 `.closed(cleanly: true)`，其它错误 → `.closed(cleanly: false)` 或 `.unreachable`（握手前失败）。IPv6 地址加方括号，`%` 转义成 `%25`（同 CLI）。
- `Pairer.pair`：用目标指纹固定证书连接，第一条发 `.pair(code:deviceName:)`，socket 打开后调用 `onAwaitingApproval`，然后等 `paired`（之后的 `welcome`、`snapshot` 不用管，关掉连接）；`denied`、超时、无 `denied` 的关闭、证书不符都按 `pairFailure` 分类。
- `pairFailure`（照 Android `pairFailureOf`）：有 `denied` 时 `badCode` → `.badCode`，`rejected` → `.rejected`，其余 → `.protocolMismatch`；否则证书不符 → `.certMismatch`；超时或干净关闭 → `.noAnswer`；其它 → `.unreachable`。
- `PairFailure.text` 逐字照抄 Android `PairingScreen.kt` 的 `pairFailureText`（第 782–789 行）。
- `BonjourBrowser.discover`：`NWBrowser` 找 `_critter._tcp`，收集 `window` 时间内的结果；每个服务用一条 `NWConnection`（TCP）解析出 `remoteEndpoint` 的 IP 和端口，拿到就取消连接，不做 TLS；只保留 `PrivateNetwork.isAllowed` 的地址。
- `FallbackResolver.resolve(afterFailure:)`：没失败过且有 `lastGood` → 返回它；否则 `discover()`，取服务名等于 `macName` 的第一个，没有就取第一个；都没有 → nil。

- [ ] **Step 1: 写失败的测试：**

```swift
// PairingTests（用 Task 3 的 FakeMac）
@Test func pairSendsPairFirstAndReturnsTheCredentials()  // 第一条 == .pair(code: "K7M2QX9P", deviceName: "iPhone")；Mac 回 paired -> .paired(deviceId:, token:, macName:)
@Test func awaitingApprovalIsReportedOnceOpen()
@Test func rejectedOnTheMacFails()                       // denied rejected -> .failed(.rejected)
@Test func closeWithoutDeniedIsNoAnswer()
@Test func timeoutIsNoAnswer()                           // timeout 50ms
@Test func pinMismatchIsCertMismatch()
@Test func failureClassification()                       // pairFailure 的全部分支
@Test func failureTextsAreAndroids()                     // .badCode.text == "这个码不对，或者已经过期了。在 Mac 的「添加手机」里点「重新生成」再试。"，.unreachable.text 同理逐字
// PinnedCertificateTests
@Test func fingerprintIsLowercaseSHA256OfTheDER()        // 固定字节 -> 已知十六进制
@Test func uppercaseOrShortPinsNeverMatch()
// FallbackResolverTests（假的 MacBrowser）
@Test func usesTheLastAddressFirst()
@Test func fallsBackToBonjourAfterTheLastAddressFails()  // afterFailure: true -> 名字匹配的那台
@Test func picksTheFirstMacWhenNoneHasTheName()
@Test func nothingFoundIsNil()
// TransportTests
@Test func transportAcceptsFramesUpTo64MiB()             // URLSessionTransport.maxMessageBytes == 64 << 20
@Test func ipv6HostsAreBracketedAndEscaped()             // 把拼 URL 的函数做成 internal static，测 "fe80::1%en0" -> "wss://[fe80::1%25en0]:47823/"
```

- [ ] **Step 2: Run** `swift test --filter CritterClientTests`。Expected: 新测试编译失败。

- [ ] **Step 3: 实现** 上面的类型。

- [ ] **Step 4: Run** `swift test`。Expected: 全部通过。

- [ ] **Step 5: 写 `LiveBridgeTests` 和 `scripts/dev/client-live-check.sh`。**
  - 测试只在环境变量 `CRITTER_LIVE_URI` 存在时运行（`@Test(.enabled(if: ...))`）：`pairsConnectsAndGetsASnapshotFromTheRealMac` 用 `URLSessionTransport` + `Pairer` 以 `deviceName: "critter-bridge-client"` 配对，把 deviceId 写到 `CRITTER_LIVE_OUT` 指向的文件；再用 `BridgeClient` + `StaticResolver` 连上，10 秒内要看到 `.connected` 和一份 `.snapshot`；然后 `request(.seen(sessionId: "no-such-session"))` 要拿到 Mac 的回执（不是"未连接"或"超时"）；最后 `stop()`。
  - 脚本照抄 `scripts/dev/e2e-phone.sh` 的前置检查（Critter 在运行、`debugEnabled`）、打开手机连接、`critter://debug-bridge-pair?out=...` 拿自动批准的 URI，以及清理（`critter://debug-bridge-revoke?deviceId=...`、原来没开手机连接就关掉）。中间跑 `CRITTER_LIVE_URI="$URI" CRITTER_LIVE_OUT="$WORK/device" swift test --filter LiveBridgeTests`。

- [ ] **Step 6: Run** `scripts/dev/client-live-check.sh`。Expected: `LiveBridgeTests` 1 个测试通过，脚本退出码 0，Mac 设置的已配对设备里没有留下 `critter-bridge-client`。前置条件不满足（Critter 没运行、没开 `debugEnabled`）时，停下来把脚本打印的要求报告给协调者，不要自己改用户的设置。

- [ ] **Step 7: Commit** `git commit -m "feat(client): pairing, the pinned URLSession transport and finding the Mac"`

---

### Task 5: 作答逻辑

**Files:**
- Create: `Sources/CritterClient/Presentation/{AnswerDraft,RequestText}.swift`
- Test: `Tests/CritterClientTests/{AnswerDraftTests,RequestTextTests}.swift`

**Interfaces:**
- Consumes: `BridgePending`、`BridgeSession`、`AnswerPayload`、`PendingKind`、`JSONValue`、`BridgeProtocol.multiSelectSeparator`、Task 3 的 `CommandResult`。
- Produces:

```swift
public final class AnswerDraft {                       // 照 Android AnswerDraft.kt，逐个方法对应
    public init(request: BridgePending)
    public func allow(); public func deny(message: String?); public func approve(); public func revise(message: String)
    public func choose(question: String, label: String)
    public func toggle(question: String, label: String)
    public func freeText(question: String, text: String)
    public func payload() -> AnswerPayload?            // 不合 Mac 的 AskDecision.validate 时为 nil
    public func markSubmitted() -> Bool                // 只有第一次为 true
}
public struct QuestionOption: Equatable, Sendable { public var label: String; public var description: String? }
public struct Question: Equatable, Sendable { public var header: String?; public var text: String; public var options: [QuestionOption]; public var multiSelect: Bool }
public enum RequestText {
    public static func title(_ request: BridgePending, session: BridgeSession?) -> String   // Android Alerts.requestTitle
    public static func permissionBody(_ input: JSONValue) -> String?                       // command / file_path / url 第一个非空
    public static func acceptsDenyMessage(_ input: JSONValue) -> Bool                       // 只有 "acceptsDenyMessage": false 时为 false
    public static func planText(_ input: JSONValue) -> String
    public static func questions(_ input: JSONValue) -> [Question]
    public static func submitsOnPick(_ questions: [Question]) -> Bool                       // 只有一个单选题
}
public enum AnswerOutcome: Equatable, Sendable {
    case sent, handledElsewhere, expired(String), failed(String)
    public init(_ result: CommandResult)   // 照 Android answerOutcome：expired 默认"这个请求已经过期了"，failed 默认"没有发送出去，再试一次"
}
public func successLabel(_ payload: AnswerPayload) -> String?   // "已提交" / "已允许" / "已批准" / nil
public enum CardState: Equatable, Sendable {                    // 作答卡片该显示什么
    case open(BridgePending), handledElsewhere, unknown
    public init(requestId: String, snapshot: SnapshotBody?, everSeen: Bool)
}
```

`CardState`：快照里有这个 requestId → `.open`；没有、但这张卡之前见过它（`everSeen`）→ `.handledElsewhere`；从没见过（比如从过期的快照打开）→ `.unknown`（卡片显示"已在电脑上处理"同样的样子，文字"这个请求已经不在了"）。

- [ ] **Step 1: 写失败的测试。** 把 `android/core/src/test/kotlin/local/critter/core/logic/AnswerDraftTest.kt`、`android/app/src/test/kotlin/local/critter/phone/AnswerInputTest.kt` 和 `CodexApprovalUiTest.kt` 里针对上面这些函数的测试逐个翻成 Swift Testing，名字和断言照搬。另加：

```swift
@Test func cardStateWhenTheRequestLeavesTheSnapshot()  // 先 .open，同一 requestId 从快照消失后 == .handledElsewhere
@Test func cardStateForARequestNeverSeen()             // == .unknown
@Test func titleCopy()  // "critter 想 swift test"、"critter 问：Which database?"、"critter 的计划等你批准"、summary 为空时 "critter 想执行一个操作"
```

- [ ] **Step 2: Run** `swift test --filter "AnswerDraftTests|RequestTextTests"`。Expected: 编译失败。
- [ ] **Step 3: 实现。** `AnswerDraft.payload()` 的规则与 Mac 的 `AskDecision.validate` 一致：每题都要答、值去空白后非空且不超过 4000 个字符、多选按选项原顺序用 `BridgeProtocol.multiSelectSeparator` 连接。
- [ ] **Step 4: Run** 同 Step 2。Expected: 全部通过。
- [ ] **Step 5: Commit** `git commit -m "feat(client): answer drafts and request texts for phones"`

---

### Task 6: 会话、额度的显示文字和顺序

**Files:**
- Create: `Sources/CritterClient/Presentation/{SessionText,LimitsText,SessionOrder}.swift`
- Test: `Tests/CritterClientTests/{SessionTextTests,LimitsTextTests,SessionOrderTests}.swift`

**Interfaces:**
- Produces（全部照 Android `android/app/src/main/kotlin/local/critter/phone/ui/SessionUi.kt` 和 `core/logic/LimitsText.kt`、`SessionOrder.kt`，文字逐字照抄）：

```swift
public enum SessionText {
    public static func source(_ s: SessionSource) -> String     // Android sourceLabel：终端、VS Code、桌面版、其它、Codex、Codex · 终端…（注意和桌面版 SessionSource.label 不同，手机上用 Android 的）
    public static func isCodex(_ s: BridgeSession) -> Bool
    public static func visibleSource(_ s: BridgeSession) -> SessionSource
    public static func supportsMessages(_ s: BridgeSession) -> Bool
    public static func supportsAnswers(_ s: BridgeSession) -> Bool
    public static func canStopTurn(_ s: BridgeSession, online: Bool) -> Bool
    public static func messageHint(_ s: BridgeSession) -> String
    public static func waitingHint(_ s: BridgeSession, hasActionableRequest: Bool) -> String?
    public static func folderName(_ cwd: String) -> String
    public static func place(_ s: BridgeSession) -> String       // "目录 · 分支 · 来源"（视觉设计 §8.3 的顺序；没有分支时省掉）
    public static func doing(_ s: BridgeSession) -> String
    public static func contextPercent(_ c: BridgeContext) -> String
    public static func conn(_ state: ConnState) -> String        // Android connText；offline 是"未连接，正在重试"
    public static func ago(_ then: Date, now: Date) -> String    // "刚刚" / "5 分钟前" / "3 小时前"
}
public enum LimitsText {
    public static func percent(_ w: RateWindow?) -> String
    public static func resets(_ w: RateWindow?, now: Date, calendar: Calendar) -> String
    public static func staleness(updatedAt: Int64, now: Date) -> String?
}
public enum SessionOrder {
    public static func forBoard(_ body: SnapshotBody) -> [BridgeSession]   // 有待答请求的在前（按最早请求的时间），其余保持 Mac 的顺序
}
```

- [ ] **Step 1: 写失败的测试。** 把 `PresentationTest.kt`、`CodexSessionUiTest.kt`、`LimitsTextTest.kt`、`SessionOrderTest.kt` 里针对这些函数的测试逐个翻过来（时区用 `TimeZone(identifier: "Asia/Shanghai")`）。另加 `placeOrderIsFolderBranchSource()`：`cwd "~/CODESPACE/clawd"`、branch `main`、终端 → `"clawd · main · 终端"`。
- [ ] **Step 2: Run** `swift test --filter "SessionTextTests|LimitsTextTests|SessionOrderTests"`。Expected: 编译失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** 同 Step 2。Expected: 全部通过。
- [ ] **Step 5: Commit** `git commit -m "feat(client): session, quota and ordering texts for phones"`

---

### Task 7: App 的状态 `BridgeStore`

**Files:**
- Create: `Sources/CritterClient/Store/{BridgeStore,StoreProtocols}.swift`
- Test: `Tests/CritterClientTests/BridgeStoreTests.swift`（假的存储、假的连接、立即执行的后台任务）

**Interfaces:**
- Consumes: Task 3–6 的类型。
- Produces:

```swift
public struct StoredPairing: Codable, Equatable, Sendable {
    public var endpoint: Endpoint; public var fingerprint: String; public var macName: String; public var deviceId: String
}
public struct CachedSnapshot: Codable, Equatable, Sendable { public var body: SnapshotBody; public var receivedAt: Date }
public protocol PairingStorage: Sendable {
    func load() -> (StoredPairing, Credentials)?
    func save(_ pairing: StoredPairing, token: String)
    func updateEndpoint(_ endpoint: Endpoint)
    func clear()                                   // 配对和快照缓存一起删
    func loadSnapshot() -> CachedSnapshot?
    func saveSnapshot(_ snapshot: CachedSnapshot)
}
public protocol BridgeLink: Sendable {
    func start() async; func stop() async; func reconnectNow() async
    func request(_ command: BridgeCommand) async -> CommandResult
}
extension BridgeClient: BridgeLink {}
public protocol PairingLink: Sendable {
    func pair(_ target: PairingTarget, deviceName: String, onAwaitingApproval: @escaping @Sendable () -> Void) async -> PairResult
}
extension Pairer: PairingLink {}
@MainActor public protocol BackgroundRunner { func run(_ work: @escaping @MainActor () async -> Void) }

public enum PairingPhase: Equatable, Sendable { case connecting, awaitingApproval }

@MainActor @Observable public final class BridgeStore {
    public init(storage: any PairingStorage,
                makeLink: @escaping @MainActor (StoredPairing, @escaping @Sendable (BridgeEvent) -> Void) -> any BridgeLink,
                pairer: any PairingLink, background: any BackgroundRunner,
                backgroundGrace: Duration = .seconds(10), now: @escaping () -> Date = Date.init)
    public private(set) var pairing: StoredPairing?
    public private(set) var conn: ConnState
    public private(set) var snapshot: SnapshotBody?
    public private(set) var snapshotAt: Date?
    public private(set) var isLive: Bool            // 快照来自当前这条连接（否则是缓存或上一条连接的）
    public private(set) var pairingPhase: PairingPhase?
    public var canAct: Bool { get }                  // conn 是 .connected 且 isLive
    public func sceneBecameActive()
    public func sceneEnteredBackground()
    public func retry()
    public func pair(_ target: PairingTarget, deviceName: String) async -> PairResult
    public func unpair()
    public func send(_ command: BridgeCommand) async -> CommandResult
}
```

行为：
- 初始化时读出配对和缓存快照（`isLive = false`，`snapshotAt = receivedAt`），有配对就建好连接但不启动。
- 连接的事件经一个 `AsyncStream` 进来，在主 actor 上**按顺序**逐个处理（不要每个事件开一个 `Task`，会乱序）。`.state` → `conn`；状态不是 `connected` 时 `isLive = false`；`.snapshot` → `snapshot`、`snapshotAt = now()`、`isLive = true`，并保存缓存；`.connectedTo(e)` 和存的地址不同 → `storage.updateEndpoint(e)`。
- `sceneBecameActive` → 有配对就 `start()`（重复调用无害）。`sceneEnteredBackground` → 交给 `background.run`：等在途的 `send` 全部回来，最多等 `backgroundGrace`，然后 `stop()`。
- `send`：没配对或没连接 → `.failed("未连接")`；否则转给连接，并计入在途数量。
- `pair`：`pairingPhase` 依次 `.connecting`、`.awaitingApproval`，结束时清空。成功 → 先停掉旧连接，`storage.save`，换成新连接并启动，清空旧快照；失败 → 原来的配对和连接不动。
- `unpair` → 停连接、`storage.clear()`、所有状态清空、`conn = .idle`。

- [ ] **Step 1: 写失败的测试：**

```swift
@Test func restoresTheCachedSnapshotAtLaunch()        // isLive false，snapshotAt == 缓存的 receivedAt
@Test func activeStartsTheLinkOnlyWhenPaired()
@Test func snapshotsAreShownAndCached()               // isLive true，storage 收到 saveSnapshot
@Test func eventsAreAppliedInOrder()                  // 连发 100 个 state/snapshot 事件，最后的状态和快照是最后发的那个
@Test func reconnectingIsNotLiveUntilANewSnapshot()   // connected -> offline -> connected：canAct 在新快照到之前为 false
@Test func aNewAddressIsRemembered()                  // .connectedTo 新地址 -> storage.updateEndpoint
@Test func backgroundingWaitsForTheAnswerInFlight()   // 假连接的 request 挂起；进后台后 stop 没调用；放行后 stop 被调用
@Test func backgroundingGivesUpAfterTheGrace()        // grace 50ms：request 一直挂着，stop 仍被调用
@Test func pairingSuccessReplacesTheOldLink()         // 旧连接 stop，新连接 start，旧快照清空
@Test func pairingFailureKeepsTheOldPairing()
@Test func pairingPhasesAreReported()                 // connecting -> awaitingApproval -> nil
@Test func unpairForgetsEverything()
@Test func sendWhileNotConnectedFails()               // == .failed("未连接")
```

- [ ] **Step 2: Run** `swift test --filter BridgeStoreTests`。Expected: 编译失败。
- [ ] **Step 3: 实现。**
- [ ] **Step 4: Run** `swift test`。Expected: 全部通过。
- [ ] **Step 5: Commit** `git commit -m "feat(client): the phone app's state, with ordered events and a graceful background"`

---

### Task 8: Xcode 工程和 App 外壳

**Files:**
- Create: `ios/Critter.xcodeproj/project.pbxproj`、`ios/Critter.xcodeproj/xcshareddata/xcschemes/Critter.xcscheme`
- Create: `ios/Config/Critter.xcconfig`、`ios/Config/Info.plist`
- Create: `ios/Critter/CritterApp.swift`、`RootView.swift`、`Platform/KeychainPairingStorage.swift`、`Platform/UIKitBackgroundRunner.swift`、`Debug/DebugLaunch.swift`、`Debug/Fixtures/{home-mixed,empty,question,plan}.json`
- Modify: `Makefile`（`.PHONY` 加 `ios-sim`）、`.gitignore`（`ios/build/`、`xcuserdata/`）

**Interfaces:**
- Consumes: `BridgeStore` 及其协议（Task 7）、`BridgeClient`、`URLSessionTransport`、`FallbackResolver`、`BonjourBrowser`、`Pairer`。
- Produces: 可在模拟器运行的 App；`RootView` 没配对时显示 `PairingView`，否则显示 `HomeView`（这两个在 Task 9、10 写，这里先放只有标题的占位）。DEBUG 启动参数（`DebugLaunch` 解析，正式构建里不存在）：
  - `-critterFixture <名字>`：用 `Debug/Fixtures/<名字>.json`（一个 `SnapshotBody`）。App 改用"假存储 + 假连接"：假装已经和 `Fixture Mac` 配对，假连接一启动就发 `connected` 和这份快照；
  - `-critterFixtureResult ok|resolved|expired|failed`：假连接对所有请求的回复；
  - `-critterOpen answer:<requestId>|detail:<sessionId>|settings`：启动后直接打开对应的弹层；
  - `-critterPairURI <uri>`：启动后直接用这个 URI 配对，不弹确认框（给脚本用）；
  - `-critterDeviceName <名字>`：配对时用的设备名。

工程要求：
- `objectVersion = 77`，一个 App target `Critter`。源码用 `PBXFileSystemSynchronizedRootGroup` 同步 `ios/Critter/`，以后加文件不用改工程。`Config/` 放在同步目录外面（Info.plist 不进资源）。
- 本地包依赖：`XCLocalSwiftPackageReference`，`relativePath = ..`；产品 `CritterKit`、`CritterClient`。
- `Critter.xcconfig`：`PRODUCT_BUNDLE_IDENTIFIER = com.braynlabs.critter`、`PRODUCT_NAME = Critter`、`DEVELOPMENT_TEAM = XB89283VYM`、`CODE_SIGN_STYLE = Automatic`、`IPHONEOS_DEPLOYMENT_TARGET = 17.2`、`TARGETED_DEVICE_FAMILY = 1`、`SWIFT_VERSION = 6.0`、`INFOPLIST_FILE = Config/Info.plist`、`MARKETING_VERSION = 0.1`、`CURRENT_PROJECT_VERSION = 1`。两个配置（Debug、Release）都以它为基础。
- `Info.plist`：`CFBundleDisplayName = Critter`；`CFBundleURLTypes` 注册 `critter-pair`；`NSLocalNetworkUsageDescription = "Critter 要连接同一个 Wi‑Fi 里的 Mac，才能显示会话、在手机上作答。"`；`NSBonjourServices = [_critter._tcp]`；`NSCameraUsageDescription = "扫描 Mac 上显示的配对二维码。"`；`UISupportedInterfaceOrientations = [UIInterfaceOrientationPortrait]`；`UILaunchScreen = {}`；`UIApplicationSceneManifest` 里 `UIApplicationSupportsMultipleScenes = false`。
- `KeychainPairingStorage`：`PairingStorage` 的真实现。约定见 Global Constraints；快照缓存在后台队列写，原子写入。
- `UIKitBackgroundRunner`：`UIApplication.beginBackgroundTask` 包住工作，结束或到期时 `endBackgroundTask`。
- `CritterApp`：建 `BridgeStore`；`makeLink` 用 `BridgeClient(transport: URLSessionTransport(), endpoint: FallbackResolver(lastGood:macName:browser: BonjourBrowser()), ...)`，app 名 `critter-ios/<版本>`；`scenePhase` 变成 `.active` / `.background` 时通知 store；`.onOpenURL` 收 `critter-pair://` 链接（交给 Task 9 的确认流程）。
- `Makefile`：

```make
IOS_SIM ?= platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
ios-sim:
	xcodebuild -project ios/Critter.xcodeproj -scheme Critter -destination '$(IOS_SIM)' -derivedDataPath ios/build build
```

- [ ] **Step 1: 写工程文件、配置和外壳代码。**
- [ ] **Step 2: Run** `xcodebuild -list -project ios/Critter.xcodeproj`。Expected: Targets 和 Schemes 里都有 `Critter`。
- [ ] **Step 3: Run** `make ios-sim`。Expected: `** BUILD SUCCEEDED **`。
- [ ] **Step 4: 在模拟器里跑起来。** Run: `xcrun simctl boot "iPhone 17 Pro" 2>/dev/null; xcrun simctl install booted ios/build/Build/Products/Debug-iphonesimulator/Critter.app && xcrun simctl launch booted com.braynlabs.critter -critterFixture home-mixed && sleep 3 && xcrun simctl io booted screenshot /tmp/critter-ios-shell.png`。用 Read 看截图。Expected: App 没崩，显示首页占位（说明 fixture 路径通了）；不带参数启动显示配对占位。
- [ ] **Step 5: Commit** `git commit -m "feat(ios): the Xcode project and app shell"`

---

### Task 9: 配对界面

**Files:**
- Create: `ios/Critter/Pairing/{PairingView,ManualPairView,PairingProgressView}.swift`、`ios/Critter/Platform/QRScannerView.swift`
- Modify: `ios/Critter/CritterApp.swift`（深链接）

**Interfaces:**
- Consumes: `BridgeStore.pair` / `pairingPhase`、`PairingTarget(uri:)`、`PairFailure.text`、`CertificateProbe`、`BonjourBrowser`、`PairingCode.alphabet` / `.length`、`PairingURI.fingerprintPrefix(_:)`、`PrivateNetwork.isAllowed(host:)`。

界面（文案逐字照抄 `android/app/src/main/kotlin/local/critter/phone/ui/pairing/PairingScreen.kt`，行号是现在的版本）：
- **扫码页**：标题"扫 Mac 上的二维码"，说明（第 464 行），取景框用 VisionKit `DataScannerViewController`（只认 QR）；`DataScannerViewController.isSupported && isAvailable` 为假时（比如模拟器）显示"这台设备不能扫码，可以用系统相机扫，或者手动输入"。按钮「手动输入」。扫到的不是 `critter-pair://` → "这不是 Critter 的配对二维码。"（第 255 行）；地址不在局域网 → 第 173 行那句。
- **深链接确认**（系统相机扫码、`simctl openurl`）：确认框"和这台 Mac 配对？"，正文、地址、证书指纹、提示照第 215–232 行；已经配对过时加红字"这会替换现在和「…」的配对。"；地址不在局域网 → 第 203 行那句，不弹确认框。
- **手动输入**：标题"手动输入"，"局域网里的 Mac"列表（`BonjourBrowser.discover()`，进入页面时找一次，找的时候显示"正在寻找…"，可以下拉刷新）；"Mac 上显示的 8 位码"，4+4 两组格子，只收 `PairingCode.alphabet` 里的字符（小写自动转大写）；按钮「连接」（连接中显示"正在连接…"）。点连接先用 `CertificateProbe` 读指纹（失败 → 第 268 行那句），弹"信任这台 Mac？"（第 614–624 行，指纹用 `fingerprintPrefix`），确认后用这个指纹配对。「改用扫码」回扫码页。
- **配对中**（`pairingPhase`）：`.connecting` 显示"连接中…"；`.awaitingApproval` 显示"在 Mac 上点「允许」"和说明"Mac 的「添加手机」窗口里出现了下面这一行。点允许之后，这里会自己往下走。"（第 282 行），下面画那一行："「<设备名>」请求连接"加不能点的「拒绝」「允许」；按钮「取消」。
- **失败**：显示 `PairFailure.text`，按钮「重新扫码」。成功后 `RootView` 自己切到首页。

- [ ] **Step 1: 实现上面的界面。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图检查**（模拟器，同 Task 8 Step 4 的装法）：无参数启动 → 扫码页（应显示"这台设备不能扫码…"）；`xcrun simctl openurl booted "critter-pair://192.168.1.20:47823?fp=<64位>&code=K7M2QX9P&name=Mac"` → 确认框；`openurl` 一个 `8.8.8.8` 的链接 → 局域网提示，没有确认框。逐张用 Read 看。Expected: 文案与上面一致，排版没有截断或重叠。
- [ ] **Step 4: 和真的 Mac 配对**（前置条件同 Task 4 Step 6）：照 `client-live-check.sh` 拿一个自动批准的 URI，`xcrun simctl launch booted com.braynlabs.critter -critterPairURI "$URI" -critterDeviceName critter-bridge-client`，10 秒后截图。Expected: 进了首页占位、显示已连接。重启 App（`simctl terminate` 再 `launch`，不带参数）仍然是已配对。结束后用 `critter://debug-bridge-revoke?deviceId=...` 撤销（deviceId 从 App 的 `UserDefaults` 读：`xcrun simctl spawn booted defaults read com.braynlabs.critter critter.pairing`）。
- [ ] **Step 5: Commit** `git commit -m "feat(ios): pairing by QR code, link or code"`

---

### Task 10: 首页和会话详情

**Files:**
- Create: `ios/Critter/Home/{HomeView,SessionRow,LimitsCards}.swift`、`ios/Critter/Detail/DetailSheet.swift`、`ios/Critter/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `BridgeStore`（`snapshot`、`conn`、`canAct`、`snapshotAt`、`send`、`retry`、`unpair`）、`SessionText`、`LimitsText`、`SessionOrder.forBoard`、`RequestText`、`AnswerOutcome`、`AnswerDraft`。
- Produces: `HomeView`；`DetailSheet(sessionId:)`；首页里的权限请求直接答（走 Task 11 的同一个提交函数 `AnswerSubmit.submit(draft:store:) async -> AnswerOutcome`，在本任务里先建好放在 `ios/Critter/Answer/AnswerSubmit.swift`，`markSubmitted()` 为假时直接返回）。

界面（结构照视觉设计 §8.3、§8.5，这一轮先用系统字体和系统颜色，像素外观在后面的计划）：
- 顶部：Mac 名字 + `SessionText.conn(conn)`；右上角设置按钮。
- 两张额度卡：名字（"5 小时"、"7 天"）、`LimitsText.percent`、进度条、`LimitsText.resets`；`limits` 有 `staleness` 时加上那句。
- 会话列表按 `SessionOrder.forBoard`：每行状态名、名字、`SessionText.doing`、`SessionText.place`、上下文百分比条和 `contextPercent`。等你确认的行排最前、橙色描边：权限请求多一块等宽的命令（`permissionBody`，最多 8 行）和「拒绝」「允许」两个按钮；提问和计划是「打开回答」；`waitingHint` 有值时显示它、不显示按钮。
- 不能作答（`canAct` 为假）时作答按钮变灰，写"连上后才能作答"。
- 离线：顶部一张卡"连不上 <Mac 名>，正在重试，下面是 <ago> 的样子"带「重试」（`store.retry()`）；`needsRepair` 时显示原因和「重新配对」（`unpair()` 后回到配对页）。
- 空状态："电脑上还没有会话" / "在电脑上开一个 Claude Code 会话，它的宠物会从这片草地里钻出来。"
- 点一行：等你确认 → 打开作答卡片（Task 11）；做完了 → 发 `.seen` 并打开详情；其它 → 打开详情。
- 详情弹层（`.sheet`，`presentationDetents([.medium, .large])`）：名字 + 状态、`doing`、目录、分支、来源、模型、上下文、最后更新（`ago(eventTime)`）。「发一句」输入框 + 发送（`supportsMessages` 为假时禁用，下面写 `messageHint`；文字去空白后为空或超过 `BridgeProtocol.maxSayUTF16Units` 个 UTF-16 单元时不能发）；发送成功显示绿字"已送到"并清空，失败显示结果的 message。`canStopTurn` 时显示「停止当前回合」，发 `.interrupt`。
- 设置页（这一轮只有连接一组）：已配对的 Mac、状态、「重新配对」（回到扫码页，旧配对在新配对成功前保留）、「取消配对」（确认后 `unpair()`）。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图检查：** `-critterFixture home-mixed`（首页：等你确认的权限行在最前、带按钮；Codex 只读会话显示提示不显示按钮）、`-critterFixture empty`、`-critterFixture home-mixed -critterOpen detail:<一个 Codex 会话的 id>`（有「停止当前回合」）、`-critterOpen settings`。逐张用 Read 看。Expected: 内容、顺序、文案与上面一致，深色模式（`xcrun simctl ui booted appearance dark`）下也看得清。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): the home list, session details and settings"`

---

### Task 11: 作答卡片

**Files:**
- Create: `ios/Critter/Answer/{AnswerSheet,QuestionForm}.swift`
- Modify: `ios/Critter/Answer/AnswerSubmit.swift`、`ios/Critter/Home/HomeView.swift`（打开卡片）、`ios/Critter/Debug/DebugLaunch.swift`（新增 DEBUG 启动参数 `-critterAutoSubmit allow|approve|first-option`）

**Interfaces:**
- Consumes: `CardState`、`AnswerDraft`、`RequestText`、`AnswerOutcome`、`successLabel`、`SessionText`、`BridgeStore`。
- Produces: `AnswerSheet(requestId:)`，由首页和 `-critterOpen answer:<id>` 打开。

规则（Android 设计 §8.5、视觉设计 §8.6、Android `AnswerSheet.kt`）：
- 卡片只按 `requestId` 取请求；用 `CardState` 决定显示什么。`.handledElsewhere` / `.unknown`："已在电脑上处理"（或"这个请求已经不在了"），2 秒后自己关。
- 共用外壳：标题 `RequestText.title`，副标题 `SessionText.place`，底部"电脑上也能答，谁先答算谁的"。
- 权限：命令或路径（等宽，完整显示，可滚动）；「拒绝并写理由…」（`acceptsDenyMessage` 为假时不显示）展开一个输入框；「拒绝」「允许」。
- 提问：每题小标签（`header`）+ 问题；选项卡片（标题 + 说明），单选圆点、多选方框；「自己写一句…」；`submitsOnPick` 时点选项就提交，否则底部「提交 n 个回答」，`payload()` 为 nil 时不可点。
- 计划：计划原文按 Markdown 显示（`AttributedString(markdown:)`，失败就显示原文），可滚动；「让它改…」（要写修改意见）和「批准计划」。
- 提交后按 `AnswerOutcome`：`.sent` → 主按钮换成 `successLabel`（拒绝、让它改没有这一步），0.9 秒后关；`.handledElsewhere` → "已在电脑上处理"，2 秒后关；`.expired(m)` → 显示 m，2 秒后关；`.failed(m)` → m 显示在按钮上方，卡片不关，可以再点。
- `canAct` 为假时所有按钮变灰，写"未连接，连上后才能作答"。
- 同一个请求只提交一次（`markSubmitted()`），首页按钮和卡片共用同一个草稿（按 requestId 存在首页的状态里）。

- [ ] **Step 1: 实现。**
- [ ] **Step 2: Run** `make ios-sim`。Expected: BUILD SUCCEEDED。
- [ ] **Step 3: 截图检查：** 三种请求各一张（`-critterFixture home-mixed -critterOpen answer:<权限 id>`、`question`、`plan`）；四种结果各一张（加 `-critterFixtureResult ok|resolved|expired|failed`，提交动作用一个 DEBUG 启动参数 `-critterAutoSubmit allow|approve|first-option` 在卡片出现 1 秒后自动执行，截图在 1.5 秒时取）。Expected: 和上面的规则一致。
- [ ] **Step 4: Commit** `git commit -m "feat(ios): answer cards for permissions, questions and plans"`

---

### Task 12: 模拟器连真的 Mac、收尾

**Files:**
- Create: `scripts/dev/ios-sim-live.sh`
- Modify: `README.md`（新增一节"iOS（开发中）"）

- [ ] **Step 1: 写 `scripts/dev/ios-sim-live.sh`。** 前置检查和清理同 `client-live-check.sh`；中间：`make ios-sim`，启动模拟器、装 App、用 `-critterPairURI "$URI" -critterDeviceName critter-bridge-client` 启动，等 10 秒截图到 `$OUT/home.png`；`simctl terminate` 再不带参数 `launch`，等 5 秒截图到 `$OUT/relaunch.png`；从 App 的 `UserDefaults` 读 deviceId，撤销；打印截图路径。
- [ ] **Step 2: Run** `scripts/dev/ios-sim-live.sh`。用 Read 看两张截图。Expected: 都显示"已连接"和 Mac 上真实的会话列表（和桌面上看到的会话一致）；脚本退出码 0；Mac 设置里没有留下 `critter-bridge-client`。**不要对真实会话发 `seen`、`say`、`interrupt` 或作答**。
- [ ] **Step 3: 写 README 一节。** 内容：iOS 版在开发中；现在能做什么（配对、看会话、作答，只在 App 开着时）；怎么在模拟器里跑（`make ios-sim`、`scripts/dev/ios-sim-live.sh`）；装到真机、推送、实时活动、看板在后面的计划。
- [ ] **Step 4: 全量验证。** Run: `swift test 2>&1 | tail -3 && make app && make ios-sim 2>&1 | tail -1`。Expected: 测试全部通过（N + 本计划新增的数量），两个构建都成功。
- [ ] **Step 5: Commit** `git commit -m "docs: running the iOS app in the simulator against a real Mac"`
