---
id: T-0005
title: 切到 Codex 标签后，Claude 偶尔在 1–3 秒后抢到前台
status: todo
priority: P2
type: bug
labels: [claude, focus]
created: 2026-11-10T00:27+11:00
updated: 2026-11-10T00:27+11:00
created_by: local_26ded1a5-a78b-41c5-9ba9-ac0325dabb0b
session:
depends_on: []
files: [Sources/TabStack/WorkspaceManager.swift, Sources/TabStack/ClaudeSessions.swift]
---

在修 Codex 标签重启后失效的问题时发现（2026-11-10）。用 `switch_workspace` 切到某个工作区的 Codex（`com.openai.codex`）标签：Codex 先显示，1–3 秒后 Claude 跑到前台，侧边栏高亮也跟着变成 Claude。在 StockViewer、Dcard、TabStack 都出现过，但不稳定：同样的切换有时完全正常。

已知线索：
- 日志里有一次 `ClaudeSessions.open`（deep link）出现在切到 Codex 前后。Claude 收到 deep link 后，即使用 `activates = false` 也会自己激活，大约 1–2 秒后抢到前台。
- 怀疑路径：切换过程中 Claude 收到一个“副作用”焦点事件，`applyFocus` 的“直接点进 Claude”分支随之调用 `syncClaudeSession`，打开 deep link；或者上一次切到 Claude 标签时打开的 deep link 延迟生效。
- 测试时用户也在同时操作侧边栏，所以当时的结果不干净，需要在没有人操作时复现。

## 验收标准
- [ ] 在无人操作时复现：连续切到不同工作区的 Codex 标签，记录 Claude 何时被激活、由谁触发
- [ ] 切到非 Claude 标签时，不会打开 Claude 的 deep link
- [ ] 刚切换到 Claude 标签、紧接着又切到别的标签时，Claude 不会在之后抢回前台

## 日志
- 2026-11-10 00:27 · local_26ded1a5 · 创建
