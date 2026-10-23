# Critter 桌面宠物 — 设计文档

日期：2026-10-17
状态：已过开发者视角审阅，待用户确认

> **2026-10-23 更新：**Clawd 形象已从项目中移除（它只属于 Claude Code，而 Critter 现在也支持 Codex，以后还会接入更多 Agent）。默认形象和皮肤出错时的内置兜底都改为小芽 Sprig；下文提到 Clawd 的地方是当时的记录。

> 记号说明：**【用户定】** 是用户在讨论中明确做出的决定；**【Claude 定】** 是 Claude 代为做出、用户尚未逐条确认的决定，实现中可以调整但应先说明；没有标记的是两者都已讨论过的事实或共识。

---

## 1. 意图

用户同时在多个地方跑 Claude Code 会话（终端 CLI、Claude Desktop App 的 Code 页、VS Code 插件），活多的时候会同时开好几个。切到别的窗口干别的事时，没法知道哪个会话已经做完、哪个卡在等授权，经常回来才发现早就停了。

要做一只常驻屏幕最上层的桌面宠物——Claude Code 的吉祥物 Clawd——一眼就能看到所有活跃会话的状态；需要你的时候（等确认、做完、出错）它会换样子、冒气泡、可选地出声；点它就跳回对应的会话窗口。参考 OpenAI Codex 的 pet 功能，但要轻量、稳定。

第一版**着重功能**；交互动画后续补，但动画系统从第一版起就要是可扩展的，不能写死。

## 2. 目标 / 非目标 / 反目标

### 目标（第一版）
1. 发现并显示所有本机活跃的、交互式的 Claude Code 会话，**不论它跑在终端、Desktop App 还是 VS Code**。
2. 每个会话一只小 Critter，实时显示 5 种状态之一（见 §6.1），气泡显示当前在做什么/需要什么。
3. 会话多时自动合并，可点击展开/收起。
4. 点击某只 Critter 或它的气泡，跳回该会话所在的窗口。
5. 会话关闭后对应的 Critter 自动离开；检测不到时可以右键手动关闭。
6. 在三种模式里都能用 `/pet` 显示/隐藏宠物。
7. 有设置页，后续个性化功能往里加。

### 非目标（第一版不做）
- 精细交互动画、"足够灵活可爱"（**【用户定】**不在本轮范围；但动画系统要可扩展，见 §6.6）。
- Windows / Linux 版（**【用户定】**保留跨平台可能性，见 §3）。
- 签名、公证、预编译包分发。
- 自定义音效（第一版是"系统音效占位"）**【用户定】**。
- **【Claude 定】**不显示云端会话（claude.ai 网页上的 Claude Code 云会话）、其它机器上的会话、非交互的 `claude -p` / SDK 调用。

### 反目标（做出来但这样就算失败）**【用户定】**
- **占内存太大。** 目标：活动监视器里"内存"一栏（即 `phys_footprint`，用户实际会看的数字，含所有子进程）≤ 50 MB；空闲时 CPU 接近 0，有动画时平均 < 1%（**【Claude 定】**具体数值和口径）。RSS 只作参考：本机实测一个空壳（透明 NSPanel + 一个动画层 + 菜单栏图标）RSS 已有 44–49 MB，但 footprint 只有 12–14 MB，所以不用 RSS 作考核口径。这是放弃 Electron/Tauri、选原生 Swift 的原因。
- **不够稳定，卡死后无法拖动而挡住屏幕内容。** 宠物在任何非用户主动的情况下都不能变成拖不动、关不掉、挡在屏幕上的东西。稳定性是重点（见 §9）。

## 3. 约束

- **平台：** macOS（用户主力机，Apple Silicon，macOS 27，Swift 6.4 / Xcode 已装）。
- **技术：** 原生 Swift **【用户定】**。不进沙盒、不上 App Store（需要读 `~/.claude`）。
- **跨平台余地：** 状态采集层（hooks + 状态文件格式）必须与平台无关，将来做 Windows 版只重写界面层。
- **工程组织：** SwiftPM 包（不是只能 Xcode 打开的工程），便于命令行构建、CI、Homebrew formula。**【Claude 定】**
- **签名：** 本地编译使用，不需要付费开发者账号。
- **不能拖慢或干扰 Claude Code 会话：** hook 必须很快、永远不失败（任何错误都吞掉、exit 0）、永远不输出会影响权限决策的内容。
- **Claude Code 版本：** 当前 2.1.301。`~/.claude/sessions/<pid>.json` 和 `claude agents --json` 是**未正式文档化**的内部数据，可能随版本变化——只能当作增强信息，缺失或格式变了要优雅降级。
- **品牌：** Clawd 是 Anthropic 的吉祥物。自用没问题；开源前要看 Anthropic 品牌规范或换成自绘致敬版。所有形象素材放在单独目录，便于整体替换。

## 4. 已确认的事实（调研 + 本机验证）

- 用户级 hooks（`~/.claude/settings.json` 或已启用插件里的 `hooks/hooks.json`）在 CLI、Desktop App Code 页、VS Code 插件三处都会执行（据官方文档；Desktop 未在本机实测，见 §11 验证项）。
- 可用事件：`SessionStart`、`SessionEnd`、`UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`PermissionRequest`、`PermissionDenied`、`Notification`（`permission_prompt` / `idle_prompt` / `agent_needs_input` 等子类型）、`Stop`、`StopFailure`、`SubagentStop` 等。hook stdin JSON 里有 `session_id`、`cwd`、`transcript_path`、`hook_event_name`，**没有**区分来源（CLI/Desktop/VS Code）的字段，也没有 claude 进程号。
- hooks 支持 `"async": true`（后台执行不阻塞会话）和 `"timeout"`。
- 插件可以打包 hooks + skills/commands，三处都生效；一个 GitHub 仓库可以直接当插件市场。
- 本机 `~/.claude/sessions/<pid>.json` 示例（当前运行中的两个会话）：
  ```json
  {"pid":20409,"sessionId":"d3331ac5-…","cwd":"/Users/apple/CODESPACE/clawd",
   "startedAt":1792166332523,"procStart":"Fri Oct 16 15:58:51 2026","version":"2.1.281",
   "kind":"interactive","entrypoint":"cli","name":"critter-c1","status":"busy",
   "updatedAt":…,"statusUpdatedAt":…}
  ```
  VS Code 里的会话 `entrypoint` 是 `"claude-vscode"`。Desktop App 的值未知。其中 `status` 字段观察到会过时（半小时没更新仍是 `busy`），**不能用来判断状态**，只用来发现会话、取名字和来源。
- `claude agents --json` 能列出这两个会话（pid、cwd、sessionId、name、status、kind）。
- **Desktop App 的 Code 会话用的是本机的 `~/.claude`：** Desktop 自带一份 Claude Code（`~/Library/Application Support/Claude/claude-code/2.1.295`），它的会话记录就写在 `~/.claude/projects/` 里，记录中的 `entrypoint` 是 `"claude-desktop"`（近 30 天有 2439 条）。所以它大概率也读 `~/.claude/settings.json` 和插件、执行 hooks——仍需 §11 实测确认。同目录下还有 `claude-code-vm`，在虚拟机里跑的会话不共享本机 `~/.claude`，不在范围内。
- 近 30 天的会话记录里出现过的 `entrypoint`：`cli`、`claude-vscode`、`claude-desktop`、`sdk-cli`（后者是 `claude -p` / SDK 调用）。
- 本机终端只有 Terminal.app；另装有 Antigravity（VS Code 分支），`~/.claude/ide/*.lock` 的 `ideName` 可区分。
- `~/.claude/ide/<pid>.lock` 记录 VS Code 窗口的 pid 和 `workspaceFolders`。

## 5. 架构

三个部件，外加一个约定好的数据目录：

```
┌──────────────── 任意 Claude Code 会话（CLI / Desktop / VS Code）────────────────┐
│  hook 事件 ──stdin JSON──▶  critter-hook <event>   （小型 Swift 命令行，毫秒级退出） │
│  /pet      ──────────────▶  critter-hook toggle                                    │
└───────────────────────────────────┬────────────────────────────────────────────┘
                                    │ 原子写入（写临时文件再 rename）
                                    ▼
                    ~/.critter/sessions/<session_id>.json   ← 与平台无关的状态文件
                                    │ 目录监听（FSEvents / DispatchSource）
                                    ▼
          Critter.app（Swift，菜单栏常驻，无 Dock 图标）
           ├─ 会话仓库：合并状态文件 + ~/.claude/sessions 增强信息 + 进程存活监听
           ├─ 宠物窗口：透明、置顶、跨所有桌面空间、不抢焦点
           ├─ 跳回窗口：按来源激活对应 app / 窗口 / 标签页
           └─ 设置窗口
```

1. **Claude Code 插件 `critter`**（仓库内 `plugin/`）：`hooks/hooks.json` 把相关事件全部交给 `critter-hook`；提供 `/pet` 命令（见 §7）。
2. **`critter-hook`**：Swift 命令行，读 stdin 的 hook JSON，换算成状态，写状态文件。也负责 `toggle`（显示/隐藏/拉起 app）。必须：启动快（目标 < 30 ms）、永远 exit 0、不向 stdout 输出任何东西（避免被 Claude Code 当成 hook 决策）、任何异常都吞掉。
3. **Critter.app**：读状态文件，渲染宠物，处理交互和设置。

**建议的 SwiftPM 结构【Claude 定】：** `CritterCore`（状态模型、文件格式、事件→状态映射、优先级、合并逻辑；纯逻辑，可单测）、`critter-hook`（可执行）、`CritterApp`（可执行，打包成 .app）。

### 5.1 状态文件格式（跨平台契约）

`~/.critter/sessions/<session_id>.json`，每个会话一个文件。建议字段（实现者可增补，但要保持向后兼容并带版本号）：

```json
{
  "schema": 1,
  "sessionId": "d3331ac5-…",
  "cwd": "/Users/apple/CODESPACE/clawd",
  "transcriptPath": "…",
  "state": "running",            // idle | running | waiting | done | error
  "detail": "Bash: npm test",    // 气泡文字（已截断的人类可读摘要）
  "lastEvent": "PreToolUse",
  "eventTime": 1792167071855,    // hook 开始执行时的毫秒时间戳，用于乱序保护
  "seq": 42,                     // 同一会话内单调递增（若可行）
  "claudePid": 20409,            // 若能得到
  "claudeProcStart": "…"         // 防进程号复用
}
```

- 写入必须原子（临时文件 + rename）。
- **乱序保护：** 写入前比较已有文件的 `eventTime`/`seq`，旧事件不得覆盖新状态（hooks 若用 async 执行，事件可能乱序到达）。
- 是否用 async hook、还是同步 + 短超时，由实现者权衡（见 §12），但必须满足"不拖慢会话"和"乱序安全"。

### 5.2 事件 → 状态映射

| 事件 | 新状态 | 气泡文字 |
|---|---|---|
| `SessionStart` | 空闲 | （无） |
| `UserPromptSubmit` | 运行中 | "思考中…" |
| `PreToolUse` | 运行中 | 工具摘要，如 "Bash: npm test"、"编辑 App.swift" |
| `PreToolUse`（工具是 `AskUserQuestion`） | 等你确认 | "Claude 在问你问题" |
| `PostToolUse` / `PostToolUseFailure` | 运行中 | 保持或"思考中…"（从"等你确认"回到运行中靠它） |
| `PermissionRequest` | 等你确认 | "需要你确认：Bash(npm test)" |
| `Notification`（`permission_prompt` / `agent_needs_input` 等需要用户输入的子类型） | 等你确认 | 通知内容 |
| `Notification`（`idle_prompt`） | 不变 | — |
| `Stop` | 做完了 | "做完了"（若 payload 里能拿到最后一条回复，取前一句作摘要） |
| `StopFailure` | 出错 | 错误类型/信息 |
| `SessionEnd` | 删除状态文件 | — |

- 用户点击了某只"做完了"的 Critter（跳回窗口）即视为已看过 → 变回空闲。
- 具体哪些 `Notification` 子类型算"需要输入"、`PermissionDenied`/`SubagentStop` 怎么处理，由实现者在 Claude Code 2.1.301 上实测后定，原则是"需要人做事 → 等你确认"。
- 映射逻辑放在 `CritterCore`，单元测试覆盖。

### 5.3 会话发现、来源识别、关闭检测

- **发现【Claude 定】：** 两个来源取并集——(a) `~/.critter/sessions/` 下出现状态文件；(b) `~/.claude/sessions/` 里出现一条记录（用目录事件监听，不轮询）。只有 (b) 没有 (a) 的会话（例如插件安装前就已启动、hooks 还没加载的会话），显示为空闲，悬停提示"重启该会话后可显示实时状态"。这样装好后不用重启所有会话也能先看到它们。
- **过滤【Claude 定】：** 只排除已知的非交互入口（`entrypoint` 以 `sdk` 开头，如 `sdk-cli`），**不要**要求 `kind == "interactive"`（避免 Desktop 会话因 `kind` 不同被误藏）。查不到 sessions 记录的会话照常显示。
- **名字：** 优先用 sessions 记录里的 `name`（如 `critter-c1`），否则用 `cwd` 的最后一级目录名。重名时附加来源区分。
- **来源：** `entrypoint`：`cli` → 终端，`claude-vscode` → VS Code，`claude-desktop` → Desktop；未知 → "其他"。sessions 记录里没有时，可以从会话记录 JSONL 里读 `entrypoint`（只读一次，不持续跟踪）。
- **claude 进程号：** 用 `sessionId` 在 `~/.claude/sessions/*.json` 里反查；拿不到时 `critter-hook` 可沿父进程链向上找 `claude` 进程。两种方法实现者择优或并用。
- **关闭检测（两层）【用户定】：**
  1. `SessionEnd` hook 删除状态文件 → Critter 立刻离开。
  2. 兜底：app 对每个已知 claude 进程注册进程退出监听（kqueue `NOTE_EXIT` / `DispatchSource.makeProcessSource`，不轮询）；进程退出 → 删除状态 → Critter 离开。比对进程号时连同进程启动时间一起校验，防止进程号复用误判。
  3. app 启动时清理所有进程已不存在的状态文件。
- **手动关闭【用户定】：** 右键任意一只 Critter → "关闭"，它离开。**【Claude 定】**若该会话其实还活着，之后再来新事件时它重新出现。

## 6. 宠物：外观与交互

### 6.1 形象
照 Claude Code 终端启动画面的字符画逐像素还原（已在浏览器里给用户看过并认可）：

```
 ▐▛███▜▌
▝▜█████▛▘
  ▘▘ ▝▝
```

解码为 18×5 的像素网格，每个像素宽:高 = 1:2（"瘦高"像素）。（Clawd 的像素图已于 2026-10-23 随 Clawd 形象一起从项目中移除。）

用 `nearest-neighbor`/不插值的方式放大渲染，保持像素锐利。素材放在独立的皮肤目录。

### 6.2 五种状态（第一版外观）

| 状态 | 头顶配件 | 动作（第一版） | 气泡 |
|---|---|---|---|
| 空闲 | 灰色 "z z" | 变灰、待机动画（如眨眼/打瞌睡） | 无 |
| 运行中 | 灰色 "•••" | 轻轻跳动 | 当前在做什么 |
| 等你确认 | 橙色 "?" | 摇摆 | 需要确认的内容 |
| 做完了 | 绿色 "✓" | 静止或轻微庆祝 | "做完了"/摘要 |
| 出错 | 红色 "!" | 变灰 | 错误信息 |

- 优先级（合并时、选"最急"时用）：等你确认 > 出错 > 做完了 > 运行中 > 空闲。
- **气泡持续显示，直到该会话状态更新【用户定】**（不自动消失）。展开时每只 Critter 的气泡都在；排版要互不重叠、不遮挡别的 Critter，过长截断，悬停看完整内容——具体排版由实现者定。
- 没有任何会话时：显示一只打瞌睡的空闲 Critter **【Claude 定】**。

### 6.3 布局：一排小 Critter，自动合并【用户定】

- 每个会话一只小 Critter 排成一排，脚下标签：会话名 + 来源（终端 / VS Code / Desktop）。顺序按会话开始时间，稳定不跳动 **【Claude 定】**。
- 会话数 > 阈值（默认 4，设置可调）时**自动合并**成"一堆"：前面一只显示最急的状态（含动画），上方是各状态计数（如 `? 1 ✓ 1 ••• 2`），气泡显示最急的那个会话。
- **合并时同样有待机/工作等动画【用户定】**，不是静态图。
- 点合并的那堆 → 展开；展开时末尾有"收起"把手 → 合并。手动展开/收起后保持用户的选择，直到会话数再次变化。

### 6.4 点击与菜单

- **左键单只 Critter 或它的气泡 → 跳回该会话窗口**【用户定】，并把"做完了"标记为已看过。
- **右键单只 Critter：** 跳回会话、关闭（见 §5.3）。**【Claude 定】**另加"隐藏宠物""设置…"。
- **菜单栏图标【Claude 定】：** 显示/隐藏、设置…、退出。
- **跳回窗口的精度（按来源）：**
  - VS Code 会话：激活打开了该 `cwd` 的 VS Code 窗口（可借助 `~/.claude/ide/*.lock` 的 `workspaceFolders`，或 `open -a "Visual Studio Code" <cwd>`）。
  - 终端会话：沿 claude 进程的父进程链找到所在 GUI app（Terminal、iTerm2、Ghostty、Warp、VS Code/Cursor 内置终端…）并激活。Terminal.app / iTerm2 通过 AppleScript 按 tty 精确选中标签页（首次会触发 macOS"自动化"授权）；其它终端只激活 app。
  - Desktop 会话：至少激活 Claude.app；能否深链到具体会话待实测。

### 6.5 窗口行为

- 透明、无边框、置顶，显示在所有桌面空间和全屏应用之上，不抢键盘焦点、不出现在 Dock 和 ⌘Tab。
- **Critter 之间的透明区域点击穿透**到下面的窗口；Critter 本身可点、可拖。
- 整组可拖到任意位置，记住位置。显示器变化导致位置跑到屏幕外时，自动拉回可见区域。
- 增删会话时这一排朝哪个方向伸缩，由实现者定（建议以用户拖放的那个角为锚点）。

### 6.6 动画系统：可扩展，不写死【用户定】

- 每种状态对应一个**命名动画**（如 `idle`、`running`、`waiting`、`done`、`error`），展开和合并两种模式都用。
- 动画由皮肤目录里的**数据清单**描述（帧序列/精灵图 + 时长 + 循环方式，或程序化动作参数），新增或替换动画、换皮肤不需要改代码。
- 第一版只提供简单动画（跳动、摇摆、眨眼、打瞌睡），但要走同一套接口。
- 动画用低帧率（像素风 ≤ 12 fps 足够）+ Core Animation 驱动，守住 §2 的 CPU 目标。
- 系统"减少动态效果"开启时显示静态帧 **【Claude 定】**。

## 7. 显示 / 隐藏与 `/pet`

- `/pet`：切换显示/隐藏；app 没在运行时先启动再显示【用户定】。
- 隐藏只是收起窗口，app 留在菜单栏，状态照常记录；**【Claude 定】**隐藏期间不播放提示音。
- **实现方式（需先做小实验验证）：**
  - 首选：注册一个 `pet` 命令（保证自动补全、不被当成未知命令），同时用 `UserPromptExpansion` hook 识别 `/pet`，执行 `critter-hook toggle` 后以 `decision: block` 拦下，**不触发模型回复**，只给用户一行"Critter 已显示/已隐藏"。
    - 2026-10-17 在 CLI 2.1.301 上实测可行。注意：插件里的命令会带命名空间（`/critter:pet`），所以 `pet` 命令要装成用户级命令 `~/.claude/commands/pet.md`；hooks 仍放在插件里。`UserPromptSubmit` 会在拦截前先触发一次（prompt 为 `/pet`），状态归约时要忽略它。
  - 兜底：skill 设 `disable-model-invocation: true`，用 `!` 内联执行 `critter-hook toggle`，让模型只回一行结果（会花一次很小的模型调用）。
- `critter-hook toggle` 与 app 的通信方式由实现者定（建议注册 URL scheme `critter://toggle`，`open` 它即可在 app 未运行时自动拉起）。
- **其它入口：** 全局快捷键（默认 ⌃⌥C，可改）、菜单栏图标。

## 8. 设置页（第一版）

| 项 | 默认 | 说明 |
|---|---|---|
| Critter 大小 | 中 | 滑块【用户定】 |
| 提示音总开关 | 开 | **系统音效占位**【用户定】，后续替换 |
| 按状态开关提示音 | 等你确认 / 做完了 / 出错 各一个 | 只在状态**变成**这几种时响一次 |
| 自动合并阈值 | 4 | |
| 全局快捷键 | ⌃⌥C | |
| 登录时自动启动 | 关 | |
| 重置位置 | — | 按钮 |

- 默认值除"Critter 大小可调"和"系统音效占位"外均为 **【Claude 定】**。
- 音效通过一个抽象的播放接口调用，换成自定义音效时不改调用方。
- 设置存储方式由实现者定（UserDefaults 即可）。

## 9. 稳定性（重点）【用户定】

"不能挡住"的核心是**足够稳定、不会卡死**：

- 主线程只做界面；文件读写、进程查询、AppleScript、进程链遍历全部放后台。
- 状态文件损坏、格式未知、字段缺失 → 忽略该文件或该字段，不崩溃。
- `~/.claude/sessions` 格式变化或缺失 → 降级（没有名字就用目录名，没有来源就显示"其他"），不影响核心状态显示。
- 不存在任何让宠物拖不动的模态状态。
- **卡死兜底【Claude 定】：** app 定期写心跳；`critter-hook toggle`（即 `/pet`）发现心跳过期就强制结束并重启 app。这样即使主线程卡死，`/pet` 也能把它救回来或收起来。
- app 崩溃不影响 Claude Code 会话（hooks 只写文件，不依赖 app 在线）。

## 10. 安装与分发

- **第一版：** 一条命令（`make install` 或 `./install.sh`）：
  1. `swift build -c release`
  2. 组装 `Critter.app`（`LSUIElement` 隐藏 Dock 图标），放进 `~/Applications`
  3. 安装 `critter-hook` 到固定路径（如 app 包内或 `~/.critter/bin`）
  4. 把仓库作为本地插件市场添加并安装 `critter` 插件（hooks + `/pet`）
- 同时提供卸载命令（移除 app、插件、`~/.critter`）。
- **以后开源：** 仓库同时是插件市场；app 用源码编译或 Homebrew formula；需要预编译包时再加 Developer ID 签名 + 公证（可在 GitHub Actions 里自动化）。

## 11. 需要先实测的风险点（建议作为实现的第一步）

1. **`/pet` 不触发模型回复**是否可行（§7 首选方案）。
2. **Desktop App Code 页：** 插件 hooks 是否触发；是否写 `~/.claude/sessions/<pid>.json`、`entrypoint` 值；关闭会话是否结束 claude 进程；能否深链到具体会话。
3. **2.1.301 上各事件的实际 payload：** `PermissionRequest`、`Notification` 子类型、`Stop`（是否带最后一条回复）、`StopFailure`、`SessionEnd`。
4. **VS Code：** 关闭 Claude 面板是否触发 `SessionEnd` / 结束进程。
5. **透明区域点击穿透**在 NSPanel 上的可靠实现。
6. **内存实测**是否在 50 MB 以内。

实测结论若推翻本文的某个假设，先回来跟用户确认再改方向。下面是预先定好的退路，**【Claude 定】**：

- **Desktop 里插件 hooks 不触发** → 改为把同样的 hooks 直接写进 `~/.claude/settings.json`（安装脚本负责写入和卸载时移除），架构不变。
- **Desktop 里连 settings.json 的 hooks 也不触发** → 第一版降级：Desktop 会话只靠 `~/.claude/sessions` 发现，显示为空闲并提示"该来源暂不支持实时状态"，点击只激活 Claude.app。第一版**不**加读取会话记录 JSONL 的第二套状态来源，保持 hook→状态文件这一条跨平台契约。
- **Desktop 不支持深链到具体会话** → 只激活 Claude.app。
- **`/pet` 在某个模式里做不到不触发模型** → 用兜底方案（§7）；兜底也不行时，该模式下靠全局快捷键和菜单栏，不阻塞第一版。

## 12. 留给实现者的决定

- hooks 用 async 还是同步 + 短超时（满足不拖慢 + 乱序安全即可）。
- 状态文件的具体字段增补、目录监听的实现方式。
- `critter-hook toggle` ↔ app 的通信方式。
- 气泡排版、增删会话时的伸缩方向。
- 动画清单的具体格式。
- 跳回窗口各来源的具体实现手段。
- 设置存储方式。
- UI 框架搭配（AppKit 窗口 + SwiftUI 视图等）。

## 13. 验收标准（第一版）

1. 终端、VS Code、Desktop 三处各开一个会话，三只 Critter 都出现，来源标签正确（Desktop 视 §11 实测结果而定）。
2. 在任一会话里：提交提示 → 运行中；触发权限确认 → 等你确认；回答完成 → 做完了；API 出错 → 出错。状态与气泡持续保留直到下一次变化。
3. 开 5 个会话自动合并；点击展开、点"收起"合并；合并时有动画。
4. 点击 Critter 跳回正确的窗口（VS Code 窗口、Terminal/iTerm2 标签页精确，其它终端至少激活 app）。
5. `/exit` 关会话、直接关终端窗口、`kill -9` claude 进程，三种情况下 Critter 都在几秒内离开；右键"关闭"可手动移除。
6. 三处 `/pet` 都能显示/隐藏；app 未运行时 `/pet` 能拉起。
7. 设置页各项生效，大小可调，提示音（系统音效占位）按开关工作。
8. 活动监视器"内存"一栏 ≤ 50 MB（5 个会话、展开、有动画时测）；空闲 CPU 接近 0。
9. 人为让 app 卡住（调试开关），`/pet` 能把它强制重启或收起。
