# Critter iOS 版待办

iOS 计划 1（`docs/superpowers/plans/2026-10-24-critter-ios-1-skeleton.md`）做完时，各轮审查留下、判定放到后面计划处理的事项。按要落到的计划分组，写后面的计划时逐条认领。

## 计划 2：宠物与看板

- `BoardTrigger` 移植成 Swift；`SpriteAtlas`、`CritterSpriteLayer`、`MotionClock` 移进 `CritterKit`（计划 1 推迟的部分）。

## iOS 推送与扩展计划（App Group）

- 存储搬到 App Group 容器和共享钥匙串。这一步在装真机之前完成，所以不需要迁移旧数据。
- 快照缓存每来一份就写一次。改成最多约 30 秒写一次，退到后台时补写（Android 是每 30 秒最多一次）。
- 重新配对时删除旧缓存是异步的：刚配对完就被杀掉，下次启动可能短暂显示上一台 Mac 的快照；排队中的写入和删除交错时，缓存可能空到下一份快照。
- 钥匙串写 token 失败只记日志：旧 token 先删、新 token 没写进去，配对记录却照写，下次启动显示"尚未配对"。改成先写新 token，成功后再写配对记录。
- `BridgeStore.pair` 本身没有防重入，现在靠界面挡着。通知入口加进来以后，要在 store 里挡。
- **真的往 APNs 发一条**（计划 3 只用假的传输层测过）：用户给 `.p8`、在开发者账号里给 App ID 开推送后，从 Mac 设置里"发送测试通知"。同时验证这台 Mac 访问 `api.sandbox.push.apple.com` 要不要走代理（spec §13.6）：Mac 用 `URLSession`，只认系统的代理设置，不认命令行用的 127.0.0.1:1082。
- **实时活动的推送 token 能不能在后台送回 Mac**（spec §13.1）：push-to-start 启动后，App 在后台被唤醒时能不能连上 Mac，把 `activityToken` 用推送登记送过去。不行就改用 iOS 18 的广播频道，或者只在前台启动。Mac 这边现在的做法：启动一次后等 token，拿不到就不再启动，活动停在旧内容（15 分钟后变灰），直到 7.5 小时或会话全部结束 5 分钟后。
- Mac 端的联机检查（计划 3 推迟到合回 `main` 之后，因为要运行这条线构建的 Critter.app，会替换用户正在用的那个）：用 `critter-bridge-client` 配一台临时设备，`push --token <64 个 0> --done` 后 `~/.critter/bridge/devices.json` 里有这份登记、权限仍是 0600，设置里这台设备后面有"推送"标签；`push --clear` 后登记消失；没有 `.p8` 时设置显示"未配置"，`~/.critter/app.json` 的 `pushReachable` 为 false；`scripts/dev/e2e-phone.sh` 照常通过；最后撤销这台临时设备。
- App 的 `ActivityAttributes` 类型要叫 `CritterActivity`：Mac 的 push-to-start 写的是 `LiveActivityContent.attributesName`。
- App 的 bundle id 定下来后，核对 Mac 设置里的默认值 `com.braynlabs.critter`。Mac 只给登记的 `bundleId` 和设置一致的 iPhone 推送（不一致时设置里写"登记了的 iPhone 不是这个 bundle id 的 App"）。
- 用户划掉实时活动后，Mac 分不清"划掉"和"结束"，有会话时最多每 10 分钟重新启动一次。真机上嫌烦的话，加一个开关，或者只在有会话开始等你确认时才重开。
- Codex 控制通道在 Mac 重启后才列出的待批请求，晚于"只记下现状"的第一份快照到达，可能被当成新请求推一次。
- `push` 帧解码失败（比如不认识的 `environment`）时 Mac 不回 `result`，手机会以为 Mac 版本太旧。只在两边版本不一致时出现。
- `BridgeClient` 的 init 文档还写着每个请求超时都会断开连接，`registerPush` 例外，改掉。
- 测试 `devicesFileStaysPrivate` 里 `setActivity` 那一步是空操作（登记里没有实时活动那一部分），补上实时活动再测。

## 装到真机的计划

- 扫码器 `startScanning()` 失败时没有任何提示（`try?`），相机开着却不识别。
- 等 Mac 点允许的最多 120 秒里，屏幕可能自动锁定，配对因此失败。`.awaitingApproval` 期间设 `isIdleTimerDisabled`。
- 用户拒绝了本地网络权限时，App 一直显示"未连接，正在重试"，没有任何提示。
- 6 秒连接时限可能把用户第一次回答本地网络权限弹窗的时间也算进去，第一次配对可能报"连不上"、要再试一次。真机上验证。
- 证书固定、连接打开、关闭的判断没有不依赖真机的测试，只有联机测试覆盖。装真机前补上。
- Bonjour 查找每次固定等 3 秒；查找窗口里进入 `.waiting` 的服务不会重试。

## 前端优化轮

- 配对确认框在大字号下可能超出屏幕（`fixedSize`，没有滚动）。
- 手动配对的证书探测任务没有被跟踪：切去扫码后，晚到的失败可能把"连不上这台 Mac…"显示在别的页面上。
- 配对进行中收到的链接会被静默丢掉；在失败页上，"不在局域网"的提示看不到。
- 发一句和停止当前回合共用"正在发送…"状态。
- 发一句超长时发送按钮变灰但没有说明（Android 把输入框限制在 4000 字）。
- 首页那一行的作答还在途中时打开卡片，卡片按钮没有反应；回答落地后卡片写"已在电脑上处理"，其实是手机答的。
- "已在电脑上处理"、Mac 名字的兜底、连接状态颜色在几个视图里各写了一份，视觉轮重写这些视图时合并。
