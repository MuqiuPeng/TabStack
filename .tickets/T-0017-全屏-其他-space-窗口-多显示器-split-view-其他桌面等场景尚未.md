---
id: T-0017
title: 全屏 / 其他 Space 窗口：多显示器、Split View、其他桌面等场景尚未验证
status: todo
priority: P3
type: chore
labels: [fullscreen]
created: 2026-11-24T01:29+11:00
updated: 2026-11-24T01:29+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session:
depends_on: []
files: [Sources/TabStack/WorkspaceManager.swift, Sources/TabStack/AX.swift]
---

T-0014 修好了单显示器下单个窗口原生全屏的情况：`resolve` 对仍在某个 Space 上的窗口按 id 查找，不再重绑或重开；`place` 会 raise 全屏窗口，切到它所在的 Space。下面这些场景走的是同一套代码，但没有实测过：

- 第二块显示器上的全屏窗口（`place` 用的是 `focusedDisplay`，`raiseOtherDisplays` 会把其他显示器的窗口再提到前面）
- Split View（两个窗口并排放在同一个全屏 Space 里）
- 被手动移到另一个普通桌面（Desktop 2）的窗口：不是全屏，`place` 会对它 setFrame + raise，结果是把窗口挪回来还是切过去，目前不确定
- `.outOfReach` 的兜底：窗口还在，但约 2 秒内都拿不到 AX 元素时，只会激活 app，macOS 不一定切到正确的 Space
- Chrome 完整扫描一遍隐藏窗口（约 3400 个 element id）略超过 0.1 秒的预算，要分两次调用完成，第一次切到 Chrome 的全屏窗口时可能慢 0.1–0.2 秒

## 验收标准
- [ ] 逐个实测上面几种场景，记录结果
- [ ] 有问题的分别开工单修，或者在这里修掉

## 日志
- 2026-11-24 01:29 · local_ab31746c · 创建
