---
id: T-0023
title: 切到全屏窗口所在的 Space 时，TabStack 去动普通桌面上的窗口，把桌面切回去
status: review
priority: P1
type: bug
labels: [fullscreen, focus, space]
created: 2026-11-28T12:10+11:00
updated: 2026-11-28T12:22+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session: local_ab31746c-041c-4267-837b-8da23617733d
depends_on: []
files: [Sources/TabStack/WorkspaceManager.swift, Sources/TabStack/AppDelegate.swift, Sources/TabStack/AX.swift]
---

接着 T-0014 的全屏修复。用户原话：「当一个应用的子窗口被全屏化进入另一个桌面的时候，不应该在切到对应的桌面时自动切换其他桌面tabstack上的窗口，因为这样会导致桌面切回」

场景：某个应用的一个窗口（比如 Chrome 的其中一个窗口）进了原生全屏，有了自己的 Space。用户切到这个 Space 时（三指滑动、调度中心、⌃→ 或点它的标签），TabStack 对普通桌面上的窗口做了显示 / 置前 / 取消隐藏 / 切换工作区之类的操作，macOS 就跟着把桌面切回去了。

怀疑点（待复现和日志确认）：`applyFocus` 的 `activation` 分支（⌘Tab / Dock 时改成显示当前工作区里该应用的窗口）、`followFocus` 切工作区、`AppDelegate` 里 `activeSpaceDidChangeNotification` 的处理。

## 验收标准
- [ ] 三指滑动、调度中心、⌃→、点它的标签这几种方式切到全屏 Space，都停在那个 Space 上，不被切回；TabStack 只更新侧边栏高亮
- [ ] 从全屏 Space 切回普通桌面、⌘Tab、点 Dock、焦点跟随，这些照常
- [ ] 真机实测 Chrome，再测一个非浏览器应用
- [ ] 保留 T-0014 和 T-0018 尚未提交的改动

## 日志
- 2026-11-28 12:10 · local_ab31746c · 创建
- 2026-11-28 12:10 · local_ab31746c · 状态 → 进行中, 认领会话 → local_ab31746c-041c-4267-837b-8da23617733d — 认领
- 2026-11-28 12:22 · local_ab31746c · 根因（加 SPDBG 日志复现确认）：切到全屏 Space 时该应用被激活，applyFocus 收到 activation=true、焦点窗口就是全屏窗口（fs=true）。全屏窗口不是当前工作区的 tab 时，走进 activation 分支（原本给 ⌘Tab/Dock 用的“显示本工作区里该应用的窗口”），select 了普通桌面上的同应用窗口，place 时 raise+activate，macOS 随即把 Space 切回桌面。日志：applyFocus com.google.Chrome wid=16384 fs=true activation=true inTabs=no → activation -> select Chrome · 关舜 → place … fs=false → space 882→3。全屏窗口属于另一个工作区时同样会进这一支；当前工作区没有该应用的 tab 时则会走 followFocus 切工作区。AppDelegate 的 activeSpaceDidChange 只处理侧边栏显示，日志里没看到它动窗口。
- 2026-11-28 12:22 · local_ab31746c · 改动（WorkspaceManager.swift，未提交，T-0014/T-0018 及 AppDelegate 里别的会话的改动都保留）：applyFocus 拿到焦点窗口后，如果它是全屏窗口，只做 focusDisplay（纯状态）和新加的 highlightOnly（是本工作区的 tab 就移高亮，否则清掉高亮），然后返回，不再 place / select / followFocus / catchLink / 同步 Claude 会话。真机测试（build.sh 编译后，临时工作区已删除、测试窗口已关）：⌃→ 从桌面滑到别的工作区的全屏 Chrome、本工作区的全屏 TextEdit，在两个全屏 Space 之间来回滑，都停在原 Space 上（修复前会被切回桌面）；⌃← 回到桌面后照常 place；点全屏窗口的 tab（本工作区内和跨工作区）都切到并停在它的 Space；类似 Dock 的激活（open -a Chrome）、⌘Tab、焦点跟随（焦点到 B 的 Finder 窗口自动切到 B）都照常。调度中心点选和触控板三指滑动没有自动化测，它们走的是同一条激活路径。
- 2026-11-28 12:22 · local_ab31746c · 状态 → 待验收 — 已修复，用 Chrome 和 TextEdit 在真机上验证过，未提交。遗留问题：T-0024（行为取舍、调度中心 / 三指滑动 / 多显示器未实测），T-0025（list_windows/add_window 看不到被缓存成“找不到”的全屏窗口）。
