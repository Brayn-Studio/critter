# Clawd 桌面宠物

一只常驻在屏幕最上层的 Clawd（Claude Code 的吉祥物）。本机每个 Claude Code 会话都对应一只小 Clawd，不管会话开在终端、VS Code 还是 Claude Desktop。会话做完了、在等你确认、或者出错了，它都会换个样子、冒出气泡，还可以响一声提示音。点一下 Clawd，就能跳回那个会话所在的窗口。

这是一个原生 macOS 应用（Swift），没有任何第三方依赖。它只占大约 20 MB 内存，空闲时几乎不占 CPU。

## 它能做什么

| 状态 | 头顶 | 动作 | 气泡 |
|---|---|---|---|
| 空闲 | 灰色 `z z` | 变灰、偶尔眨眼 | 无 |
| 运行中 | 灰色 `•••` | 轻轻跳动 | 当前在做什么，例如 `Bash: npm test` |
| 等你确认 | 橙色 `?` | 摇摆 | 需要你确认的内容 |
| 做完了 | 绿色 `✓` | 轻轻呼吸 | "做完了："加上最后一条回复的第一句 |
| 出错 | 红色 `!` | 变灰 | 错误信息 |

- 每个会话一只 Clawd，排成一排。脚下的标签显示会话名和来源（终端 / VS Code / Desktop）。
- 气泡会一直显示，直到该会话的状态再次变化。超长的文字最多显示 2 行，鼠标悬停可以看到全文。
- 会话数超过合并阈值（默认 4）时，所有 Clawd 会合并成"一堆"：
  - 最前面那只显示最急的状态，上方显示各状态的数量。
  - 点这一堆可以展开；展开后末尾有"⇥ 收起"把手，点它（或右键菜单里的"收起"）再合并回去。
  - 展开后如果一排放不下（比如会话很多、屏幕较窄），会保持合并，不会有 Clawd 跑到屏幕外；这时右键菜单里的"展开"是灰的。
- 会话关闭后，对应的 Clawd 会在几秒内自己离开。三种关闭方式都算：`/exit`、直接关掉终端、`kill -9`。
- 如果它没离开，可以右键点它，选"关闭"。
- 透明的地方可以点穿到下面的窗口。整排 Clawd 可以拖到任意位置，位置会被记住。
- 显示器拔掉或分辨率变化后，宠物会自动回到屏幕内。

## 系统要求

- macOS 14 或更高版本（开发和测试用的是 macOS 27，Apple Silicon）。
- Swift 6 工具链（Xcode 或 Command Line Tools）。
- Claude Code CLI，并且 `claude` 命令在 `PATH` 里。

## 安装

```sh
make install
```

安装会做下面几件事，可以重复执行（再跑一次就是升级）：

1. 编译 release 版。
2. 把 `Clawd.app` 装进 `~/Applications`，并注册 `clawd://` URL scheme。
   - 如果 Clawd 正在运行，会自动重启，换成新版本。
3. 把 `clawd-hook` 装到 `~/.clawd/bin/`。
4. 把 `/pet` 装成用户级命令：`~/.claude/commands/pet.md`。
5. 把本仓库添加为本地插件市场（已经添加过就只刷新），并安装或更新 `clawd` 插件。插件里是上报状态用的 hooks。
   - 插件按版本号缓存在 `~/.claude/plugins/cache/clawd-pet/clawd/<版本>/`。改了 `plugin/` 里的 hooks，要同时把 `plugin/.claude-plugin/plugin.json` 和 `.claude-plugin/marketplace.json` 里的版本号加一，重新安装后才会生效。

装完后：

- **已经打开的 Claude Code 会话要重启，才会加载 hooks。** 没重启的会话仍然会出现，但标签上会多一个"·未接入"，状态一直显示为空闲。
- 在任意会话里输入 `/pet`，或者运行 `open ~/Applications/Clawd.app`，就能启动 Clawd。

## 卸载

```sh
make uninstall
```

卸载会移除插件、插件市场、`Clawd.app`（并从 Launch Services 注销 `clawd://`）、`/pet` 命令、`~/.clawd` 和开机自启项（`~/Library/LaunchAgents/local.clawd.pet.plist`）。

**卸载后请重启仍然开着的 Claude Code 会话。** 这些会话启动时已经加载了插件的 hooks，卸载后它们还会继续触发；hooks 发现 `~/.clawd/bin/clawd-hook` 不在了会直接跳过，不会报错，但要重启会话才会彻底不再调用。

设置保存在 UserDefaults 里，卸载时会保留。要一起清掉，运行 `defaults delete local.clawd.pet`。

## 使用

### 显示和隐藏

有三个入口：

- **`/pet`**：设计上终端、VS Code、Desktop 里的 Claude Code 会话都能用；目前只在终端 CLI 里实测过。
  - 它会被 hook 直接拦下，**不会触发模型回复**，你只会看到一行"Clawd 已显示"或"Clawd 已隐藏"。
  - Clawd 没在运行时，`/pet` 会先把它启动起来。
  - Clawd 卡死时，`/pet` 会把它强制重启，见下面的"稳定性"。
- **全局快捷键 ⌃⌥C**：可以在设置里改。
- **菜单栏图标**：菜单里有"显示宠物 / 隐藏宠物"、"设置…"和"退出 Clawd"。

隐藏只是把窗口收起来。Clawd 仍在菜单栏里，会话状态照常记录，但隐藏期间不会响提示音。

### 点击 Clawd

- **左键**点 Clawd 或它的气泡：跳回该会话的窗口。如果它的状态是"做完了"，同时标记为已看过，变回空闲。
- **右键**：菜单里有"跳回会话"、"关闭"、"隐藏宠物"和"设置…"。

不同来源的会话，跳回的效果不同：

| 会话在哪里 | 点击后 |
|---|---|
| Terminal.app | 前置窗口，并精确选中该会话所在的标签页（通过 AppleScript 按 tty 匹配） |
| iTerm2 | 前置窗口，并选中对应的 session（按 tty 匹配） |
| VS Code、Cursor、Windsurf、Antigravity | 打开该会话所在的工作区窗口 |
| 其它终端，例如 Ghostty、Warp | 激活该应用 |
| Claude Desktop | 激活 Claude.app |

第一次跳回 Terminal 或 iTerm2 时，macOS 会弹出"自动化"授权，问是否允许 Clawd 控制该终端，选"好"即可。

如果当时点了"不允许"，可以到 系统设置 › 隐私与安全性 › 自动化 里重新打开。没打开之前，点击只会激活终端，不会切换到对应的标签页。

### 哪些会话会显示

- 本机所有交互式 Claude Code 会话都会显示。
- `claude -p` 和 SDK 调用不会显示，这是有意的。
- 云端会话、其它机器上的会话也不会显示。

## 设置

打开方式：菜单栏图标 › 设置…，或者右键宠物 › 设置…。

| 项 | 默认 | 说明 |
|---|---|---|
| Clawd 大小 | 中（1.0） | 滑块，范围 0.5–2.0，拖动时实时生效 |
| 提示音 | 开 | 总开关 |
| 等你确认 / 做完了 / 出错 | 都开 | 只在会话**变成**这个状态时响一次；同一时刻有多个，只响最急的那个 |
| 自动合并阈值 | 4 | 会话数超过这个值就合并，范围 2–10 |
| 全局快捷键 | ⌃⌥C | 点"录制"，然后按下新的组合键。组合里必须有 ⌃、⌥ 或 ⌘；按 Esc 取消。"恢复默认"可改回 ⌃⌥C |
| 登录时自动启动 | 关 | 打开后写入 `~/Library/LaunchAgents/local.clawd.pet.plist`，下次登录时生效 |
| 重置位置 | — | 把宠物放回主屏幕右下角 |

提示音目前是**系统音效占位**：等你确认用 Ping，做完了用 Glass，出错用 Basso。以后可以换成自定义音效，不需要改调用方。

## 调试日志

```sh
touch ~/.clawd/debug    # 打开日志，不用重启
rm ~/.clawd/debug       # 关闭日志
```

打开后会写两份日志：

- **`~/.clawd/app.log`**：Clawd 应用的日志。每次显示内容变化记一行（展开或合并、每个会话的状态、窗口位置），还会记下这些事件：
  - 会话退出、被 Esc 打断、被关闭；
  - 跳回窗口的方案和结果（`jump-plan`、`jump-result`）；
  - 提示音播放或跳过的原因（`sound`）；
  - 快捷键注册结果（`hotkey register`）。
- **`~/.clawd/hook.log`**：每次 hook 调用记一行，包括事件名和处理结果。

## 稳定性

- **主线程只做界面。** 读写文件、查询进程、执行 AppleScript、播放音效都放在后台队列。
- **卡死兜底。** App 每 2 秒写一次心跳，写到 `~/.clawd/app.json`（App 已关闭 App Nap，隐藏时心跳也不会被系统推迟）。如果心跳超过 10 秒没更新，下一次 `/pet` 会先照常把请求发过去，再等最多 1.5 秒：App 回了新心跳，就只是慢了一下，不做处理；没回，才强制结束 Clawd 并重新启动它，同时提示"Clawd 无响应，已重启"。
  - 强制结束前会核对进程身份：只有可执行文件是 `…/Contents/MacOS/Clawd`、而且启动时间和 `app.json` 里记的一致，才算是 Clawd。`app.json` 里的进程号可能早已被别的程序占用（例如重启电脑后），这时 `/pet` 只会重新启动 Clawd，绝不会结束那个程序。
- **hooks 不依赖 App。** hooks 只负责写状态文件。Clawd 没运行或崩溃了，Claude Code 会话照常工作；Clawd 再次启动时，会立刻显示每个会话当前的状态。
- **坏数据不会让它崩溃。** 状态文件或 `~/.claude/sessions` 里的文件损坏、格式未知或缺字段时，Clawd 会跳过那个文件，其余会话照常显示。

## 开发

```sh
swift build            # 调试版
swift test             # 全部单元测试
make app               # 组装 dist/Clawd.app
```

两个辅助脚本：

- `scripts/demo-sessions.sh 5`：造 5 个假会话，用来看排版和动画。
  - `scripts/demo-sessions.sh set 1 waiting`：改第 1 个假会话的状态。
  - `scripts/demo-sessions.sh clean`：清掉所有假会话。
- `scripts/measure.sh [--sessions N]`：测量内存（`phys_footprint`）和平均 CPU。加了 `--sessions N` 会先造 N 个假会话，`0` 表示清空。

本机实测：5 个会话全部展开并在播放动画时，内存约 21 MB，CPU 约 0%。

目录结构：

| 目录 | 内容 |
|---|---|
| `Sources/ClawdCore` | 纯逻辑，全部有单元测试 |
| `Sources/clawd-hook` | hook 可执行文件 |
| `Sources/ClawdApp` | 菜单栏应用 |
| `plugin/` | Claude Code 插件（hooks） |
| `Skins/` | 形象素材 |

测试用的环境变量（**只用于测试，不要在日常环境里设置**）：

- `CLAWD_HOME`：替换 `~/.clawd`；`CLAUDE_CONFIG_DIR`：替换 `~/.claude`。单元测试靠它们把文件写进临时目录。
- 插件 hooks 里写死的是 `$HOME/.clawd/bin/clawd-hook`，而 `Clawd.app` 由 Launch Services 启动，拿不到 shell 里的环境变量，始终读 `~/.clawd` 和 `~/.claude`。设了这两个变量，hooks 和 App 就会各看各的目录。
- 所以 `make install` / `make uninstall` 会忽略 `CLAWD_HOME`（并给出提示），始终使用 `~/.clawd`；设了 `CLAUDE_CONFIG_DIR` 时也会提示 App 看不到那些会话。

调试开关：

- `defaults write local.clawd.pet debugEnabled -bool true` 打开下面几个调试用 URL：
  - `clawd://debug-hang`：让主线程卡死，用来测试卡死兜底；
  - `clawd://debug-click`：模拟点击；
  - `clawd://debug-set`：改设置。
- 在打开 `debugEnabled` 的基础上，再设置 `debugJumpDryRun`，跳回窗口时只记录方案，不实际执行。
- 用完后用 `defaults delete local.clawd.pet debugEnabled` 关掉。

## 已知限制

- **Claude Desktop 会话的实时状态还没在本机实测。** 插件 hooks（以及 `/pet`）是否会在 Desktop 的 Code 页触发，还有待验证；VS Code 里的 `/pet` 也还没实测。
  - 如果不触发，Desktop 会话仍会通过 `~/.claude/sessions` 被发现，但只会显示为空闲。
  - 点击这样的会话只会激活 Claude.app，不会跳到具体会话。
- **部分视觉和交互效果还没有人工验收。** 开发时用的是没有显示器的代理环境，下面这些都只用日志验证过，没有用眼睛和手确认：
  - 宠物外观和设置窗口；
  - 滑块拖动时的实时缩放；
  - 提示音是否真的听得到；
  - 快捷键实际按下的效果；
  - 跳回 Terminal 标签页和 VS Code 窗口；
  - 开机自启是否生效。
- **快捷键冲突检测有限。** macOS 没有公开接口能查出其它应用占用了哪些组合键，所以只有在注册失败时，设置页才会显示"该快捷键已被占用"。
- **跳回 iTerm2 的脚本没在本机测试过**，因为本机没装 iTerm2。
- **重装后可能要重新授权。** App 用的是本地 ad-hoc 签名，重新编译安装后，macOS 可能会再次请求"自动化"授权。
- **只支持 macOS。** 状态文件格式和 hooks 与平台无关，以后做 Windows 版只需要重写界面层。

## 品牌说明

Clawd 是 Anthropic 的吉祥物。本项目目前仅供自用；如果要开源发布，需要先遵循 Anthropic 的品牌规范，或者换成自绘的致敬版形象。

所有形象素材都只放在 `Skins/` 目录，动画也由 `Skins/clawd/manifest.json` 这份数据清单描述，所以整体替换形象不需要改代码。也可以把自定义皮肤放进 `~/.clawd/skins/clawd/`，它的优先级高于内置皮肤。
