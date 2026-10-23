# Critter 手机端（Android）— 设计文档

日期：2026-10-18
状态：已通过开发者视角审阅，用户已确认（2026-10-18）

> **2026-10-23 更新：**Clawd 形象已从项目中移除（它只属于 Claude Code，而 Critter 现在也支持 Codex，以后还会接入更多 Agent）。默认形象和皮肤出错时的内置兜底都改为小芽 Sprig；下文提到 Clawd 的地方是当时的记录。

> 记号：**【用户定】** 是用户明确做的决定；**【Claude 定】** 是 Claude 代为做的决定，用户还没有逐条确认，实现时可以调整，但要先说明；**【实测】** 是 2026-10-18 在本机 Claude Code 2.1.302 上实验得到的结果；没有标记的是调研得到的事实，或者双方都已认可的内容。
>
> 草图：`docs/superpowers/specs/2026-10-18-critter-android-mockups.html`，用浏览器打开。里面的小人是从 `Skins/*/manifest.json` 真实渲染出来的。

---

## 1. 意图

用户同时开着好几个 Claude Code 会话，桌面上的 Critter 能告诉他每个会话的状态。但人不在电脑前，或者在用手机时，就看不到了。另外，碰到 Claude 卡在等确认、等回答的时候，他想直接在手机上处理掉，不必回到电脑前。

所以要做一个 Android App，通过**局域网**连接工作电脑上的 Critter【用户定】，提供三样东西：

1. **悬浮球**：一个 Critter 悬浮在其他 App 上面，像桌面版那样平时合并成一堆，点一下展开，显示每只宠物和它的信息【用户定】。
2. **纯看板模式**：手机横放、正在充电时自动打开，屏幕保持常亮【用户定】。有两种模式可以手动切换【用户定】：
   - 放大的、可互动的 **Critter 模式**；
   - **专业看板模式**。
3. **在手机上作答**：需要你时（等确认、Claude 在提问、要批准计划），可以直接在 App 里回答【用户定：能做到就做；实测能做到，见 §4.1】。

看板上要能看到：所有正在进行的会话、5 小时额度、7 天额度、每个会话的上下文用量、工作目录和 git 分支【用户定】。

手机**只连局域网里的工作电脑，不直接连 Claude 的服务器**【用户定】。

整体要**尽量低功耗**，纯看板模式下尤其要降低功耗和发热【用户定】。

## 2. 目标 / 非目标 / 反目标

### 目标（第一版）
1. 手机与 Mac 上的 Critter.app 配对后，实时显示所有会话。会话列表和桌面版一致，包括同一套形象、同一个"随机宠物"分配。
2. 每个会话显示：状态、正在做什么（气泡）、名字、来源（终端 / VS Code / Desktop）、工作目录、git 分支、模型、上下文用量。全局显示 5 小时和 7 天额度，以及各自的重置时间。
3. 悬浮球。收起时显示"一堆"，点一下沿屏幕边竖排展开【用户定，草图 B】。
4. 纯看板：横放加充电时自动打开，拔电或竖起来时自动退出。Critter 模式和专业看板可以手动切换，屏幕常亮、纯黑、低亮度、低帧率。
5. 作答。四种情况：
   - 权限审批（允许 / 拒绝，拒绝时可以附一句理由）；
   - AskUserQuestion（点选项，或者自己写一句）；
   - 批准计划；
   - 让 Claude 修改计划（附修改意见）。

   电脑和手机同时可以答，谁先答就算谁的。
6. 提醒：有会话变成"需要你"时，手机短震一下；如果悬浮球看不见，就发一条系统通知。权限审批可以直接在通知上点允许或拒绝。
7. "发一句"：给空闲、做完或卡住的会话发一句话【Claude 定，放在最后做；见 §6.4】。

### 非目标（第一版不做）
- 离开局域网后的远程访问，比如中转服务器或公网穿透。用户已经在用 Claude 自带的 Remote Control，那条路走的是 Anthropic 服务器，不在本项目范围内。
- iOS 版、上架应用商店、连接多台电脑。
- 在手机上开新会话、看完整对话记录或代码 diff。
- MCP elicitation 对话框、项目信任对话框这类其它弹窗的作答。
- 系统屏保（DreamService）形式的看板，以后可以加，见 §8.6。

### 反目标（做出来但这样就算失败）
- **耗电、发热。** 用户最在意的是"尽量低功耗"。代码层面必须做到的省电要求见 §9（不做实测验收）。
- **干扰 Claude Code 会话。** 下面任何一种情况发生，Claude Code 的行为都必须和现在完全一样：手机没连上、Critter.app 没运行、手机端功能整个关着。尤其是：
  - 能等手机回复的 hook 不能让终端里的对话框晚出现；
  - 不能让会话卡住；
  - 不能输出任何不该输出的内容。
- **局域网里的其他人能看到会话内容，或者替用户点"允许"。**
- **用户现有的状态栏坏了，或者显示的样子变了。**
- **点到过期的卡片，批准了不该批准的东西。** 每个回答都必须精确对应一个仍在等待的请求。

## 3. 约束

- **桌面端**：沿用现有的 Swift / SwiftPM 工程和全部约束（见 `2026-10-17-critter-desktop-pet-design.md` 的 §2、§3、§9），包括：
  - hook 必须快、永远 exit 0、吞掉一切错误；
  - 主线程只做界面；
  - 坏数据跳过，不能崩溃；
  - 状态文件是跨平台契约，只能向后兼容地加字段。
  - 不引入第三方依赖。
- **手机端**：原生 Kotlin【Claude 定，理由和桌面端选 Swift 一样：省电、占用小】。
  - 代码放在本仓库的 `android/` 目录【Claude 定】。
  - 只自己侧载安装，不上架应用商店。
- **工具链（本机已装好并验证过）**：
  - AGP 9.4.1、Gradle 9.8.1（wrapper）、JDK 21；
  - compileSdk / targetSdk 37，minSdk 29【Claude 定：29 是第一个有 `foregroundServiceType` 的版本】。
  - 本机直连 dl.google.com 和 services.gradle.org 都不通，要走系统代理 `127.0.0.1:1082`。代理已经写在 `~/.gradle/gradle.properties` 里，不放进仓库。
- **最终用哪台手机未定**【用户定：暂时没法确定】。所以要按通用 Android 设计，并且照顾到主流国产系统：小米 HyperOS、OPPO ColorOS、vivo OriginOS、华为/荣耀、三星 One UI。
- **开发用真机**【用户定：有真机，已经通过 USB 连上这台 Mac，开了开发者模式】：
  - 型号是 vivo V2121A，系统版本 PD2121_A_6.18.8（vivo 系统 13.5），Android 13（API 33），屏幕 1080×2400，480 dpi。
  - 从 §4.3 可以推出三点：
    - Android 17 的本地网络权限在这台手机上测不到，要用 API 37 模拟器补测；
    - `setRequestedFrameRate`（API 35）用不了，要用 `Surface.setFrameRate`（API 30+）；
    - vivo 的"后台弹出界面"和"允许高耗电"这两项保活引导，可以在这台手机上直接验证。
- **Claude Code 2.1.302。** 依赖的接口是：
  - hooks 的 `PermissionRequest` 决策；
  - `PreToolUse`；
  - 状态栏输入 JSON；
  - 会话收件箱 socket。

  前三个是官方文档里有的。收件箱 socket 的线格式没有正式文档，所以缺失或格式变了时都要能优雅降级。

## 4. 已确认的事实

### 4.1 在手机上作答【实测】

实验方法：用 tmux 驱动一个真实的交互式会话（`--model haiku --permission-mode default`），通过 `--settings` 只给这个会话挂测试用的 hook。hook 先记录收到的输入，再等一个"手机回复文件"出现。

| # | 场景 | 结果 |
|---|---|---|
| 1 | `PermissionRequest` hook 在等回复时 | 终端的审批框**照常同时弹出**，两边一起等 |
| 2 | hook 输出 `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` | 终端审批框自动关闭，命令执行，界面显示 "Allowed by PermissionRequest hook" |
| 3 | 先在终端里点"允许" | 命令正常执行；**还在等的 hook 进程不会被结束**，会一直挂到它自己的超时 |
| 4 | `PreToolUse` hook 在 AskUserQuestion 上等待 | 终端只显示 "running PreToolUse hooks…"，**问题不会弹出**（所以不能用这条路） |
| 5 | `PreToolUse` 放行后 | 问题照常弹出，**同时触发 `PermissionRequest`（tool_name = AskUserQuestion）** |
| 6 | 在 5 的基础上，`PermissionRequest` 输出 `behavior: allow`，`updatedInput` = 原样的 `questions` 加上 `answers: {"<问题原文>": "<选项 label>"}` | 终端里的问题自动关闭，显示 "→ Pear"，Claude 拿到了答案 |
| 7 | ExitPlanMode 也会触发 `PermissionRequest`，输入里有完整的 `plan` 文本 | 输出 `deny` + `message`：Claude 照着修改意见改了计划、重新提交；输出 `allow` + `updatedInput` = 原样输入：批准，退出计划模式，回到进计划模式前的那个模式 |
| 8 | 在终端按 Esc 或选"No"拒绝权限 | **不触发任何 hook 事件**，只在会话记录里写一行 `[Request interrupted by user for tool use]` |
| 9 | 在终端里回答 AskUserQuestion | 触发 `PostToolUse`（tool_name = AskUserQuestion），然后是 `Stop` |
| 10 | 往会话收件箱 socket（`CLAUDE_CODE_MESSAGING_SOCKET`）写一行 `{"type":"auth","token":"<CLAUDE_CODE_MESSAGING_TOKEN>"}`，再写一行 `{"type":"user","message":{"role":"user","content":"…"}}` | 空闲会话立即开始新的一轮，Claude 照做了。但它被标成"另一个会话发来的消息"，Claude 会附带提醒：这种消息不能当作用户的批准、不能用来改配置。socket 不返回任何确认 |

另外：
- hook 的环境变量里有 `CLAUDE_CODE_MESSAGING_SOCKET` 和 `CLAUDE_CODE_MESSAGING_TOKEN`，`SessionStart` 时就已经有了。
- `PermissionRequest` 的输入里没有 `tool_use_id`，这是文档写的，实测也一样。
- hooks 默认超时 600 秒。文档说超时的 hook 会被取消、它的输出会被丢弃。

### 4.2 数据从哪来
- **5 小时 / 7 天额度**：只有状态栏输入 JSON 里有，字段是 `rate_limits.five_hour.used_percentage`、`rate_limits.five_hour.resets_at`（Unix 秒），7 天的是 `seven_day.*`。
  - 只有 Pro / Max 订阅才有，而且要等第一次 API 响应之后才会出现。
  - 某个窗口过了重置时间就会消失。
  - 没有官方的本地文件或命令能读到这些数据。用户现有的状态栏脚本 `~/.claude/statusline-command.sh` 已经在读这些字段。
- **上下文**：状态栏输入里有 `context_window.used_percentage`、`context_window_size`（20 万或 100 万）、`current_usage`。
  - 状态栏只在终端 CLI 里运行，VS Code 和 Desktop 里的会话没有。
  - 兜底办法：取会话记录里最后一条带 `usage` 的 assistant 消息，用 `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` 算出已用量。窗口大小按模型推断，所以是近似值。
- **状态栏什么时候运行**：会话开始时、每条 assistant 消息之后、`/compact` 之后、额度重置时等等，有 300 ms 防抖。空闲时不运行。
  - 插件**不能**自带状态栏，只能写在用户设置里。
- **git 分支**：状态栏输入里没有，要自己从工作目录的 `.git/HEAD` 读。
- **其余字段**（状态、气泡、工作目录、来源、名字）：现有的 `PetSession` 已经有了。
- **每个会话分到哪个形象**：只存在 `PetController` 的内存里，所以要由 Mac 推给手机。

### 4.3 Android 平台（调研，引用的是 developer.android.com 和 AOSP）
- **前台服务**：类型用 `connectedDevice`。
  - 它需要 `FOREGROUND_SERVICE_CONNECTED_DEVICE` 权限，外加 `CHANGE_NETWORK_STATE`、`CHANGE_WIFI_STATE`、`CHANGE_WIFI_MULTICAST_STATE` 中的一个。这些都不会弹窗问用户。
  - 没有时长限制，可以在 `BOOT_COMPLETED` 时启动。
  - 不要用 `dataSync`：targetSdk 35 起每 24 小时只能跑 6 小时。
  - 不能随便从后台启动前台服务。能用的豁免有：
    - 有悬浮窗权限（SAW），而且悬浮窗正在显示（targetSdk 35 起要求必须可见）；
    - 用户关掉了这个 App 的电池优化；
    - 开机完成；
    - 用户点了通知。
- **从后台打开界面**：持有 SAW 权限的 App 直接 `startActivity(FLAG_ACTIVITY_NEW_TASK)` 一直到 Android 17 都允许。Android 14 到 17 新加的限制只针对 PendingIntent，不影响直接调用。
  - 但小米 HyperOS 和 vivo 还要用户打开"后台弹出界面"，否则会静默失败。
- **充电和横放**：
  - `ACTION_POWER_CONNECTED` 不在清单广播的豁免名单里，只能在前台服务里动态注册。
  - 当前的充电状态从 `ACTION_BATTERY_CHANGED` 这条粘性广播里读。
  - 手机实际是不是横放，只能用重力传感器判断。显示方向跟着前台 App 走，靠不住。
  - 屏幕熄灭后，非唤醒类传感器不送数据。
- **悬浮窗**：用 `WRAP_CONTENT` 窗口，加 `FLAG_NOT_FOCUSABLE | FLAG_NOT_TOUCH_MODAL`，窗口外的触摸会正常传给下面的 App。Android 12 的不可信触摸拦截只针对 `FLAG_NOT_TOUCHABLE` 的穿透窗口。
  - 展开时直接改这个窗口的尺寸，不要做全屏透明窗。
- **常亮与功耗**：
  - 常亮用 `FLAG_KEEP_SCREEN_ON`，不要用 wake lock。
  - 每个窗口可以单独设 `screenBrightness`，OLED 上最省电的办法就是调暗。
  - 降低刷新率可以用 `View.setRequestedFrameRate(...LOW)`（API 35），或者 `Surface.setFrameRate`、`preferredRefreshRate`。这些都只是建议，厂商可以不听。
  - 防烧屏没有系统 API，只能自己定时挪动画面、调暗。
- **网络保活**：
  - Doze（深度休眠）期间，持有前台服务的进程网络不会被断。但各家国产系统的冻结机制仍可能切断它。
  - 同一子网内没有 NAT，心跳只是为了发现对端已经断了。
  - `NsdManager`（mDNS 发现）只在 App 处于前台时才会替你拿组播锁；后台重新发现时要自己短时间持有 `MulticastLock`。
- **Android 17 的本地网络权限**：targetSdk 37 起，`ACCESS_LOCAL_NETWORK` 是必需的运行时权限，属于 `NEARBY_DEVICES` 权限组。
  - 不申请的话，连局域网的 TCP 会超时，mDNS 也用不了。
  - 运行在 Android 16 上时不要申请这个权限。
- **国产系统保活**：要用户手动打开自启动、把电池设为"无限制"、在最近任务里锁住 App、允许悬浮窗和后台弹出界面。各家的具体位置不一样（参考 dontkillmyapp.com）。
  - 侧载 App 可以用 `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` 请求忽略电池优化。

## 5. 架构

```
┌─────────────── Claude Code 会话（CLI / VS Code / Desktop）───────────────┐
│ hooks ─▶ critter-hook event     （已有：写状态文件；新增：撤销已了结的请求） │
│ PermissionRequest ─▶ critter-hook ask   （新增：可能等手机回复）           │
│ 状态栏 ─▶ critter-hook statusline -- <原来的状态栏命令>   （新增）         │
└──────────────┬──────────────────────────────────┬──────────────────────┘
               │ ~/.critter/sessions/*.json         │ ~/.critter/pending/*.json ⇄ answers/*.json
               │ ~/.critter/status/*.json           │ ~/.critter/inbox/*.json（收件箱地址，0600）
               ▼                                    ▼
      Critter.app ── MonitorEngine（已有）── 手机连接模块 Bridge（新增，独立队列）
                                                    │ TLS WebSocket，Bonjour _critter._tcp
                                                    ▼ 局域网
      Android App ── 前台服务（连接、悬浮球、充电/横放检测、通知）
                  ├─ 悬浮球（悬浮窗，WRAP_CONTENT）
                  ├─ 看板 Activity（Critter 模式 / 专业看板）
                  └─ 作答 / 详情卡片（半透明 Activity）
```

- **文件仍是唯一的跨进程接口**：hook 和 App 之间只通过 `~/.critter/` 下的文件通信，延续桌面版"hooks 不依赖 App"的原则。
- **手机端功能默认关闭**：在 Mac 设置里打开"手机连接"之后，才会监听网络端口、生成待答请求【Claude 定】。

## 6. 电脑端改动

### 6.1 状态栏数据采集
- 新增 `critter-hook statusline [-- <原命令>]`，按下面的顺序工作：
  1. 从 stdin 读入整段 JSON。
  2. 把需要的字段原子写入 `~/.critter/status/<session_id>.json`：
     - `sessionId`、`updatedAt`（毫秒）；
     - `model.id`、`model.displayName`；
     - `contextWindow.size`、`usedPercentage`；
     - `rateLimits.fiveHour` / `sevenDay` 的 `usedPercentage`、`resetsAt`。
  3. 把**同一段 stdin 原样**交给 `/bin/sh -c "<原命令>"`，把它的 stdout 原样输出。
  - 字段缺失或 null 时就不写那个字段。
  - 任何错误都吞掉，原命令照样运行。
  - 自己额外增加的耗时目标 < 20 ms。
- 安装方式：把 `~/.claude/settings.json` 里的 `statusLine.command` 改成 `[ -x '<hook>' ] && exec '<hook>' statusline -- '<原值>' || exec /bin/sh -c '<原值>'`（`<hook>` 是展开后的 `~/.critter/bin/critter-hook` 绝对路径）；卸载时还原成原值【Claude 定】。
  - 后半段是兜底：hook 文件不在了（`~/.critter` 被删、卸载到一半），shell 直接运行原命令，状态栏不会坏。
  - 最早的形式是 `'<hook>' statusline -- '<原值>'`，没有兜底。还原和状态判断两种形式都认，`statusline-install` 会把旧形式就地升级成新形式。
  - 原来没有状态栏的话，就写成 `[ -x '<hook>' ] && exec '<hook>' statusline || exit 0`，这时什么都不输出。已实测：输出为空时，终端的样子和没有状态栏时一样（§13.5）。
  - 编辑 settings.json 的要求：
    - 除了这一个字符串，其它字节都不变；
    - 先备份到 `~/.critter/backup/`；
    - 文件解析失败，或者 `statusLine` 不是 command 类型时，拒绝修改并说明原因；
    - 重复执行结果不变。
  - 由 `critter-hook` 的子命令实现，例如 `statusline-install` / `statusline-uninstall`，`make install` 和 `make uninstall` 调用它们。
- 项目级设置可能覆盖 `statusLine`，这种项目里的会话就采不到状态栏数据。这种情况只在 README 里说明，不做处理。
- **额度是账号级的**：取所有会话里 `updatedAt` 最新的那一份。
  - 过了 `resetsAt` 的窗口，显示"已重置"，不显示旧的百分比。
  - 这份数据超过 30 分钟没更新时，显示"x 分钟前"。

### 6.2 git 分支与上下文兜底（在 Critter.app 里算）
- **分支**：从 `cwd` 往上找 `.git`，最多找到家目录为止。
  - `.git` 是目录：读 `HEAD`。
  - `.git` 是文件（worktree、子模块）：跟着里面的 `gitdir:` 找到对应目录，再读那里的 `HEAD`。
  - 内容是 `ref: refs/heads/<名字>` 时，分支就是这个名字；否则是分离头，显示 7 位短哈希。
  - 结果按 HEAD 文件的修改时间缓存。不调用 `git` 命令。
- **上下文**：
  - 有状态栏数据时，以状态栏为准。
  - 没有时，读会话记录末尾（≤ 64 KB），找最后一条带 `usage` 的 assistant 消息，按上面的公式算。窗口大小先看状态栏有没有给过，没有就按模型 id 推断（参见 model-config 文档里哪些模型默认 100 万），推断不了就按 20 万。
  - 兜底算出的数显示"≈"。
  - 结果按文件大小和修改时间缓存。

### 6.3 能等手机回复的 hook：`critter-hook ask`
- 在 `plugin/hooks/hooks.json` 里给 `PermissionRequest` 再加一项：
  - 命令是 `critter-hook ask`，`timeout: 600`；
  - 原来那项 `event`（timeout 5）保留；
  - 插件版本号加一。
- **门槛**【Claude 定】：下面三条同时满足才进入等待，否则立刻 exit 0、不输出任何东西。
  1. `app.json` 的心跳是新鲜的（≤ 10 秒）；
  2. 手机连接已经打开；
  3. 最近 10 分钟内有任何一台已配对的手机连过。

  第 3 条用"10 分钟内连过"而不是"此刻在线"，是因为手机熄屏时 Wi-Fi 可能短暂断开，熄屏期间来的请求，亮屏后应该还能答。
  - 另外，在 §13.3 验证之前，`ask` 只对终端里的会话生效：hook 环境里的 `CLAUDE_CODE_ENTRYPOINT` 必须是 `cli`。VS Code、Desktop、SDK 的会话，以及这个变量缺失时，一律立刻 exit 0、不输出、不写 pending 文件。
- **等待**：
  1. 原子写入 `~/.critter/pending/<requestId>.json`（目录 0700）。内容是：
     - `requestId`（随机）、`sessionId`；
     - `kind`：permission / question / plan；
     - `toolName`、`toolInput`（超长的截断，见下）；
     - `matchKey` = sha256(toolName + 规范化后的 toolInput)；
     - `createdAt`、`expiresAt` = createdAt + 590 秒；
     - 本 hook 的 pid。
  2. 然后等下面任意一件事发生（用 kqueue 监听目录，或者每 200 ms 查一次，由实现者决定）：
     - `~/.critter/answers/<requestId>.json` 出现：校验后输出决策，删掉两个文件，exit 0；
     - 自己的 pending 文件被删了，说明请求已经在别处了结：不输出，exit 0；
     - Critter 的心跳超过 10 秒没更新：删掉 pending 文件，不输出，exit 0；
     - 到了 `expiresAt`：同上。
- **决策 JSON 由 hook 自己拼**，只用它从 stdin 读到的原始 `tool_input`，加上回答里几个受约束的字段。手机或 App 传来的内容**绝不会原样**变成 `updatedInput`：

| kind | 回答 | hook 输出 |
|---|---|---|
| permission | `{"decision":"allow"}` | `decision.behavior = "allow"` |
| permission | `{"decision":"deny","message":"…"}` | `behavior = "deny"`，`message` 为用户写的理由；没写就用 "用户在手机上拒绝了" |
| question | `{"answers":{"<问题原文>":"<label 或自由文本>"}}` | `behavior = "allow"`，`updatedInput` = 原 `tool_input` 加上 `answers`；只接受原 `questions` 里出现过的问题原文 |
| plan | `{"decision":"approve"}` | `behavior = "allow"`，`updatedInput` = 原 `tool_input` |
| plan | `{"decision":"revise","message":"…"}` | `behavior = "deny"`，`message` = 修改意见 |

- **撤销已了结的请求**：pending 文件被删，等待中的 hook 就会退出，手机上的卡片也跟着消失。
  - `critter-hook event` 处理这些事件时顺带删除：
    - `PostToolUse`、`PostToolUseFailure`、`PermissionDenied`：删掉同一会话里 `matchKey` 相同的 pending 文件；
    - `UserPromptSubmit`、`Stop`、`StopFailure`、`SessionEnd`：删掉这个会话的所有 pending 文件。
  - Critter.app 处理这些情况：
    - `MonitorEngine` 识别到 Esc 中断时（实测 8：拒绝不会触发任何事件，只能这样发现），删掉该会话的所有 pending 文件；
    - 会话被回收时同样删除；
    - 启动时清掉过期的 pending 和 answers 文件。
- **超长内容**：
  - Bash 命令、文件路径、问题、计划原文都完整保留。
  - Edit/Write 的内容只保留前 4 KB，这部分只用来显示；`matchKey` 用完整内容计算。
- 必须遵守桌面版对 hook 的全部约束：永远 exit 0；除了合法的决策 JSON 以外不输出任何东西；所有异常都吞掉。

### 6.4 收件箱与"发一句"
- `critter-hook event` 在 `SessionStart` 时，把 `CLAUDE_CODE_MESSAGING_SOCKET` 和 `CLAUDE_CODE_MESSAGING_TOKEN` 写进 `~/.critter/inbox/<session_id>.json`，文件权限 0600。会话结束时删除。
- Critter.app 收到手机的"发一句"后，连接这个 socket，按实测 10 的格式写两行，然后关闭连接。
  - socket 不存在、连接失败、或者地址不在 `/tmp/cc-socks*` 下，就告诉手机"发送失败"。
- 界面上要写明：Claude 会把这句话当成"另一个会话发来的消息"，它不能用来批准任何东西。
- 这个接口没有正式文档。将来格式变了、发不出去时，只把这个功能关掉，不影响其它功能。

### 6.5 Critter.app 的手机连接模块（Bridge）
- **线程**：独立的串行队列，和 `MonitorEngine` 一样。不碰主线程，出错也不影响宠物界面。
- **监听**：用 Network.framework 的 `NWListener`，WebSocket over TLS，默认端口 47823，端口被占时自动顺延。用 Bonjour 广播 `_critter._tcp`，名字是这台 Mac 的电脑名。
  - 只接受私有网段来的连接：10/8、172.16/12、192.168/16、169.254/16、100.64/10，以及 IPv6 的链路本地和 ULA 地址。
- **TLS 身份**：第一次打开手机连接时生成自签名证书，私钥存到钥匙串或 `~/.critter/bridge/`（0600）。只有点"重置配对"才重新生成。生成方法由实现者决定，比如调用系统自带的 `/usr/bin/openssl`。
- **配对**【Claude 定】：
  1. Mac 设置 →"添加手机"，显示一个二维码，内容是 `critter-pair://<IP>:<端口>?fp=<证书 SHA-256>&code=<8 位一次性码>&name=<电脑名>`。码 5 分钟内有效，只能用一次。
  2. 手机扫码后，用这个指纹固定（pin）证书连接，发送 `pair`。
  3. Mac 弹出确认"允许「设备名」连接？"。
  4. 用户确认后，Mac 发给手机一个随机设备令牌。Mac 端只存令牌的哈希，存在 `~/.critter/bridge/devices.json`（0600）。
  - 备用方式：手机通过 Bonjour 找到 Mac，手动输入 8 位码，第一次连接时信任看到的证书指纹。
  - 设置里有已配对设备列表，可以撤销，还显示每台设备的最后在线时间。
- **快照**：
  - 订阅 `MonitorEngine.rebuild` 去重后的输出，再补上这些信息：
    - 分支、上下文、状态栏数据；
    - 每个会话的形象（由 `PetController` 提供，会话标识用 id）；
    - 待答请求。
  - 有变化时在 250 ms 内合并推送，每次推送完整快照（会话不多，通常 < 20 KB）。
  - 另外两类文件变化也会触发推送：
    - `~/.critter/pending`，用 `DirectoryWatcher` 监听；
    - `~/.critter/status`。
- **回答**：
  1. 手机发来 `answer` 后，先校验：
     - 请求还在；
     - kind 对得上；
     - 字段合法（问题原文必须属于这个请求）。
  2. 校验通过后，原子写入 answers 文件，回复成功。不通过就回复失败和原因，比如"已在电脑上处理"。
- **标记已看过**：手机点"做完了"的小人时，发 `seen`。Mac 调用 `monitor.markSeen`，效果和桌面上点击一样【Claude 定】。
- **心跳**：`app.json` 增加两个字段，`bridgeEnabled` 和 `lastClientSeen`（毫秒），给 `critter-hook ask` 判断门槛用。

### 6.6 设置界面
新增"手机"一节，包含：
- 开关"允许手机连接"，默认关；
- "添加手机"（显示二维码和 8 位码）；
- 已配对设备列表（显示最后在线时间，可以撤销）；
- "状态栏数据"的状态（已接入 / 未接入 / 被项目设置覆盖时的说明），以及接入、撤销按钮；
- "重置配对"。

### 6.7 安装 / 卸载
- `make install`：多执行一步 `statusline-install`，并把插件版本号加一（hooks.json 有改动）。
- `make uninstall`：先执行 `statusline-uninstall`，再执行原来的卸载步骤。还原不了（`settings.json` 里仍然是 Critter 的包装）时，停在这一步，什么都不删，打印现在的命令、手动还原的办法和 `~/.critter/backup/` 里的备份。
- 新增 `make android`：调用 `android/gradlew assembleRelease`，签名用本地 keystore，keystore 不进仓库。
- 新增 `make android-install`：用 `adb install -r` 安装到手机。

## 7. 通信协议
- WebSocket 文本帧，每帧一个 JSON 对象，用 `type` 区分消息。单帧上限 1 MB。
- 字段名由实现者定，下面只列语义。

**手机 → Mac**

| type | 用途 |
|---|---|
| `hello` | 协议版本号（第一版为 1）、设备令牌、App 版本 |
| `pair` | 一次性码、设备名 |
| `answer` | requestId，以及 §6.3 表里的回答字段 |
| `seen` | sessionId |
| `say` | sessionId、文本（≤ 4000 字） |
| `skin` | 请求某个形象的 manifest（自定义皮肤用） |

**Mac → 手机**

| type | 用途 |
|---|---|
| `welcome` | 协议版本号、电脑名、Critter 版本 |
| `paired` | 设备令牌 |
| `snapshot` | 见下 |
| `result` | 对 answer、seen、say 的回执：成功或失败，以及原因 |
| `skin` | 形象名和 manifest JSON |

**快照内容**：
- `sessions[]`，每个会话包括：
  - id、name、source；
  - state、detail、activity；
  - cwd（家目录显示成 `~`）、branch；
  - model；
  - context：已用百分比、窗口大小、是否为估算；
  - skin（形象名）；
  - eventTime、startedAt、tracked。
- `limits`：
  - fiveHour：usedPercentage、resetsAt；
  - sevenDay：usedPercentage、resetsAt；
  - updatedAt。
- `pending[]`，每个请求包括：
  - requestId、sessionId、kind；
  - toolName；
  - 显示用的内容：命令、路径、问题和选项（含 multiSelect 标记）、计划原文；
  - createdAt、expiresAt。
- `settings`：桌面的合并阈值、空闲淡化、随机宠物开关等等。手机端可以选择跟着电脑走。

**断线重连**：手机重连后先收到完整快照，不需要补发中间的变化。

## 8. 手机端

### 8.1 工程与技术栈【Claude 定，实现者可以换等价方案】
- 工程在 `android/`，分两个模块：
  - `:core`：纯 Kotlin/JVM 库。内容是形象模型和校验器、`SkinRenderer.grid`、整个动画引擎、协议模型。用 JVM 单元测试。
  - `:app`：Android 应用。
- 内置形象：构建时把仓库根目录的 `Skins/` 复制进 assets；声音同理，从 `Sounds/` 复制。源文件始终只有一份。
- 依赖：
  - Kotlin 协程、kotlinx.serialization；
  - OkHttp：WebSocket，加一个固定证书指纹的 TrustManager；
  - Jetpack Compose：设置页、引导页、专业看板、卡片；
  - 扫码用 CameraX 加一个离线解码库，比如 ZXing core。不能依赖 Google Play 服务，华为手机上没有。
- 小人统一用自定义 View（`CritterView`）画在 Canvas 上，不用 Compose 画。这个 View 同时用在悬浮球和 Critter 看板里。

### 8.2 动画引擎移植
- **要逐行翻成 Kotlin 的**（这些都是纯逻辑，只依赖 Foundation）：
  - `Skin.swift`：模型、`SkinValidator`、`SkinLoader`（不包括内嵌的 clawd JSON，那份直接用 assets 里的）；
  - `SkinRenderer.grid` 和 dim 色调公式；
  - `Motion/` 目录下的全部文件：`MotionActor` 及其 `+State`、`+Interaction`，`Particle`，`MotionGaze`，`MotionTravel`，`MotionMath`（含 SplitMix64 和 `jsRound`）；
  - `TickGrid`、`ActorSnapshot`；
  - `FlockModel`：合并或展开的判断。
- **要在安卓上重写的**：
  - `CritterSpriteLayer`：画快照。地面裁切、影子、道具、粒子、头顶标记、角标的绘制顺序都要和桌面一致。
  - `SpriteAtlas`：缓存姿势位图，包括正常和变暗两种。
  - `MotionClock`：用 Handler 或 Choreographer，定时到 `ticksUntilChange` 那一刻再醒，屏幕看不见时停下。
- **验收标准**：把 `Tests/CritterCoreTests` 里的这些测试移植成 Kotlin 单元测试，全部通过：
  - `TickGrid`、`Particle`、`MotionPlayback`、`MotionState`；
  - `MotionInteraction` 中和单只宠物有关的部分；
  - `Skin`、`SkinAssigner`。
  - 另外加一个"金样"测试：在 Swift 里用固定种子跑几段状态序列，把每一拍的快照导出成 JSON 放进 `android/core/src/test/resources`，Kotlin 用同样的种子跑一遍，逐拍比较。
- **触摸交互**：对应桌面上的鼠标交互。手机没有悬停，所以：
  - 手指按下 = 注意到你。睡着的会醒过来，醒着的会抬手顶一下。
  - 按住拖动超过 3 dp = 拎起来，松手 = 放下。
  - 轻点后松开 = boop，同时执行点击动作。
  - 来回蹭 = 摸摸，用 `RubDetector`，阈值换算成 dp。
  - 手指在屏幕上时，目光跟着手指走。
- **减少动态效果**：系统"移除动画"打开（动画时长缩放为 0）时，等同于桌面的"减少动态效果"。

### 8.3 连接与保活
- **前台服务** `BridgeService`：
  - 类型 `connectedDevice`，常驻通知写"已连接 · N 个会话"。
  - 只从界面启动；开机和 App 更新后自动重新启动。
  - 用户关掉手机连接时，停止服务。
- **连接**：
  - 先用上次成功的地址，失败了再用 NSD 重新发现。后台发现时短暂持有 `MulticastLock`。
  - 断线后退避重连：2 秒起，逐步加倍到 60 秒封顶。网络变化（`NetworkCallback`）时立刻重连一次。
  - 不在 Wi-Fi 上时不重连。
- **心跳**：看板打开时 30 秒一次，其它时候 3 分钟一次。Mac 端 10 分钟没收到任何流量，就断开这个连接。
- **离线显示**：
  - 悬浮球变成一只灰色睡着的小人，标签写"离线"；
  - 看板保留最后一次的数据，标注"x 分钟前"；
  - 待答卡片置灰，不能作答。

### 8.4 悬浮球（草图 1、2B）
- **收起**：
  - 显示"一堆"：最急的那只站最前面，头顶是它的状态标记，后排最多再画两只、变暗；
  - 上方显示各状态的数量，下方标签写"N 个会话"；
  - 只有一个会话时就是一只。
  - 可以拖动，松手后吸附到最近的左边或右边，位置会记住。
- **展开**：点一下，同一个窗口变高，沿所在的那条边竖排展开【用户定】。
  - 每只小人旁边是气泡（朝屏幕内侧）和标签（名字 · 来源）。
  - 放不下时可以上下滑。
  - 末尾有"收起"把手。点窗口外面也会收起（`FLAG_WATCH_OUTSIDE_TOUCH`）。
- **点某只小人**：
  - 它在"需要你"：打开作答卡片；
  - 它"做完了"：发 `seen`，同时打开详情卡片；
  - 其它状态：打开详情卡片。详情卡片显示状态、在做什么、目录、分支、模型、上下文，以及"发一句"。
- **卡片的形式**【Claude 定】：半透明的底部弹层 Activity，盖在当前 App 上。用 Activity 是为了能弹出输入法。
- **设置项**：
  - 大小；
  - 空闲淡化（默认跟着电脑）；
  - 没有会话时自动隐藏（默认关，这时显示一只睡着的小人）；
  - 全屏应用里是否隐藏（默认关）。

### 8.5 作答卡片（草图 3）
- **权限**：标题是"<名字> 想 <做什么>"，副标题是目录 · 分支 · 来源，正文是命令或路径。按钮有"拒绝"和"允许"。"拒绝"可以展开一个输入框写理由。
- **提问**：
  - 支持 1–4 个问题，每题列出选项（label 和说明）。
  - 单选题点了就提交。多选题勾选后提交。每题都有"自己写一句"。
- **计划**：
  - 计划原文按 Markdown 渲染，可以滚动。
  - 按钮有"批准"和"让它改"（附修改意见）。
- 底部小字："电脑上也能答，谁先答算谁的"。
- 请求已经在别处了结时，卡片显示"已在电脑上处理"，然后自动关闭。
- 请求过期了（Mac 回 `expired`）时，卡片像“已在电脑上处理”一样显示“已经过期了”和 Mac 的话（没有就是“这个请求已经过期了”），然后自动关闭。
- 其他回答失败时，提示原因，卡片不关。
- 待答请求就是快照里的 `pending`。卡片每次都按 requestId 取，绝不按"这个会话当前的请求"取。

### 8.6 纯看板模式（草图 board-modes）
- **形式**：`BoardActivity`，锁定横屏，沉浸式全屏，纯黑背景。
  - 常亮用 `FLAG_KEEP_SCREEN_ON`。
  - 亮度默认 0.3，可以调。
  - 可以显示在锁屏上面（`setShowWhenLocked`、`setTurnScreenOn`）。但在锁屏上作答前要先解锁（`requestDismissKeyguard`）【Claude 定】。
  - 两种模式用一个按钮或左右滑来切换，会记住上次选的。
- **Critter 模式**：
  - 小人放大站成一排，排法和动画都同桌面。每只的组成：
    - 头顶：气泡和状态标记；
    - 脚下：名字、分支 · 来源；
    - 最下面：一条细线，表示上下文用量。
  - 左上角是时钟【Claude 定】，右上角是 5 小时和 7 天额度的小进度条。
  - 交互同 §8.2，点"需要你"的那只会打开作答卡片。
  - 会话太多放不下时，先缩小，再把空闲的合并成一堆。具体做法由实现者定。
- **专业看板**：
  - 左栏：时钟；两张额度卡，各有百分比、进度条和重置时间。
  - 右边：两列会话卡片，内容有状态色块、在做什么、分支、目录、来源、上下文进度条和用量。
  - 需要你的卡片排在最前面，带橙色边框，可以直接点"允许"或"拒绝"。提问和计划要打开卡片才能答。
  - 会话多了右边可以上下滑。
- **自动打开 / 退出**【用户定：横放加充电时开启】：
  - 前台服务动态监听充电。充电时打开重力传感器（`SENSOR_DELAY_NORMAL`，批量上报），不充电时关掉。
  - 判定横放并且静止 3 秒后，打开看板（`FLAG_ACTIVITY_NEW_TASK`）。
  - 用户在这次充电期间手动退出过看板，就不再自动弹出，直到下次插电。
  - 退出条件：拔掉电源 10 秒后，或者竖起来 3 秒后，自动退出【Claude 定】。
- **省电手段**：
  - 动画最快每 60 ms 一帧（约 16 fps），而且只有画面真的变化时才重画。
  - 申请低刷新率：API 35 以上用 `setRequestedFrameRate` 的 LOW 类别，更早的版本用 `Surface.setFrameRate(30)` 或 `preferredRefreshRate`。
  - 时钟每分钟只重画一次。
- **防烧屏**：
  - 每 3 分钟把整个画面随机挪动 ±4 dp；
  - 静止的文字用灰色；
  - 15 分钟没有触摸、也没有状态变化时，自动再调暗一档。
- **以后**：系统屏保（DreamService）形式的看板，适合系统没有隐藏屏保设置的手机。第一版不做。

### 8.7 提醒【Claude 定】
- **有会话变成"需要你"时**（和桌面一样，只在刚进入这个状态时提醒一次）：
  - 短震一下；
  - 悬浮球里那只蹦出来；
  - 悬浮球看不见时（锁屏、熄屏、悬浮球关着），发一条高优先级通知：
    - 权限请求：通知上直接带"允许""拒绝"按钮，按钮设了 `setAuthenticationRequired(true)`，锁屏时要先解锁；
    - 提问和计划：带"打开"按钮。
  - 看板开着、悬浮球因此收起时，看板代替悬浮球显示请求，也不发通知；悬浮球关着时，看板不拦通知。
  - 悬浮球（或代替它的看板）看得见时来的请求先不发通知；等它变得看不见（熄屏、锁屏、被隐藏、关掉）时，还没了结的补发一次，不再震动。
  - 请求了结后，通知自动撤回。
- **做完了 / 出错**：默认不震动、不发通知，可以在设置里打开。
- **提示音**：只在看板模式下响，默认关；声音和桌面那几套一样。
- 遵守系统的勿扰模式。

### 8.8 首次引导与设置
- **首次引导**依次是：
  1. 扫码配对；
  2. 本地网络权限（Android 17 及以上）；
  3. 通知权限；
  4. 悬浮窗权限；
  5. 忽略电池优化；
  6. "保持后台运行"：按 `Build.MANUFACTURER` 显示对应厂商的设置步骤，能跳转的地方直接跳过去。要覆盖的设置有自启动、电池无限制、锁定最近任务、后台弹出界面。

  每一步都可以跳过，跳过后的影响要说清楚。
- **设置页**分几组：
  - 连接：已配对的电脑、状态、重新配对；
  - 悬浮球：见 §8.4；
  - 看板：自动打开、默认模式、亮度、退出规则；
  - 提醒：见 §8.7；
  - 形象：跟着电脑，或者手机上单独选；
  - 减少动态效果。

## 9. 省电要求【用户定：不做耗电实测验收，只要求在代码层面尽量优化】

不设测量数字，也不做耗电、温度的实测验收。代码必须做到下面这些，代码审查时逐条检查：

- **只在画面变化时才画**：
  - 小人的时钟按 `ticksUntilChange` 定时醒来，和桌面版相同；
  - 所有会话空闲时，悬浮球不重画；
  - 看不见的视图（悬浮球收在边上被遮挡、Activity 在后台、熄屏）停掉时钟。
- **帧率**：
  - 动画最快每 60 ms 一帧；
  - 看板申请低刷新率（§8.6）；
  - 不用持续运行的属性动画或无限循环的 Compose 动画；
  - 时钟文字每分钟只重组一次。
- **网络**：
  - 一条长连接，服务器主动推送，不轮询；
  - 心跳间隔见 §8.3；
  - 断线重连用指数退避；
  - 不在 Wi-Fi 上时不重连；
  - mDNS 发现只在连接失败时做。
- **传感器**：只在充电时打开重力传感器，用 `SENSOR_DELAY_NORMAL` 加批量上报，拔电立刻注销。
- **屏幕**：
  - 看板纯黑背景、默认亮度 0.3，没人碰时再调暗一档；
  - 常亮只用 `FLAG_KEEP_SCREEN_ON`，不用 wake lock，拔电后清掉。
- **后台**：
  - 熄屏时只保留连接和提醒，不做任何渲染，不跑周期任务；
  - 不用 AlarmManager 做轮询，不用 WorkManager 做周期任务。
- **内存**：
  - 姿势位图按形象和缩放倍数缓存（同 `SpriteAtlas`），不在每帧里分配对象；
  - 快照更新时只重画变化了的会话。
- **Mac 端**：手机连接模块没有客户端时什么都不做；有客户端时只在快照变化时推送。不能改变桌面版现有的内存和 CPU 表现。

## 10. 安全
- 手机连接**默认关闭**，只在打开后才监听端口，而且只接受私有网段的连接。
- 必须配对：用一次性码加用户在 Mac 上确认，TLS 证书固定指纹。设备令牌在 Mac 端只存哈希，可以撤销。
- 手机能做的事只有四样，其余一概不能（不能执行命令、不能读文件、不能改设置）：
  1. 回答**正在等待**的请求，而且只能用 §6.3 表里的那几种形式；
  2. 标记已看过；
  3. 发一句（发出的消息不能代替用户批准，这是 Claude Code 自己保证的）；
  4. 读形象文件。
- 回答文件只由 Critter.app 写，目录权限 0700；hook 自己拼决策 JSON（§6.3）。
- **威胁模型的边界**【用户定：不防】：以用户本人身份运行的本机进程，**不在防范范围内**，包括另一个 Claude 会话。
  - 这类进程可以写 `~/.critter/answers/`，相当于替用户点了"允许"；也可以删 pending 文件，让手机上的卡片消失。
  - 不防的理由：能做到这些的进程，本来也能改 `~/.claude/settings.json` 放开所有权限，或者替换 `~/Applications/Critter.app`。所以文件通道没有带来新的口子。
  - 这条边界要在 README 的安全说明里写清楚。
  - 不做代码签名身份，不用钥匙串 ACL，也不做对端签名校验。
- 收件箱令牌、TLS 私钥、设备列表，文件权限都是 0600。
- 手机端只在应用私有存储里存三样东西：配对信息、证书指纹、最后一次快照。

## 11. 稳定性与失败方式
- 以下几种情况下，Claude Code 的行为和现在完全一样：手机连接关闭、Critter.app 没运行、手机不在线超过 10 分钟。具体表现：
  - `ask` 立刻退出；
  - 状态栏包装脚本原样转发；
  - `event` 只多做一件事：删除 pending 文件。
- 每个待答请求最多等 590 秒。超时后只能在电脑上答，手机上的卡片随之消失。
- 实测 3 发现，电脑上先答了以后，等待中的 hook 不会被结束。§6.3 的撤销机制让它在 1 秒内自己退出。还要验证一点：撤销之前万一 hook 输出了决策，会不会被忽略（见 §13）。
- Mac 睡眠时连接会断，手机显示离线。不会阻止 Mac 睡眠。
- 手机端：
  - 悬浮窗或服务崩溃后，退避重启，不能陷入崩溃循环；
  - 坏的快照或坏的形象文件直接跳过，不能崩溃；
  - 坏的自定义形象会退回内置的 Clawd。

## 12. 测试与验证
- **Swift 单元测试**：
  - 状态栏解析和原样转发；
  - `ask` 对三种 kind 拼出的决策 JSON，用 §4.1 实验时记录下来的真实输入当测试数据；
  - pending 的撤销匹配（`matchKey`、按事件清理）；
  - 分支读取：普通仓库、worktree、分离头；
  - 上下文兜底计算；
  - settings.json 的修改和还原：其它字节必须不变；
  - 配对令牌存储；
  - 协议的编码和解码。
- **端到端脚本**：把这次实验固化成 `scripts/dev/` 下的脚本，用 tmux 驱动真实的 `claude --model haiku`，用一个命令行测试客户端代替手机，验证以下全部流程：
  - 权限的允许和拒绝；
  - 提问：单选、多选、自由文本；
  - 计划的批准和修改；
  - 终端先答时 hook 自动退出、卡片消失；
  - Esc 拒绝后的撤销；
  - 发一句。
- **Kotlin**：
  - 动画引擎的移植测试和金样比对（§8.2）；
  - 协议模型测试。
- **真机检查点**（用 §3 那台 vivo，通过 adb）：
  - 安卓相关的每一步完成时，都要在真机上走一遍那一步的清单。每一步的清单在实现计划里写。
  - 合起来要覆盖：
    - 配对、断网重连；
    - 悬浮球的拖动、吸边、展开、收起；
    - 作答、通知按钮；
    - 熄屏后前台服务会不会被 vivo 冻结；
    - 看板自动打开和退出（包括 vivo 的"后台弹出界面"开关打开和不打开两种情况）；
    - 防烧屏位移；
    - 悬浮球在所有会话空闲时确实不重画（用调试帧计数器看）。
  - 不做耗电、温度的实测【用户定】。
- **模拟器**：API 37 镜像，通过代理下载。只用来测 Android 17 才有的行为，主要是 `ACCESS_LOCAL_NETWORK` 的申请和拒绝。

## 13. 待实测 / 风险（实现早期先验证）
实测日期 2026-10-19，Claude Code 2.1.302，`--model haiku`，`scripts/dev/e2e-phone.sh` 十个场景全部通过（之后新增的 `late-answer` 还没跑过，见第 2 条）。
1. 【已实测】AskUserQuestion 的 `answers` 格式：
   - 多选：把选中的 label 用 `", "`（逗号加一个空格）连成一个字符串。回答 `A, B` 后，终端显示 `· Pick letters → A, B`，Claude 复述收到的是 `A, B`，两个选项都拿到了，所以不需要试 `,` 连接或 JSON 数组。已写进协议文档和 `AskDecision.multiSelectSeparator`，单元测试 `questionMultiSelectFormat`；安卓端的 `joinMultiSelect` 本来就是 `", "`，不用改。
   - 自由文本：直接把文字当值。回答 `Mango` 后 Claude 复述 `FRUIT=Mango`。
2. 【待实测：场景 `late-answer` 已写好，还没在真实会话里跑过】电脑上先答之后，手机的回答晚到。
   - 撤销要等事件：在电脑上按 Enter 允许后，pending 文件要到工具结束（`PostToolUse`）才删；按 Esc 拒绝后，要等 Critter 从会话记录里认出中断（约 1–2 秒）。这段时间里手机还能答，Mac 回 `ok:true`，等待中的 hook 也会输出决策。`ok:true` 只表示"交给了等待中的 hook"，不表示 Claude 照做了（协议文档已写明）。
   - 要确认的是：这时 Claude Code 会忽略这个晚到的决策。`scripts/dev/e2e-phone.sh late-answer` 测两种情况：(a) 终端里允许了一条要跑 15 秒的命令，命令还在跑时手机回"拒绝"并附一句标记，期望命令照常跑完、标记不出现在屏幕上；(b) 终端里按 Esc 拒绝，紧接着手机回"允许"，期望命令不会执行、屏幕上没有 "Allowed by PermissionRequest hook"。两边手机收到的回执记在 `INFO` 行里。
3. 【需手工检查；在那之前 `ask` 只对 CLI 开启】VS Code 或 Antigravity、Desktop 里的会话：在里面触发一次需要确认的命令，看界面上的确认框是否和 hook 并行等待、手机上答了以后是否自动关闭。
   - 2026-10-19 起，`ask` 只在 `CLAUDE_CODE_ENTRYPOINT == "cli"` 时等待，其它入口（`claude-vscode`、`claude-desktop`、`sdk-*`）和变量缺失时立刻退出（单元测试 `askExitsImmediatelyOutsideTheCli`）。原因：没验证过的入口里，如果确认框要等 hook 返回才出现，一个等待中的 `ask` 会把那里的提示卡住最多 590 秒。
   - 这些会话照样出现在手机上，只是它们的确认只能在电脑上答。验证通过后，把对应的入口加进 `AskCommand` 的允许列表。
4. 【已实测】子代理触发的权限请求：形状和主会话一样，`toolName` 是 `Bash`，`input` 是 `{"command":"touch e2e-sub.txt","description":"…"}`；快照里该请求的 `sessionId` **就是父会话的 id**（没有单独的子代理会话），手机上按父会话显示即可。
5. 【已实测，2026-10-19】状态栏命令输出为空时（原来没有状态栏、接成不带 `--` 的形式），终端底部和没有状态栏时**一样**，所以 `make install` 继续给没有状态栏的用户接上不带 `--` 的形式。
   - 做法：tmux 里开一次性的 `claude --model haiku`，`--setting-sources project` 排除用户设置，用 `--settings` 分别给 `{}`（没有状态栏）和 `statusLine = '<hook>' statusline`（输出为空）两种，开场和回复一次之后各截一次屏。
   - 结果：两边逐行相同，只差路径、会话名、随机的输入提示和用时；底部都是 `⏵⏵ auto mode on (shift+tab to cycle)` 加右侧的 `/rc`，后面没有空行。对照组（`echo SL-CONTROL-LINE`）的状态栏占一行，模式行被挤到下一行，说明这个比较能看出差别。
   - 新的自带兜底的空形式（`[ -x '<hook>' ] && exec '<hook>' statusline || exit 0`）在 hook 存在和不存在时都输出 0 字节、exit 0（单元测试 `wrapperWithoutTheHookRunsTheOriginal`）。
6. 开发用的 vivo 手机上，从后台打开看板会不会被拦，以及需要打开哪些开关。`ACCESS_LOCAL_NETWORK` 的实际弹窗表现，在模拟器上验证。
7. 收件箱 socket 是没有文档的接口，Claude Code 升级后要重新验证。2026-10-19 在 2.1.302 上，"发一句"（场景 `say`）仍然有效：空闲会话立即开始新的一轮并照做。

其它在端到端测试里一并确认的：
- 在电脑上按 Enter 允许后，工具一结束请求就从快照里消失（2 秒内），`critter-hook ask` 进程也退出了；按 Esc 拒绝后 2 秒内请求消失。
- 计划：退回修改意见后 Claude 重新提交了计划，批准后退出计划模式，回到进入计划模式之前的权限模式（实测是"接受编辑"）。

## 14. 建议的实现顺序（交给实现计划细化）
1. **Mac 数据层**：状态栏采集、分支、上下文兜底，用 `PetSession` 加上补充信息组成快照模型。
2. **Bridge**：TLS WebSocket、Bonjour、配对、快照推送，再加一个命令行测试客户端。
3. **作答链路**：`critter-hook ask`、pending/answers、撤销机制，然后跑端到端脚本，同时验证 §13 的第 1–5 条。
4. **安卓骨架**：配对、前台服务、连接保活、专业看板（先只用文字和进度条）、作答卡片、通知。
5. **`:core` 动画引擎移植**、`CritterView`，然后是 Critter 看板模式。
6. **悬浮球**：收起、展开、拖动、吸边、提醒。
7. **看板自动打开和退出**、首次引导、各厂商的保活引导，然后按 §9 逐条检查省电要求。
8. **发一句**。

## 15. 留给实现者的
- 库的具体选择（只要满足 §8.1 的约束）、协议字段的具体名字、端口号的顺延规则、重连退避的具体数值。
- 悬浮球展开、收起、拖动时的动画细节，只要沿用桌面的动作名和节奏。
- 会话太多时，看板的缩放和合并规则。
- 生成证书的方法、等待回答时用监听目录还是轮询。
- 专业看板在小屏手机上的排版细节。草图按 800×370 画，实际要适配常见的横屏尺寸。
