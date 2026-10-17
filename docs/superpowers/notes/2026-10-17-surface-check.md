# 三种模式端到端验收记录（Task 16）

日期：2026-10-17。版本 0.2.0，Claude Code 2.1.301（CLI）/ 2.1.300（VS Code）/ 2.1.295（Desktop 内置）。证据来自 `~/.critter/hook.log` 与 `~/.critter/app.log`（诊断日志）以及用户目测。

| 模式 | 结果 | 证据 |
|---|---|---|
| 终端（Terminal.app） | 通过 | 用户确认：开会话出现、关闭后离开、状态正确。日志：SessionStart→idle、UserPromptSubmit→running、Stop→done（播放 Glass）、SessionEnd→delete；点击 → `plan=terminalTab tty=/dev/ttys004`，`script found`（选中正确标签页）；展开/收起正常。 |
| Claude Desktop（Code 页） | 部分通过 | 插件 hooks 会触发，来源标签正确，状态流转正确，点击 → `opened Claude.app`。**关掉对话不会结束 claude 进程**，Critter 不会自动离开；要等退出 Desktop（此时 SessionEnd 才到）或右键「关闭」。用户接受，已写入 README 已知限制。 |
| VS Code 插件 | 用户判定通过（未逐项实测） | 与终端共用同一套 hooks 和机制；写入 README 已知限制。 |

spec §11 风险点结论：
1. `/pet` 不触发模型：CLI 实测可行（Batch C）。
2. Desktop：hooks 触发 ✅；`~/.claude/sessions` 记录与 `entrypoint` 正确（来源显示正确）✅；关闭对话不结束进程 ❌（已知限制）；深链到具体会话：未实现，只激活 Claude.app。
3. 各事件 payload：已在 CLI spike 中确认。
4. VS Code 关闭面板：未实测。
5. 透明区域点击穿透：用户使用中未反馈问题。
6. 内存：5 个会话约 21 MB footprint，CPU ≈ 0。
