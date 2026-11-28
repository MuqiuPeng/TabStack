---
id: T-0025
title: list_windows / add_window 看不到被扫描缓存成“找不到”的其他 Space 窗口
status: todo
priority: P3
type: bug
labels: [fullscreen, mcp]
created: 2026-11-28T12:22+11:00
updated: 2026-11-28T12:22+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session:
depends_on: []
files: [Sources/TabStack/AX.swift]
---

在测 T-0023 时发现：一个全屏的 Chrome 窗口（在自己的 Space 上，WindowServer 里存在），用 `add_window` 连续两次都报 “no open window”。把它退出全屏、回到当前桌面后马上就能加。

原因：`AX.windowsIncludingHidden` 扫描完一轮没找到的窗口 id 会记进 `unresolved`，之后不再查找，除非又出现新的窗口 id。窗口进入全屏的动画期间可能正好扫不到，于是一直被当成“没有 AX 元素”。T-0014 给按 id 找 tab 窗口的路径加了 `wanted` 参数绕开这个缓存，但 `AX.listedWindows`（list_windows / add_window / 侧边栏的添加窗口）没有。

## 验收标准
- [ ] `unresolved` 只记不在任何 Space 上的窗口；或者对在 Space 上的窗口隔一段时间再查一次
- [ ] 实测：Chrome 窗口全屏后，`list_windows` 能列出它，`add_window` 能加进工作区

## 日志
- 2026-11-28 12:22 · local_ab31746c · 创建
