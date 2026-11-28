---
id: T-0024
title: 全屏 Space 上只更新高亮：留下的取舍和没测到的切换方式
status: todo
priority: P3
type: chore
labels: [fullscreen, focus]
created: 2026-11-28T12:22+11:00
updated: 2026-11-28T12:22+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session:
depends_on: [T-0023]
files: [Sources/TabStack/WorkspaceManager.swift]
---

T-0023 让 `applyFocus` 在焦点窗口是全屏窗口时只更新侧边栏高亮。这样做有几处取舍，另外还有没测到的场景：

- 全屏窗口属于另一个工作区时，不再自动跟到那个工作区（以前会 followFocus），侧边栏高亮会清掉。回到桌面后，按当时的焦点照常处理
- ⌘Tab / 点 Dock 到某个应用时，如果 macOS 自己跳到了它的全屏 Space（全屏窗口是它的主窗口），TabStack 不再把本工作区里该应用的普通窗口拉出来，而是停在全屏 Space 上
- 焦点在全屏窗口上时，不再抓取链接（catchLink），也不再同步 Claude 会话
- 没有自动化测过：调度中心里点 Space 缩略图、触控板三指滑动、多显示器（全屏窗口在第二块屏上）。按代码这些都走同一个应用激活 → applyFocus 的路径，但没实测
- 没有处理“切到全屏 Space 时 AX 报的焦点窗口滞后、还是桌面窗口”的情况：复现时没遇到

## 验收标准
- [ ] 用户确认上面三条行为取舍可以接受，或者改成想要的样子
- [ ] 实测调度中心点选、三指滑动、多显示器下切到全屏 Space 都不会被切回
- [ ] 如果遇到焦点滞后导致的回切，加“焦点窗口不在屏幕上就先不处理”之类的保护

## 日志
- 2026-11-28 12:22 · local_ab31746c · 创建
