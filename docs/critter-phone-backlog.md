# Critter 手机端待办

2026-10-19 真机走查之后整理。第一部分是用户定的、留给下一轮单独的前端优化；第三部分是各轮代码审查留下、当时判为次要而没修的问题，按模块列出（只写文件名，不写行号）。

## 一、前端优化轮（用户定）

1. **应用图标。** `AndroidManifest.xml` 没有声明 `android:icon`，桌面和安装界面显示的是安卓默认的小机器人。需要一个 Critter 的自适应图标。（Claude 的建议：图标是产品标识，按改名时的约定不用 Clawd 的形象，用原创形象之一。）
2. **看板打开时自动隐藏悬浮球。** 看板（专业或宠物模式）在前台时悬浮球收起，看板关闭后恢复。
3. **看板宠物模式里拖动宠物。** 单只宠物可以随意拖动，其他宠物不跟着动；松手后它自己走回原来的位置（走回去，不是瞬移）。

## 二、真机走查记录

2026-10-19，vivo V2121A（Android 13），正式签名版，局域网连 Mac。

| 步骤 | 结果 |
|---|---|
| 1. vivo 保活开关 | 通过（电池优化白名单、待机分组 EXEMPT、前台服务常驻） |
| 2. 悬浮球 | 通过（出现、拖动、吸边；窗口约 249×300，不拦截外部触摸） |
| 3. 看板充电横放自动打开、竖起和拔电退出、手动退出后不再自动打开、锁屏上显示 | 通过 |
| 4. 拔线锁屏后收到权限请求通知，点「允许」后电脑执行 | 通过 |
| 5. 回答 AskUserQuestion | 通过 |
| 6. 批准计划 | 通过 |
| 7. 发一句 | 通过 |
| 8. 减少动态效果、切换形象 | 通过 |

走查中发现并修复：

- `02332c5` 扫码页只释放自己绑定的相机用例。原来在首次引导的配对步骤按返回，底下首页扫码页的相机会被正在关闭的引导页一起解绑，预览全黑。
- `4f91715` 首次引导在配对前被返回取消时直接退出应用，不再露出一个一模一样的扫码页。

## 三、遗留的次要问题

部分条目可能已在后来的修复波次里顺带解决，动手前先核对。

### Android

- 通知上点「允许」：连接显示为已连上但实际已断时重试较弱，最坏约 36 秒才提示失败。
- 用 Home 键离开看板后，看板一直活到拔电，期间不会再次自动打开。
- Android 12+ 的通知跳板限制可能拦住从锁屏通知按钮打开回答卡片（会提示，通知保留，点通知正文可进入）。
- `ensureConnected` 在正在连接时也会触发 `reconnectNow`；`reconnectNow()` 在连接中会留下过期的唤醒标记。
- 悬浮堆可见时看过的提醒，之后不会再发通知。
- 看板改的 30 秒心跳间隔要到下一次重连才生效。
- 多个卡片窗口共用 `taskAffinity=""`，可能落在同一个任务里。
- `BridgeClient`：`stop()` 后马上 `start()` 有竞争（旧任务的 finally 会清掉新 socket），`stop()` 不重置离线时间和退避；`pingIntervalMs` 不是 `@Volatile`；旧的 OkHttpClient 连接池没有关闭。
- `pair()` 对被拒绝、证书不符、超时一律返回 null，界面分不清是码错了还是证书不对。
- `startClient()` 没有同步，配对成功和服务启动可能同时各起一个客户端。
- `CritterApp.onCreate`、配对和取消配对在主线程读写磁盘；`BoardSounds.prepare` 在主线程。
- 看板的分钟时钟和防烧屏循环不跟随生命周期，停止后还在跑。
- 请求通知在锁屏上显示命令内容，应改成 `VISIBILITY_PRIVATE` 加公开版本。
- `BoardActivity.answerPermission` 用 `lifecycleScope`，离开看板会取消等待回复。
- 会话行副标题顺序是「分支 · 目录 · 来源」，设计稿是「目录 · 分支 · 来源」。
- `injectSnapshotForDebug` 在正式的 `BridgeRepository` 上是公开的；收到自定义形象会把所有角色重建一次；点会话可能根据离线缓存的快照打开卡片（`AnswerActivity` 会再核对）。
- 看板的静止判断只看一次采样；已配对面板切换有视觉跳动；后台启动被系统拦下时没有提示（README 里有说明）。
- 缺测试：`reconnectNow`、`setPingInterval`、`stop`、形象回复；`AlertPlanner` 新会话情形；`PairingUri` 里的 `+`。
- 核心库：`SkinManifest` 是可变数据类，被多个角色共享；`intOrNull` 不接受 `3.0`（Swift 版接受，会退回 clawd）；`jsRound` 溢出时饱和而 Swift 会崩（校验范围内到不了）；核心测试类路径加了整个 `Skins/` 目录。

### Mac

- 卸载时如果包装脚本还在但 hook 已经没了，会停下来并打印手动步骤。
- 答案已被取走后再收到第二个答案，会短暂返回 ok，之后被清理。
- 状态栏命令的输出经过 `String(decoding:)`，非法 UTF-8 字节会变成 U+FFFD；`settings.json` 也是有损解码。
- `atomicWrite` 在 `setAttributes` 抛错时留下临时文件；`settings.json` 备份用默认 0644 权限（里面可能有密钥），应沿用原权限或 0600。
- 安装对改过路径的 hook 不幂等（会嵌套包装）；`uninstall.sh` 写死 `$HOME/.critter/bin`，而安装支持 `$CRITTER_HOME`。
- 用量全为 0 的一行会得出 0 token，而不是取更早的一轮（`ContextUsage`）。
- 问题答案先 trim 再判长度但输出原值，两边加空格可绕过 4000 字限制；计划退回的意见不 trim 而拒绝会 trim（`AskDecision`）。
- event hook 每个事件都重新解析 stdin、列出 pending 目录并计算哈希，即使手机功能没开；应只对相关事件解析，pending 为空时直接返回。
- 目录只在创建时 chmod 0700；inbox token 在 chmod 前短暂是 0644（`PendingRequest`、`Inbox`）。
- `DeviceRegistry.load` 把损坏的设备文件当成空列表，下一次添加会覆盖它；未知设备 id 提前返回，时间差能看出 id 是否存在。
- 「发一句」的长度 Mac 按字符数、手机按 UTF-16 计，且不 trim 就转发；`ResultReason.expired` 定义了但从不产生。
- 配对「允许」来得太晚时可能批准另一台手机（客户端编号每次 `BridgeServer` 重启从头算）。
- `BridgeController` 有 468 行，混了生命周期、快照组装和缓存、配对和 `getifaddrs`，可拆出 SnapshotAssembler 和 LANAddress；SHA-256 十六进制、`inet_ntop`、版本字符串的代码有重复；开发用客户端从两个线程退出。
- 缺测试或测试偏弱：`matchKeyIgnoresKeyOrder`、`statusLineRejectsBadSessionId`、超长输入截断、`binaryAskWithoutAppExitsFast` 的 1 秒时限在并行测试下不稳；没有测试把协议文档里的示例和解码器对上。
