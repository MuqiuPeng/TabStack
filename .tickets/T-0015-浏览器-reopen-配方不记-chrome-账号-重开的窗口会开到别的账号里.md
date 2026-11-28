---
id: T-0015
title: 浏览器 Reopen 配方不记 Chrome 账号，重开的窗口会开到别的账号里
status: todo
priority: P2
type: bug
labels: [restore, browser]
created: 2026-11-24T01:29+11:00
updated: 2026-11-24T01:29+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session:
depends_on: []
files: [Sources/TabStack/Restore.swift, Sources/TabStack/WorkspaceManager.swift]
---

在修 T-0014 时发现：一个开在“关舜”账号下的 Chrome tab（标题以 “– 关舜” 结尾），按配方重开后，新窗口开到了 “Robin” 账号里（标题 “– Robin”）。

原因：`Reopen` 只存 `urls`；`Restore.perform` 用 AppleScript `make new window`，Chrome 会把窗口开在最近使用的那个账号里。`open_window` 本身支持 `profile`，但配方里没有记下来。

## 验收标准
- [ ] `captureRecipes` 记下浏览器窗口所属的账号（可以从窗口标题后缀或 Chrome 的 profile 目录判断）
- [ ] `Restore.perform` 按记下的账号重开窗口（例如 `--profile-directory`）
- [ ] 旧配方没有账号信息时，行为和现在一样
- [ ] 实测：两个账号各开一个 tab，关掉窗口后点 tab，都在原账号里重开

## 日志
- 2026-11-24 01:29 · local_ab31746c · 创建
