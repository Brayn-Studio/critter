# Critter 手机端 · 计划 2：安卓骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 做出一个能侧载的安卓 App，具备以下能力：
- 和 Mac 上的 Critter 配对，用前台服务保持连接；
- 竖屏显示会话列表，横屏显示专业看板；
- 在作答卡片上处理权限、提问和计划；
- 有会话需要你时短震并发通知，权限请求可以直接在通知上点允许或拒绝。

小人动画、悬浮球、自动打开看板放在计划 3。

**Architecture:** 两个 Gradle 模块。
- `:core` 是纯 Kotlin/JVM 库，内容有：协议模型、配对 URI、固定证书指纹的 WebSocket 客户端（OkHttp）、重连退避、提醒判断、回答草稿校验、额度文案。全部用 JVM 单元测试覆盖，TLS 部分用 MockWebServer 加自签名证书测。
- `:app` 只负责界面（Compose）和安卓相关的部分：前台服务、NSD、通知、权限。

**Tech Stack:**
- AGP 9.4.1（内置 Kotlin）、Kotlin 2.4.21、Gradle 9.8.1 wrapper、JDK 21；
- compileSdk / targetSdk 37，minSdk 29；
- Jetpack Compose（BOM 2026.09.00）、kotlinx.serialization 1.11.0、kotlinx.coroutines 1.11.0、OkHttp 5.5.0、CameraX 1.6.2、ZXing core 3.5.4；
- 测试：kotlin-test（JUnit 5）、mockwebserver3 5.5.0、okhttp-tls 5.5.0。

**Spec:** `docs/superpowers/specs/2026-10-18-critter-android-design.md`，重点是 §7、§8.1、§8.3、§8.5、§8.6、§8.7、§9、§10。

**协议以 `docs/critter-bridge-protocol.md` 为准**，这份文档由计划 1 的 Task 7 产出，计划 1 必须已经完成。

## Global Constraints

- 包名和 applicationId 都是 `local.critter.phone`；App 名称是 `Critter`。
- 依赖只用上面 Tech Stack 列出的这些，加上 AndroidX 的 core-ktx 1.19.1、activity-compose 1.13.0、lifecycle-runtime-compose 2.11.0、Material3（版本由 BOM 决定）。不依赖 Google Play 服务（spec §8.1）。
- 本机构建要走代理。代理配置在 `~/.gradle/gradle.properties` 里，不能写进仓库。
- 前台服务类型是 `connectedDevice`。需要的权限有：`FOREGROUND_SERVICE`、`FOREGROUND_SERVICE_CONNECTED_DEVICE`、`CHANGE_WIFI_MULTICAST_STATE`、`ACCESS_NETWORK_STATE`、`INTERNET`、`POST_NOTIFICATIONS`、`VIBRATE`、`RECEIVE_BOOT_COMPLETED`、`CAMERA`、`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`、`ACCESS_LOCAL_NETWORK`。`ACCESS_LOCAL_NETWORK` 只在 API 37 及以上运行时申请（spec §4.3）。
- 断线重连：从 2 秒起，每次翻倍，封顶 60 秒；网络变化时立即重连一次；不在 Wi-Fi 上时不重连。例外：地址是 `127.0.0.1` 时（开发时用 `adb reverse`）不检查 Wi-Fi（spec §8.3）。
- 心跳（WebSocket ping）：看板打开时每 30 秒一次，其它时候每 3 分钟一次（spec §8.3）。
- 省电（spec §9）：
  - 一条长连接，不轮询；
  - 不用 AlarmManager 或 WorkManager 做周期任务；
  - 常亮只用 `FLAG_KEEP_SCREEN_ON`；
  - 时钟每分钟只重组一次；
  - 不用无限循环的 Compose 动画。
- 文案逐字照抄：
  - 底部小字："电脑上也能答，谁先答算谁的"
  - 卡片被别处处理后的提示："已在电脑上处理"
  - 前台通知的标题："已连接 · N 个会话"，断开时是"未连接"
  - 状态名沿用桌面版：空闲、运行中、等你确认、做完了、出错
- 作答只能针对快照 `pending` 里还存在的 `requestId`，卡片绝不按"这个会话当前的请求"去取（spec §8.5）。
- 本地只存三样东西：配对信息（Mac 地址、端口、指纹、deviceId、token）、最后一次快照、设置项。全部放在应用私有存储（spec §10）。

## Review Focus

1. **Mac 重启后，自签名证书没变，但 IP 变了。** 客户端应该通过 NSD 按服务名找到新地址，再用同一个指纹连上，不需要重新配对。由 Task 4 的 `clientReconnectsToNewAddressWithSamePin` 覆盖。
2. **证书指纹不匹配**（中间人，或者 Mac 重置了配对）。必须拒绝连接，状态变成"需要重新配对"，而且不能每 2 秒重试一次把电耗光：指纹错误不进入退避重连。由 Task 4 的 `pinMismatchStopsRetrying` 覆盖。
3. **同一个请求，通知和卡片几乎同时点了"允许"。** 第二次提交应该得到 `resolved`，或者被本地去重，不能产生两次回答。由 Task 3 的 `answerDraftSubmitsOncePerRequest` 和 Task 7 的界面状态共同覆盖。
4. **快照里多了 App 不认识的字段或枚举值**，比如将来的协议版本或新的 `source`。解码不能崩，未知的枚举映射成 `other` 或 `unknown`。由 Task 2 的 `decodeToleratesUnknownFieldsAndEnums` 覆盖。
5. **一次快照里同时有好几个会话变成"等你确认"。** 只震一次，每个请求各发一条通知；请求了结后，对应的通知撤回。由 Task 3 的 `alertPlannerVibratesOncePerSnapshot` 和 `alertPlannerCancelsResolved` 覆盖。

---

## 文件结构

```
android/
  settings.gradle.kts            build.gradle.kts            gradle.properties
  gradle/libs.versions.toml      gradle/wrapper/…           gradlew  gradlew.bat
  core/build.gradle.kts
  core/src/main/kotlin/local/critter/core/
    protocol/Messages.kt         协议模型和编解码
    protocol/PairingUri.kt       配对 URI 的解析与生成
    net/PinnedTls.kt             按指纹固定证书的 TrustManager 和 HostnameVerifier
    net/BridgeClient.kt          WebSocket 客户端：状态流、请求和回执的对应、心跳
    net/ReconnectBackoff.kt      退避策略
    logic/AlertPlanner.kt        前后两份快照 → 要发、要撤的提醒
    logic/AnswerDraft.kt         界面上的作答状态 → AnswerPayload，包括校验和防重复提交
    logic/LimitsText.kt          额度、重置时间、"x 分钟前"等文案
    logic/SessionOrder.kt        看板的排序（需要你的排在前面）
  core/src/test/kotlin/…         各个类对应的测试
  core/src/test/resources/protocol/*.json   从协议文档里摘出来的示例
  app/build.gradle.kts
  app/src/main/AndroidManifest.xml
  app/src/main/kotlin/local/critter/phone/
    CritterApp.kt                Application：创建通知渠道，持有 BridgeRepository
    data/PairingStore.kt         SharedPreferences
    data/SettingsStore.kt        SharedPreferences，用 StateFlow 暴露
    data/SnapshotCache.kt        最后一次快照存成文件
    bridge/BridgeRepository.kt   包装 BridgeClient，加上 NSD 和网络监听，供服务和界面共用
    bridge/NsdLocator.kt         NSD 发现，短时间持有 MulticastLock
    service/BridgeService.kt     前台服务
    service/BootReceiver.kt      开机和 App 更新后重启服务
    service/Alerts.kt            通知渠道、发通知、撤通知、震动
    service/NotificationActionReceiver.kt   通知上的"允许""拒绝"
    ui/MainActivity.kt           入口：没配对时进配对页，配对后进首页
    ui/pairing/*.kt              扫码（CameraX + ZXing）、手动输入、深链接
    ui/home/*.kt                 竖屏的会话列表和连接状态
    ui/answer/AnswerActivity.kt  半透明的底部弹层：权限、提问、计划
    ui/answer/MarkdownLite.kt    计划正文用的极简 Markdown 渲染
    ui/board/BoardActivity.kt    横屏专业看板
    ui/settings/SettingsScreen.kt
    ui/theme/*.kt
Makefile（改）                   新增 android 和 android-install 两个目标
.gitignore（改）                 忽略 android/build、android/*/build、android/.gradle、android/local.properties、android/keystore.properties
```

---

### Task 1: 工程脚手架

**Files:**
- Create: 上面结构里所有 Gradle 文件，`core` 和 `app` 两个模块的 `build.gradle.kts`，`AndroidManifest.xml`（暂时只有一个空的 `MainActivity`），`CritterApp.kt`
- Modify: `Makefile`、`.gitignore`

**Interfaces:**
- Produces（后面的任务都依赖这些）：
  - `android/gradle/libs.versions.toml` 里的版本别名：`agp = "9.4.1"`、`kotlin = "2.4.21"`、`serialization = "1.11.0"`、`coroutines = "1.11.0"`、`okhttp = "5.5.0"`、`composeBom = "2026.09.00"`、`activityCompose = "1.13.0"`、`lifecycle = "2.11.0"`、`coreKtx = "1.19.1"`、`camerax = "1.6.2"`、`zxing = "3.5.4"`。
  - 插件别名：`android-application`、`kotlin-jvm`、`kotlin-serialization`、`kotlin-compose`。
  - `:core` 应用 `kotlin-jvm` 和 `kotlin-serialization`，`jvmToolchain(21)`，测试用 JUnit Platform。
  - `:app` 应用 `android-application`（内置 Kotlin）、`kotlin-compose`、`kotlin-serialization`，依赖 `project(":core")`。`namespace` 和 `applicationId` 都是 `local.critter.phone`，`minSdk 29`、`targetSdk 37`、`compileSdk 37`。
  - `android/local.properties` 由 Makefile 生成，内容是 `sdk.dir=$HOME/Library/Android/sdk`，不进 git。
  - Makefile 的两个新目标：
    - `make android`：执行 `cd android && ./gradlew :core:test :app:assembleRelease`。release 用本地 keystore 签名：
      - keystore 放在 `$HOME/.android/critter-release.jks`，第一次运行时用 `keytool -genkeypair` 生成，别名 `critter`；
      - 密码写在 `android/keystore.properties`，第一次随机生成，不进 git。
    - `make android-install`：执行 `adb install -r android/app/build/outputs/apk/release/app-release.apk`，然后 `adb shell am start -n local.critter.phone/.ui.MainActivity`。
- 第一次生成 wrapper 时，用 `~/.local/share/gradle-9.8.1/bin/gradle wrapper --gradle-version 9.8.1`。

- [ ] **Step 1: 建好脚手架。** `:core` 里先放一个占位测试 `class SmokeTest { @Test fun builds() = assertTrue(true) }`。这个测试在 Task 2 删掉。
- [ ] **Step 2: 构建并在真机上运行**

Run: `make android && make android-install && sleep 2 && ~/Library/Android/sdk/platform-tools/adb exec-out screencap -p > /tmp/critter-t1.png`
Expected: 构建成功；App 在 vivo 真机上启动；截图里能看到空白的 Compose 页面，标题是 "Critter"。

- [ ] **Step 3: 提交**

```bash
git add android Makefile .gitignore
git commit -m "feat(android): scaffold the Critter phone app"
```

---

### Task 2: 协议模型和编解码（`:core`）

**Files:**
- Create: `core/src/main/kotlin/local/critter/core/protocol/Messages.kt`、`PairingUri.kt`
- Create: `core/src/test/resources/protocol/*.json`，从 `docs/critter-bridge-protocol.md` 里逐字摘出每种消息的示例，一种消息一个文件
- Test: `core/src/test/kotlin/local/critter/core/protocol/MessagesTest.kt`、`PairingUriTest.kt`

**Interfaces:**
- Produces:
  - `sealed interface ServerMessage`，包含 `Welcome`、`Paired`、`Denied(reason: DenyReason)`、`Snapshot(seq, sentAt, body: SnapshotBody)`、`Skin(id, name, manifest: JsonObject?)`、`Result(id, ok, reason: ResultReason?, message)`；入口是 `fun decodeServer(text: String): ServerMessage?`。
  - `sealed interface ClientMessage`，包含 `Hello`、`Pair`、`Answer(id, requestId, payload: AnswerPayload)`、`Seen`、`Say`、`SkinRequest`；入口是 `fun encode(msg: ClientMessage): String`。
  - 数据类 `SnapshotBody`、`BridgeSession`、`BridgeContext`、`BridgeLimits`、`RateWindow`、`BridgePending`、`BridgePrefs`、`AnswerPayload`：字段名和类型与协议文档完全一致。
  - 几个枚举：
    - `SessionSource { terminal, vscode, desktop, other }`
    - `PetState { idle, running, waiting, done, error, unknown }`
    - `PendingKind { permission, question, plan, unknown }`
    - `DenyReason`、`ResultReason`：都再加一个 `unknown`
  - JSON 实例 `val BridgeJson = Json { ignoreUnknownKeys = true; explicitNulls = false; coerceInputValues = true }`。不认识的枚举值靠自定义 serializer 落到 `other` 或 `unknown`。
  - `data class PairingUri(host, port: Int, fingerprint: String, code: String, name: String)`，以及 `companion fun parse(s: String): PairingUri?`、`override fun toString()`。格式和协议文档一致，IPv6 主机加方括号。
  - `fun sha256Hex(der: ByteArray): String`：小写十六进制。

- [ ] **Step 1: 写失败的测试**

```kotlin
@Test fun decodesEveryDocumentedServerExample()   // 资源里每个 server-*.json 都能解码成对应的类型，抽查关键字段
@Test fun encodesClientMessagesToDocumentedShape() // encode(Hello(...)) 和 client-hello.json 解析成 JsonElement 后相等；其它客户端消息同理
@Test fun decodeToleratesUnknownFieldsAndEnums() {
    val s = """{"type":"snapshot","seq":1,"sentAt":1,"future":true,"body":{"sessions":[{"id":"a","name":"n","source":"jetbrains","state":"sleeping","cwd":"~","skin":"clawd","eventTime":1,"startedAt":1,"tracked":true}],"pending":[],"prefs":{"skin":"clawd","randomSkins":false,"idleDim":1.0,"mergeThreshold":4}}}"""
    val snap = decodeServer(s) as ServerMessage.Snapshot
    assertEquals(SessionSource.other, snap.body.sessions[0].source)
    assertEquals(PetState.unknown, snap.body.sessions[0].state)
}
@Test fun unknownMessageTypeDecodesToNull()
@Test fun pairingUriRoundTrip()                   // 用例和 Swift 侧相同：IPv4、IPv6、中文电脑名
@Test fun pairingUriRejectsGarbage()              // 缺 fp、端口不是数字、scheme 不对 → null
```

（如果实际示例的嵌套方式和上面的 JSON 不同，以协议文档为准，改测试。）

- [ ] **Step 2: 运行，确认测试失败**

Run: `cd android && ./gradlew :core:test`
Expected: 编译失败。

- [ ] **Step 3: 实现。** 删掉 Task 1 的 `SmokeTest`。
- [ ] **Step 4: 运行，确认测试通过**

Run: `cd android && ./gradlew :core:test`
Expected: BUILD SUCCESSFUL，以上测试全部通过。

- [ ] **Step 5: 提交**

```bash
git add android/core
git commit -m "feat(android): bridge protocol models and pairing links"
```

---

### Task 3: 纯逻辑（`:core`）：退避、提醒、作答草稿、额度文案、排序

**Files:**
- Create: `core/src/main/kotlin/local/critter/core/net/ReconnectBackoff.kt`
- Create: `core/src/main/kotlin/local/critter/core/logic/AlertPlanner.kt`、`AnswerDraft.kt`、`LimitsText.kt`、`SessionOrder.kt`
- Test: 每个文件对应一个测试类

**Interfaces:**
- Consumes: Task 2 的模型。
- Produces:
  - `class ReconnectBackoff(initialMs: Long = 2_000, maxMs: Long = 60_000)`，方法有 `fun nextDelayMs(): Long`（2000、4000、8000…封顶 60000）和 `fun reset()`。
  - `data class AlertPlan(val vibrate: Boolean, val post: List<BridgePending>, val cancel: List<String>, val sessionAlerts: List<Pair<BridgeSession, PetState>>)`
  - `object AlertPlanner`，方法是 `fun plan(previous: SnapshotBody?, current: SnapshotBody, prefs: AlertPrefs): AlertPlan`：
    - `previous == null`（第一份快照）时，只发通知，不震动；这和桌面版"第一次快照不响"一致。
    - `post`：出现在 `current.pending`、但不在 `previous.pending` 里的请求。
    - `cancel`：在 `previous.pending` 里、但不在 `current.pending` 里的 requestId。
    - `vibrate`：当 `prefs.vibrateOnWaiting` 为真，并且至少有一个会话从非 waiting 变成 waiting 时，为 true。一份快照最多震一次。
    - `sessionAlerts`：刚变成 done 或 error 的会话，只在 `prefs.notifyDone` 或 `prefs.notifyError` 打开时才包含。
  - `data class AlertPrefs(val vibrateOnWaiting: Boolean = true, val notifyDone: Boolean = false, val notifyError: Boolean = false)`
  - `class AnswerDraft(val request: BridgePending)`：
    - 方法：`fun allow()`、`fun deny(message: String?)`、`fun approve()`、`fun revise(message: String)`、`fun choose(question: String, label: String)`、`fun toggle(question: String, label: String)`（多选题）、`fun freeText(question: String, text: String)`；
    - `fun payload(): AnswerPayload?`：草稿不完整或不合法时返回 null，规则和 Mac 端的 `AskDecision.validate` 一致；
    - `fun markSubmitted(): Boolean`：同一个草稿只有第一次调用返回 true；
    - 多选题的拼接方式以计划 1 Task 10 实测得到的结果为准，结论写在协议文档的"AskUserQuestion answers"一节。
  - `object LimitsText`，方法有：
    - `fun percent(w: RateWindow?): String`：例如 "16%"，没有数据时是 "—"；
    - `fun resets(w: RateWindow?, nowMs: Long, zone: ZoneId): String`：
      - 已经过了重置时间："已重置"；
      - 不到 1 小时："还剩 49 分钟"；
      - 今天之内："21:40 重置"；
      - 更晚："周四 09:00 重置"；
    - `fun staleness(updatedAtMs: Long, nowMs: Long): String?`：超过 30 分钟时返回 "x 分钟前"，超过 2 小时返回 "x 小时前"，否则返回 null。
  - `object SessionOrder`，方法 `fun forBoard(body: SnapshotBody): List<BridgeSession>`：有待答请求的会话排最前面（按请求的 createdAt 升序），其余保持原顺序。

- [ ] **Step 1: 写失败的测试**

```kotlin
@Test fun backoffDoublesToCapAndResets()
@Test fun alertPlannerFirstSnapshotPostsWithoutVibrating()
@Test fun alertPlannerVibratesOncePerSnapshot()   // 两个会话同时变成 waiting → vibrate == true，post 有 2 条
@Test fun alertPlannerCancelsResolved()           // 请求 r1 消失 → cancel == ["r1"]
@Test fun alertPlannerDoneOnlyWhenEnabled()
@Test fun answerDraftPermission()                 // allow() → AnswerPayload(decision="allow")；deny(" ") → AnswerPayload(decision="deny", message=null)
@Test fun answerDraftQuestionNeedsEveryQuestion() // 有两道题时只答一道 → payload() == null
@Test fun answerDraftPlanReviseNeedsMessage()
@Test fun answerDraftSubmitsOncePerRequest()      // markSubmitted() 第一次返回 true，第二次返回 false
@Test fun limitsTextResetsVariants()              // 固定 zone = Asia/Shanghai，覆盖四种情况
@Test fun limitsTextStaleness()
@Test fun sessionOrderPutsWaitingFirst()
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `cd android && ./gradlew :core:test`
Expected: 编译失败。

- [ ] **Step 3: 实现**
- [ ] **Step 4: 运行，确认测试通过**

Run: `cd android && ./gradlew :core:test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add android/core
git commit -m "feat(android): reconnect, alert and answer logic"
```

---

### Task 4: WebSocket 客户端，固定证书指纹（`:core`）

**Files:**
- Create: `core/src/main/kotlin/local/critter/core/net/PinnedTls.kt`、`BridgeClient.kt`
- Test: `core/src/test/kotlin/local/critter/core/net/BridgeClientTest.kt`。用 mockwebserver3 起一个服务端，证书用 okhttp-tls 的 `HeldCertificate` 现场生成。

**Interfaces:**
- Consumes: Task 2 的消息和 `sha256Hex`，Task 3 的 `ReconnectBackoff`。
- Produces:
  - `object PinnedTls { fun client(fingerprint: String, base: OkHttpClient = OkHttpClient()): OkHttpClient }`：
    - 自定义的 `X509TrustManager` 只信任叶子证书 DER 的 SHA-256 等于 `fingerprint` 的证书；
    - `HostnameVerifier` 总是放行，因为身份已经由指纹保证（spec §6.5）；
    - 指纹不符时抛出 `PinMismatchException`。
  - `sealed interface ConnState`，取值有 `Idle`、`Connecting`、`AwaitingApproval`（配对时等 Mac 上确认）、`Connected(macName: String)`、`Offline(retryInMs: Long, since: Long)`、`NeedsRepair(reason: String)`（指纹不符、令牌被拒，或者 `denied`）。
  - `interface Endpoint { suspend fun resolve(): Pair<String, Int>? }`：给出当前要连的地址和端口。App 端用"上次成功的地址，失败了就 NSD 重新发现"来实现；测试里返回固定值。
  - `class BridgeClient(scope: CoroutineScope, endpoint: Endpoint, fingerprint: String, credentials: () -> Credentials?, clock: () -> Long = System::currentTimeMillis)`：
    - 状态流：`val state: StateFlow<ConnState>`、`val snapshot: StateFlow<ServerMessage.Snapshot?>`；
    - `val pairing: SharedFlow<ServerMessage.Paired>`；
    - `fun start()`、`fun stop()`；
    - `fun setPingInterval(ms: Long)`：30_000 或 180_000；改了以后要重建 OkHttpClient，并重新连接；
    - `suspend fun request(msg: ClientMessage): ServerMessage.Result`：自动生成 `id`，10 秒内没收到对应 `result` 时，返回 `Result(ok=false, reason=unknown, message="超时")`；
    - `suspend fun pair(uri: PairingUri, deviceName: String): ServerMessage.Paired?`：用 `uri` 里的指纹建立连接，发 `pair`，最多等 120 秒用户在 Mac 上确认。
  - `data class Credentials(val deviceId: String, val token: String)`
- **规则**：
  - 收到 `denied(badToken)`、`denied(protocol)`，或者出现 `PinMismatchException`：进入 `NeedsRepair`，**不再自动重连**。
  - 其它断线：进入 `Offline`，按退避时间重连；连上以后重置退避。
  - 每次连上都会先收到 `welcome`，然后是 `snapshot`。

- [ ] **Step 1: 写失败的测试**

```kotlin
@Test fun helloThenSnapshotFlows()                     // 服务端收到 hello 后回 welcome 和 snapshot → state 是 Connected，snapshot 有值
@Test fun requestMatchesResultById()                   // 服务端把收到的 id 原样放进 result 返回
@Test fun requestTimesOut()                            // 用虚拟时钟或缩短超时
@Test fun pinMismatchStopsRetrying()                   // 指纹给错 → NeedsRepair，此后服务端再也没收到连接
@Test fun badTokenNeedsRepair()
@Test fun dropReconnectsWithBackoff()                  // 服务端断开 → Offline(retryInMs = 2000) → 重新连上
@Test fun clientReconnectsToNewAddressWithSamePin()    // endpoint 第二次 resolve 给出另一个端口上的新服务端（证书相同）→ 连上，不需要重新配对
@Test fun pairWaitsForApproval()                       // 服务端在收到 pair 2 秒后才回 paired → pair() 返回 Paired，过程中 state 是 AwaitingApproval
```

- [ ] **Step 2: 运行，确认测试失败**

Run: `cd android && ./gradlew :core:test --tests '*BridgeClientTest*'`
Expected: 编译失败。

- [ ] **Step 3: 实现**
- [ ] **Step 4: 运行，确认测试通过**

Run: `cd android && ./gradlew :core:test`
Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add android/core
git commit -m "feat(android): pinned TLS bridge client with backoff"
```

---

### Task 5: 前台服务、NSD、通知和提醒（`:app`）

**Files:**
- Create: `app/.../data/PairingStore.kt`、`SettingsStore.kt`、`SnapshotCache.kt`
- Create: `app/.../bridge/BridgeRepository.kt`、`NsdLocator.kt`
- Create: `app/.../service/BridgeService.kt`、`BootReceiver.kt`、`Alerts.kt`、`NotificationActionReceiver.kt`
- Modify: `AndroidManifest.xml`、`CritterApp.kt`

**Interfaces:**
- Consumes: Task 2–4 的全部内容。
- Produces（界面层用）：
  - `class BridgeRepository(app: Application)`，`CritterApp` 里只有一个实例：
    - `val state: StateFlow<ConnState>`、`val snapshot: StateFlow<SnapshotBody?>`：没连上时用缓存；
    - `val lastUpdated: StateFlow<Long?>`；
    - `suspend fun answer(requestId: String, payload: AnswerPayload): ServerMessage.Result`；
    - `suspend fun seen(sessionId: String)`、`suspend fun say(sessionId: String, text: String): ServerMessage.Result`；
    - `suspend fun pair(uri: PairingUri): Boolean`；
    - `fun unpair()`；
    - `fun boardVisible(visible: Boolean)`：切换心跳间隔，30 秒或 3 分钟。
  - `PairingStore`：`load(): Pairing?`、`save(Pairing)`、`clear()`。`data class Pairing(host, port, fingerprint, macName, deviceId, token)`。
  - `SettingsStore`：`StateFlow<PhoneSettings>`，以及 `fun update(transform: (PhoneSettings) -> PhoneSettings)`。
    - `PhoneSettings` 的字段：`bridgeEnabled = true`、`vibrateOnWaiting = true`、`notifyDone = false`、`notifyError = false`、`boardBrightness = 0.3f`。
  - `NsdLocator`：`suspend fun find(macName: String, timeoutMs: Long = 5_000): Pair<String, Int>?`。发现期间持有 `MulticastLock`，结束后释放。
  - `BridgeService`：
    - 只有在已配对、并且 `bridgeEnabled` 为真时才运行；
    - 常驻通知写"已连接 · N 个会话"，或者"未连接"；
    - 订阅 `snapshot`，交给 `AlertPlanner`，再执行 `Alerts.apply(plan)`；
    - 用 `ConnectivityManager.NetworkCallback` 在网络变化时让客户端立即重连。
  - `Alerts`：
    - 通知渠道有三个：`critter.status`（常驻，低重要性）、`critter.waiting`（高重要性，会弹出）、`critter.result`（默认重要性）。
    - 每个待答请求一条通知，通知 id 由 requestId 计算。
    - 权限请求的通知带两个动作："允许"和"拒绝"，都设置 `setAuthenticationRequired(true)`（API 31 及以上），点了会把 requestId 和决定广播给 `NotificationActionReceiver`。
    - 提问和计划的通知带一个动作"打开"，跳转到 `AnswerActivity`。
    - 震动用 `VibrationEffect.createOneShot(80, DEFAULT_AMPLITUDE)`。
  - `NotificationActionReceiver`：调用 `repository.answer`，然后撤掉这条通知。如果回执是 `resolved`，改发一条 3 秒后自动消失的通知"已在电脑上处理"。
  - `BootReceiver`：监听 `BOOT_COMPLETED` 和 `MY_PACKAGE_REPLACED`，满足条件时启动服务。
  - 勿扰模式：只有在 `NotificationManager.currentInterruptionFilter == INTERRUPTION_FILTER_ALL` 时才震动；通知本身交给系统按勿扰规则处理（spec §8.7）。
  - 调试入口（只在 debug 构建里）：`app/src/debug/.../DebugPairReceiver.kt`，在 debug 的清单里声明为 exported。
    - 接收 action `local.critter.phone.DEBUG_PAIR`，带字符串 extra `uri`；
    - 收到后调用 `repository.pair(PairingUri.parse(uri))`；
    - 用来在 Task 6 的配对界面完成之前做真机验证。
- **Files 补充**：Create `app/src/debug/kotlin/local/critter/phone/DebugPairReceiver.kt`、`app/src/debug/AndroidManifest.xml`。

- [ ] **Step 1: 实现上面各个类和清单文件**
- [ ] **Step 2: 构建**

Run: `cd android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL，没有新的 lint 错误。

- [ ] **Step 3: 在真机上验证**。前提是计划 1 已完成，Mac 上的 Critter 已经打开手机连接，并且 `debugEnabled` 已打开。

```bash
adb=~/Library/Android/sdk/platform-tools/adb
$adb install -r android/app/build/outputs/apk/debug/app-debug.apk
$adb reverse tcp:47823 tcp:47823
open -g "critter://debug-bridge-pair?out=/tmp/critter-pair.json"
URI=$(python3 -c 'import json;print(json.load(open("/tmp/critter-pair.json"))["uri"])')
# 把 host 换成 127.0.0.1，走 adb reverse（端口以 URI 里的为准）
URI=$(echo "$URI" | sed -E 's#critter-pair://[^:/?]+#critter-pair://127.0.0.1#')
$adb shell am broadcast -a local.critter.phone.DEBUG_PAIR --es uri "'$URI'" -n local.critter.phone/.DebugPairReceiver
```

Expected：
- 前台通知变成"已连接 · N 个会话"，N 等于 Mac 上的会话数；
- 在 Mac 上造一个待答请求（做法同计划 1 Task 9 Step 4），手机会震一下，并弹出一条带"允许""拒绝"的通知；
- 点"允许"以后，Mac 上出现对应的回答文件。

（深链接配对在 Task 6 实现，到时候改用 `adb shell am start -a android.intent.action.VIEW -d "'$URI'"`。）

- [ ] **Step 4: 提交**

```bash
git add android/app
git commit -m "feat(android): foreground bridge service, alerts and notification actions"
```

---

### Task 6: 配对页、首页和设置（`:app`）

**Files:**
- Create: `app/.../ui/MainActivity.kt`（替换掉 Task 1 的空页面）、`ui/pairing/PairingScreen.kt`、`ui/pairing/QrScanner.kt`、`ui/home/HomeScreen.kt`、`ui/settings/SettingsScreen.kt`、`ui/theme/Theme.kt`
- Modify: `AndroidManifest.xml`：给 `MainActivity` 加上 `critter-pair` scheme 的 VIEW intent-filter

**Interfaces:**
- Consumes: Task 5 的 `BridgeRepository`、`PairingStore`、`SettingsStore`。
- **配对页**：
  - 主路径是扫码：用 CameraX 预览，ZXing 的 `QRCodeReader` 解码，`PairingUri.parse` 解析成功后自动发起配对。
  - 备用路径"手动输入"：先用 NSD 列出局域网里的 Mac（`_critter._tcp`），选一台后输入 8 位码。第一次连接时信任看到的证书指纹，并把指纹显示给用户看（spec §6.5 的备用方式）。
  - 通过深链接 `critter-pair://…` 打开时，直接发起配对。
  - 配对过程中显示"请在 Mac 上点允许"。
  - 要申请的权限：
    - 相机：进入扫码时申请；
    - 通知：配对成功后申请（API 33 及以上）；
    - `ACCESS_LOCAL_NETWORK`：在发起任何连接之前申请（API 37 及以上）。被拒绝时显示说明，并提供"去设置"按钮。
- **首页**（竖屏）：
  - 顶部：连接状态（`ConnState` 转成文字）、Mac 名字、两个额度（用 `LimitsText`）；
  - 下面是会话列表，排序用 `SessionOrder.forBoard`。每行有状态色点、名字、来源、`detail`、分支 · 目录、上下文进度条（估算值前面加 "≈"）；
  - 有待答请求的行带橙色边框，点击打开 `AnswerActivity`；
  - 点"做完了"的会话会调用 `repository.seen`；
  - 右上角有"看板"按钮（打开 `BoardActivity`）和设置入口。
- **设置页**：
  - 连接：已配对的 Mac、状态、"重新配对"、"取消配对"；
  - 提醒：`vibrateOnWaiting`、`notifyDone`、`notifyError`；
  - 看板亮度：滑块，范围 0.1–1.0；
  - "忽略电池优化"：调用 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 构建，并在真机上验证**

Run: `make android && make android-install`，然后按 Task 5 Step 3 的深链接配对。

Expected：
- 首页显示 Mac 上的所有会话，分支和上下文都有值；
- 截图存为 `adb exec-out screencap -p > /tmp/critter-home.png`，人工看一遍排版；
- 设置里点"取消配对"，回到配对页。

- [ ] **Step 3: 提交**

```bash
git add android/app
git commit -m "feat(android): pairing, home list and settings"
```

---

### Task 7: 作答卡片（`AnswerActivity`）

**Files:**
- Create: `app/.../ui/answer/AnswerActivity.kt`、`AnswerSheet.kt`、`MarkdownLite.kt`
- Modify: `AndroidManifest.xml`：主题设为半透明，`launchMode="singleTop"`，`excludeFromRecents="true"`

**Interfaces:**
- Consumes: Task 3 的 `AnswerDraft`，Task 5 的 `BridgeRepository.answer`。
- 入口 Intent 的 extra 只有 `requestId`。弹层每次都从 `repository.snapshot` 里按 requestId 查请求。查不到时，显示"已在电脑上处理"，1.5 秒后关闭。
- 布局按草图 3 和 spec §8.5：
  - 标题："<会话名> 想 <摘要>"；
  - 副标题：目录 · 分支 · 来源；
  - **权限**：正文显示 `input.command`、`input.file_path` 或 `input.url`，按这个顺序取第一个存在的；按钮是"拒绝"和"允许"，"拒绝"可以展开一个输入框写理由。
  - **提问**：每道题显示 header 和问题原文；选项按钮显示 label，下面一行小字是 description；单选题点了就提交；多选题勾选后点"提交"；每道题最后都有"自己写一句"。
  - **计划**：用 `MarkdownLite` 渲染计划原文，可以滚动；按钮是"让它改"（展开输入框）和"批准"。
  - 底部小字："电脑上也能答，谁先答算谁的"。
- `MarkdownLite`：只支持 `#`、`##`、`###` 标题，`-` 和 `1.` 列表，行内代码，代码块，粗体，其它内容按纯文本显示。
- 提交流程：先调用 `AnswerDraft.markSubmitted()`，返回 false 就什么都不做；然后调用 `repository.answer`：
  - `ok`：关闭弹层；
  - `resolved`：显示"已在电脑上处理"，然后关闭；
  - 其它失败：显示原因，弹层不关，并允许重试（新建一个 `AnswerDraft`）。
- 处于锁屏时，提交前先调用 `KeyguardManager.requestDismissKeyguard`（spec §8.6）。
- 离线时（`repository.state` 不是 `Connected`），作答按钮全部置灰，顶部显示"未连接，连上后才能作答"（spec §8.3）。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 真机验证**。用计划 1 的 `scripts/dev/e2e-phone.sh` 起一个真实的 haiku 会话，或者照它的做法手动起一个，依次触发下面三种情况，每一种都在手机上作答，并截图存档：
  - 权限请求：在手机上点允许，Mac 终端里的审批框应该自动关闭；
  - 单选题：手机上选一个，终端里出现 `→ <label>`；
  - 计划：先"让它改"，再"批准"。

Expected: 三种情况都成功，截图存到 `/tmp/critter-answer-*.png`。

- [ ] **Step 3: 提交**

```bash
git add android/app
git commit -m "feat(android): answer sheet for permissions, questions and plans"
```

---

### Task 8: 横屏专业看板（`BoardActivity`）

**Files:**
- Create: `app/.../ui/board/BoardActivity.kt`、`ProBoard.kt`、`BoardChrome.kt`（时钟、防烧屏挪动、亮度）
- Modify: `AndroidManifest.xml`：`screenOrientation="sensorLandscape"`，主题为全屏黑底

**Interfaces:**
- Consumes: `BridgeRepository`、`LimitsText`、`SessionOrder`、`SettingsStore.boardBrightness`。
- 布局按草图 board-modes 里的"专业看板"：
  - 左栏宽 178dp：时钟，每分钟对齐整分刷新一次；两张额度卡，每张有百分比、进度条、重置文案；
  - 右边两列会话卡片，内容有状态色块、在做什么、分支 · 目录 · 来源、上下文进度条和用量；
  - 有待答请求的卡片带橙色边框。权限请求可以直接点"允许"或"拒绝"，提问和计划打开 `AnswerActivity`。
  - 数据过期时，在额度卡下面显示 `LimitsText.staleness`；没连上时，左上角显示"未连接 · x 分钟前"。
- 窗口设置：
  - 加 `FLAG_KEEP_SCREEN_ON`；
  - `screenBrightness = settings.boardBrightness`；
  - 沉浸式全屏；
  - 申请低刷新率：API 35 及以上用 `window.decorView.setRequestedFrameRate(View.REQUESTED_FRAME_RATE_CATEGORY_LOW)`；API 30 及以上用 `window.attributes.preferredRefreshRate = 30f`，或者从 `display.supportedModes` 里选一个最低刷新率的模式。
- 防烧屏：每 3 分钟给整个内容区一个 ±4dp 的随机偏移（跳过去，不做动画）。15 分钟内没有触摸、也没有状态变化时，亮度再降为 `boardBrightness × 0.6`；一碰屏幕就恢复。
- 生命周期：`onStart` 时调用 `repository.boardVisible(true)`，`onStop` 时调用 `boardVisible(false)`。
- 计划 2 只做专业看板。Critter 模式和自动打开 / 退出放在计划 3。

- [ ] **Step 1: 实现**
- [ ] **Step 2: 真机验证**

Run: 从首页点"看板"，把手机横过来；截图 `adb exec-out screencap -p > /tmp/critter-board.png`。

Expected：
- 排版和草图一致；
- 等 3 分钟后再截一张，整体位置有偏移；
- `adb shell dumpsys window | grep -i keep` 显示 `KEEP_SCREEN_ON`。

- [ ] **Step 3: 提交**

```bash
git add android/app
git commit -m "feat(android): landscape pro dashboard"
```

---

### Task 9: 真机走查，补 README

**Files:**
- Modify: `README.md`，新增"手机 App（安卓）"一节，内容有：构建和安装（`make android`、`make android-install`）、配对、各项权限的用途、vivo 机型需要打开"后台弹出界面"和"允许后台高耗电"、已知限制。

- [ ] **Step 1: 走查真机清单**。逐项打勾，结果写进本任务的报告：
  - 用二维码配对：Mac 设置里显示二维码，手机扫码，在 Mac 上点"允许"；
  - 手机断开 Wi-Fi 后再连上，App 自动重连，常驻通知的状态跟着变；
  - 在 Mac 设置里撤销这台设备，手机进入"需要重新配对"，并且不再反复重试（可以在 `adb logcat` 里确认）；
  - 锁屏状态下来了一个权限请求：手机震一下，弹出通知；在通知上点"允许"时要求先解锁；解锁后作答成功；
  - 熄屏 10 分钟后再亮屏，连接仍在。如果被 vivo 冻结了，就把需要打开的开关写进 README。
- [ ] **Step 2: 更新 README，提交**

```bash
git add README.md
git commit -m "docs: build, pair and use the Android app"
```
