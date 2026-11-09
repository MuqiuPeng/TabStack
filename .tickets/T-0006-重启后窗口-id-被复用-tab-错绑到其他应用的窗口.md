---
id: T-0006
title: 重启后窗口 id 被复用，tab 错绑到其他应用的窗口
status: review
priority: P1
type: bug
labels: [restore, restart]
created: 2026-11-10T00:30+11:00
updated: 2026-11-10T00:35+11:00
created_by: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
session: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
depends_on: []
files: [Sources/TabStack/WorkspaceManager.swift]
---

重启后系统从小数字重新分配 CGWindowID。EcoH2Ome、dosshpay、Career 三个工作区的 Terminal tab 重启前的窗口 id 是 103，重启后 103 恰好分给了一个 VS Code 窗口。`isBound` 只检查 id 是否存在、不检查归属应用，于是这三个 tab 一直显示已绑定，不会去找真正的 Terminal 窗口。

## 验收标准
- [ ] 判断"已绑定"时要求窗口属于该 tab 的应用
- [ ] 检测到重启（开机时间变化）时清空所有 tab 的旧窗口 id，再按指纹重新识别
- [ ] 跨工作区共享同一窗口的 tab（followers）不会因 id 复用而被带错
- [ ] 实测：三个错绑在 103 的 Terminal tab 恢复为未绑定或绑到 Terminal 窗口

## 日志
- 2026-11-10 00:30 · local_b791c3a6 · 创建
- 2026-11-10 00:30 · local_b791c3a6 · 状态 → 进行中, 认领会话 → local_b791c3a6-453c-446f-ac97-5ad082ad2dcc — 认领
- 2026-11-10 00:35 · local_b791c3a6 · 状态 → 待验收 — 已完成（未提交）：isBound 校验窗口归属应用；按 kern.boottime 检测重启，把旧窗口 id 打上 stale 位（保留共享分组）；重新识别分两轮，先标题（忽略终端尺寸）后指纹，目录指纹有歧义时不绑定。实测：三个错绑在 103 的 Terminal tab 变为未绑定；模拟重启后 81 个 tab 中 76 个自动重新绑定，剩下 5 个是没恢复的 Chrome 窗口。
