---
id: T-0007
title: 重启后不恢复 Terminal：关闭系统自动拉起的 Terminal 窗口
status: review
priority: P2
type: feature
labels: [restore, restart, terminal]
created: 2026-11-10T00:30+11:00
updated: 2026-11-10T01:04+11:00
created_by: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
session: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
depends_on: [T-0006]
files: [Sources/TabStack/Restore.swift, Sources/TabStack/WorkspaceManager.swift]
---

很多工作区的 Terminal tab 都在 `~`，恢复配方只有 document（当前目录），标题也几乎相同，重启后按标题/目录匹配会分错窗口。

做法：由 TabStack 按 tab 记录的目录新开 Terminal 窗口，只认本次恢复中新出现的窗口；系统自动恢复出来、没被任何 tab 认领的窗口保持不动。

## 验收标准
- [ ] 多个 tab 目录相同时，重启后每个 tab 各自得到一个 Terminal 窗口
- [ ] 不会抢占其他 tab 已认领的窗口
- [ ] 系统恢复出的多余 Terminal 窗口不被关闭或改动

## 日志
- 2026-11-10 00:30 · local_b791c3a6 · 创建
- 2026-11-10 00:35 · local_b791c3a6 · 状态 → 进行中, 认领会话 → local_b791c3a6-453c-446f-ac97-5ad082ad2dcc — 认领
- 2026-11-10 00:35 · local_b791c3a6 · T-0006 模拟重启发现：多个都在 ~、标题完全相同的 Terminal 窗口只能按顺序分配，tab 可能拿到别的工作区原来那个终端；需要可靠的终端指纹（例如自定义标题或由 TabStack 自己开窗）才能解决。
- 2026-11-10 00:35 · local_b791c3a6 · 状态 → 待办, 认领会话 → 无 — 只是补充记录，并未开始做，退回待办。
- 2026-11-10 01:02 · local_b791c3a6 · 标题 → 重启后不恢复 Terminal：关闭系统自动拉起的 Terminal 窗口 — 按你的要求改了范围：Terminal 不再恢复；重启后系统拉起的 Terminal 窗口一律关闭；Terminal tab 只在点击时按目录开新窗口，不在后台自动恢复。
- 2026-11-10 01:02 · local_b791c3a6 · 状态 → 进行中, 认领会话 → local_b791c3a6-453c-446f-ac97-5ad082ad2dcc — 认领
- 2026-11-10 01:04 · local_b791c3a6 · 状态 → 待验收 — 已实现（未提交）：检测到重启且在开机 5 分钟内启动时，关闭开机 3 分钟内被系统拉起的 Terminal 的窗口（只关它启动后 20 秒内已有的窗口，2 分钟后停止）；清理期间 Terminal tab 不自动绑定；后台恢复跳过 Terminal tab，点击时才按目录开新窗口。已验证普通重启 TabStack 不会关任何终端（13 个前后一致）；关闭逻辑需要下次真实重启验证。
