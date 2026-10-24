# Critter 手机端 · iOS 计划 5：装到真机 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iOS 版装到用户的 iPhone 上，用真推送把 spec §12 的真机检查点走完。

分两部分：
- **A 部分**不需要用户动手：
  - 先做完装真机之前必须修的事：计划 4 最终审查留下的两条、计划 1 留下的几条连接问题；
  - 给 Makefile 加真机的构建和安装命令。
- **B 部分**每一步都要用户在场：
  - 在开发者账号里给 App ID 打开能力；
  - 提供 `.p8`；
  - 连上手机，在手机上点按，把检查点一项项过。

**Architecture:** 同计划 1–4。A 部分的逻辑仍放 `CritterClient` / `CritterKit` / `CritterCore`，在 Mac 上 `swift test`。B 部分不写新功能，只修真机上暴露的问题（每个问题按 systematic-debugging 的做法先查原因再修）。

**Tech Stack:** 同计划 4，另外用到 `xcrun devicectl`（装 App、读设备日志）。

**Spec:** `docs/superpowers/specs/2026-10-23-critter-ios-design.md` §6.8（Makefile）、§12（真机检查点）、§13（待实测）。真机上要验证的清单在 `docs/critter-ios-backlog.md` 的"装到真机的计划"一节，B 部分照它逐条过。

## Global Constraints

- 计划 1–4 的全局约束继续有效。
- **任何会在用户的 Apple 开发者账号里登记、修改东西的操作，都要先得到用户在当次对话里的同意**，包括：
  - 给 App ID 打开能力；
  - 登记 App Group；
  - 生成描述文件；
  - 用 `-allowProvisioningUpdates` 构建。

  不能因为"之前同意过别的"就做。
- `ios/Config/Base.xcconfig` 的 `CODE_SIGN_STYLE[sdk=iphoneos*] = Manual` 保持不动，除非用户在 B 部分选了"让 Xcode 自动处理"。那时只在那一次构建命令里覆盖，不改文件。
- 装到手机、在手机上点按，都由用户来做；不用任何驱动用户手机界面的办法。
- `.p8` 只放在 `~/.critter/bridge/apns/`（0600），不进仓库，不打日志，不出这台 Mac。
- GitHub 等全部做完再推送（用户 2026-10-24 定）。

## A 部分：装真机前（不需要用户）

### Task 1: 推送默认只能"打开"，扩展解开后才给按钮

**参考：** 计划 4 最终修复轮的残留裁决（`.superpowers/sdd/2026-10-24-critter-ios-4-ios-push/progress.md`，"Ruling (residual → plan 5 FIRST item"）。

**改法：**
- Mac 组推送时，`aps.category` 写只能打开的 `sealed` 类别，真正的类别只放在自定义键 `k` 里（`k` 本来就在加密的关联数据里）。
- 通知服务扩展解密成功后，把 `categoryIdentifier` 换成 `k`；解不开、或者扩展根本没运行，就停在 `sealed`，不会出现「允许」「拒绝」。
- 同步修改：
  - `PushPayload.alert`；
  - `PushOpening`（解不开的判断）；
  - 协议文档的例子和说明；
  - Swift 的文档例子测试；
  - Android 的文档测试（它跳过 iOS 推送这一节，确认仍通过即可）。

**测试：**
- `theMacSendsTheOpenOnlyCategory`；
- `aDecryptedPushGetsItsRealCategory`；
- `anUndecryptedPushStaysOpenOnly`。

### Task 2: 换到同一台 Mac 时不误报；提示在配对的每一页都能看到

**参考：** 同上，"Ruling (residual → plan 5 before device use)" 和 "notice only on the scanner page"。

**改法：**
- 新配对的证书指纹和旧配对相同，说明是同一台 Mac：不提示去撤销这台手机，也不换推送密钥。Mac 收到新登记后，会按计划 3 的 FI2 规则清掉旧记录上同一个 token 的登记。
- "旧 Mac 可能还在推"的提示，在手动输入、等待批准、失败页也显示。

**测试：** `pairingAgainToTheSameMacSaysNothing`。

### Task 3: 计划 1 留下的连接问题（能不靠真机做的）

`docs/critter-ios-backlog.md`"装到真机的计划 › 计划 1 留下的"：
- 扫码器 `startScanning()` 失败时给出提示，不再静默。
- 等 Mac 点允许期间（`.awaitingApproval`）屏幕常亮，离开就还原。
- 本地网络权限被拒时给出提示，并带「去设置」：
  - `NWBrowser` 或连接报 `kDNSServiceErr_PolicyDenied`（-65570），或者 `NWError` 的同类错误，就判断为被拒；
  - 判断逻辑抽成纯函数，测试。
- 证书固定、连接打开、关闭的判断，补上不依赖真机的测试（用本机回环和自签证书，或注入的 `BridgeSocket`）。
- Bonjour 查找里进入 `.waiting` 的服务要重试一次。

做完的条目从台账删掉。

### Task 4: Makefile 的真机命令（只写，不运行）

spec §6.8：
- `make ios`：真机 Release 构建。
  - 默认按 `CODE_SIGN_STYLE[sdk=iphoneos*] = Manual` 签名，描述文件不齐时失败，并打印"先在 B 部分把能力和描述文件备好"；
  - 只有设了 `ALLOW_PROVISIONING=1` 才加 `-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic`，并在开头打印"这会在开发者账号里登记 App ID 能力和 App Group"。
- `make ios-install`：用 `xcrun devicectl list devices` 找到唯一连着的 iPhone，用 `xcrun devicectl device install app` 装上；有多台或没有，就报错退出。
- `make ios-test`：在模拟器上构建一遍，并跑 `swift test --filter 'CritterClientTests|CritterKitTests'`。iOS target 没有单独的测试 target，纯逻辑测试都在包里。
- README 写清这三个命令和 `ALLOW_PROVISIONING` 的含义。

这一任务不运行 `make ios` 和 `make ios-install`。

## B 部分：真机检查（每一步都要用户在场）

开始前停下来问用户，拿到答案再往下走：
1. **手机**：iPhone 型号和 iOS 版本（spec §13.5）；手机已打开开发者模式，用线或同一 Wi‑Fi 连上这台 Mac。
2. **能力和描述文件**：二选一：
   - 用户自己在开发者网站给 `com.braynlabs.critter`、`.notify`、`.widgets` 打开能力（清单见台账"描述文件要带齐这些能力"），用 Xcode 下载描述文件；
   - 或者同意这一次用 `ALLOW_PROVISIONING=1 make ios`，让 Xcode 自动登记。
3. **`.p8`**：用另一个 App 已经在用的那一把，还是新建一把（新建的只能下载一次）。拿到后由用户在 Mac 的 Critter 设置里"选择 .p8 文件…"导入，填 Team ID。

### Task 5: 构建、安装、第一次配对

- `make ios`（或用户选的那种），然后 `make ios-install`。
- 用户在手机上打开 Critter，走首次引导：
  - 配对（扫 Mac 上的二维码）；
  - 本地网络弹窗（注意 6 秒连接时限会不会算进弹窗的时间）；
  - 通知权限；
  - 实时活动说明；
  - 看板自动打开（建快捷指令）。
- 在 Mac 的设置里看到这台手机，带"推送"标签；手机设置里显示 Mac 的状态句。
- 有问题时，用 `xcrun devicectl device info …` 或用户提供的手机截图、Mac 上 Console 的设备日志查原因。

### Task 6: 推送和通知

照台账"计划 4 留下的"逐条过，每条记下结果：
- **真推送**：Mac 设置里"发送测试通知"能到手机。不通时查代理（spec §13.6）：Mac 发推送走系统代理设置，不认命令行的 127.0.0.1:1082。
- **权限请求的通知**：
  - 锁屏、解锁前后各看一次显示的内容；
  - 面容 ID 之后点「允许」，终端里的命令执行；
  - 「拒绝并写理由」；
  - Codex 的请求只有两个按钮。
- **提问和计划**：从通知打开卡片作答。
- **点按钮作答**：
  - App 被划掉时点「允许」，量耗时（spec §13.3）；
  - 离开 Wi‑Fi 时点，显示"没送到…"、按钮还在，回到 Wi‑Fi 再点一次能成。
- **撤回**：在 Mac 上答掉以后，手机上的通知消失（后台推送，或者回到前台时对账）。
- **专注模式**：等你确认的通知能穿过（spec §13.4）。
- **取消配对**：取消后不再收到推送。

### Task 7: 实时活动、待机、看板、触摸

- **实时活动**：
  - 启动、更新、结束；
  - 灵动岛的紧凑、最小、展开；
  - 锁屏；
  - 待机模式；
  - 安静 15 分钟不变灰（每 12 分钟有刷新）；
  - push-to-start 后的 token 能不能送回 Mac（spec §13.1）；
  - 更新预算（§13.2）。
- **看板**：快捷指令自动化加横放打开看板，拔电和竖起来退出；亮度和常亮的还原；静音开关。
- **触摸和键盘**：
  - 宠物的按下、拎起、拖、摩擦；
  - 弹层下拉关闭；
  - 左边缘右滑返回；
  - 输入框和键盘；
  - 亮度滑块。
- **扫码页、深色和着色图标、减少动态效果。**

### Task 8: 收尾

- 真机上发现并修好的问题，每条一个提交、带测试。
- 台账：做完的删掉，没做完的写清原因和下一步。
- README 的 iOS 一节写上"已在 <机型> / iOS <版本> 上验证"。
- 走 superpowers:finishing-a-development-branch：这时全部做完，按用户的决定把 main 推到 GitHub（推送前再确认一次）。
