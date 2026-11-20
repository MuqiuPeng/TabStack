---
id: T-0004
title: Windows 移植：评审 feat/windows-p0 和 docs/windows-port，完成 P2 后合并
status: doing
priority: P1
type: feature
labels: [windows, backlog-audit]
created: 2026-11-09T16:11+11:00
updated: 2026-11-21T01:34+11:00
created_by: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
session:
depends_on: []
files: []
---

`feat/windows-p0`（P0 工作区 + P1 布局恢复 + 每屏一个侧边栏，最新提交 2026-11-08）和 `docs/windows-port` 都还没进 main；P2（非激活工作区休眠）尚未开始。推送身份问题：现在用 MuqiuPeng 自己的 token 可以推送。

来自会话：`local_abea2ec9…`

## 验收标准
- [ ] 两个分支已评审
- [ ] P2 完成
- [ ] 已合并进 main

## 日志
- 2026-11-09 16:11 · local_b791c3a6 · 创建
- 2026-11-21 01:34 · user · 状态 → 进行中
- 2026-11-21 01:34 · user · 进度：P0、P1 完成，另有托盘窗口、版本目录 appID、开机自启、Ctrl+Alt+T 工单面板等（见 docs/windows-port.md 第 7 节进度）。尚缺：P2 休眠整段（L1、L4 及其依赖的 Reopen 配方、触发策略、设置项、侧边栏状态）；P3 的 MCP 服务器与浏览器扩展；跟进 main 的 038642e（切换工作区延后整理窗口、后台最小化）；windows/README.md 过时需重写。
