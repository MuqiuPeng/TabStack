---
id: T-0013
title: Claude 重启后侧边栏图标一直是灰的
status: review
priority: P2
type: bug
labels: []
created: 2026-11-19T11:49+11:00
updated: 2026-11-19T11:49+11:00
created_by: local_26ded1a5-a78b-41c5-9ba9-ac0325dabb0b
session:
depends_on: []
files: []
---

现象：Claude 在 08:01 自己重启（多半是更新）后，TabStack 侧边栏里的 Claude 图标一直是灰的。

排查：标签已经绑到新窗口 7949，悬停提示里也没有“窗口已关闭”。而图标变灰只取决于两个条件：窗口是否存在、`runningIDs` 里有没有这个应用。所以问题应该出在 `runningIDs` 过期：它只在应用启动/退出的通知里刷新，通知可能先于 `NSWorkspace.runningApplications` 更新到达，读到的还是旧列表，之后再没有刷新。

修复：改用 KVO 监听 `runningApplications`，tick（每 2 秒）也刷新一次。

- [x] 编译并重启 TabStack
- [ ] Claude 下次自己重启后，确认图标不再变灰（重启 TabStack 本身就会清掉这个状态，这次没法当场复现）

## 日志
- 2026-11-19 11:49 · local_26ded1a5 · 创建
- 2026-11-19 11:49 · local_26ded1a5 · 状态 → 待验收
