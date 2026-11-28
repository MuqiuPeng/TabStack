---
id: T-0014
title: 窗口进入原生全屏后工作区跟丢该窗口，切回时按 Reopen 配方新开窗口
status: review
priority: P1
type: bug
labels: [fullscreen, rebind]
created: 2026-11-24T01:10+11:00
updated: 2026-11-24T01:29+11:00
created_by: local_ab31746c-041c-4267-837b-8da23617733d
session: local_ab31746c-041c-4267-837b-8da23617733d
depends_on: []
files: [Sources/TabStack/WorkspaceManager.swift, Sources/TabStack/AX.swift, Sources/TabStack/WindowWatcher.swift, Sources/TabStack/Restore.swift]
---

把工作区里的某个窗口变成 macOS 原生全屏（绿色按钮或 ⌃⌘F，窗口进入单独的 Space）后，切到别的工作区再切回来，TabStack 会按 Reopen 配方重新打开一个新窗口，而不是回到原来那个全屏窗口。

需要先用日志或实测确认 tab 是在哪一步被判成"窗口已关闭"/"未绑定"的（猜测：全屏窗口在另一个 Space，不在 on-screen 窗口列表里 / AX 枚举不到 / 窗口 id 变了），再修。

## 验收标准
- [ ] 全屏窗口在同一个工作区里一直保持绑定
- [ ] 切走再切回时回到原来那个全屏窗口（切到它所在的 Space），不新开窗口
- [ ] 退出全屏后 tab 仍然绑在原窗口上
- [ ] 切走时，全屏窗口所在的应用照常隐藏，或者至少不打乱别的工作区
- [ ] 真机实测：至少一个浏览器窗口和一个普通 app 窗口

## 日志
- 2026-11-24 01:10 · local_ab31746c · 创建
- 2026-11-24 01:11 · local_ab31746c · 状态 → 进行中, 认领会话 → local_ab31746c-041c-4267-837b-8da23617733d — 认领
- 2026-11-24 01:28 · local_ab31746c · 根因（加日志实测确认）：窗口全屏后 id 不变，WindowServer 里仍在（isBound=true，在自己的全屏 Space 上），但 AXWindows 只列当前 Space 的窗口，app 被隐藏时也不列。resolve() 只在 AX.windows(pid:) 里找 tab 的窗口，找不到就走标题匹配 → 按 Reopen 配方 startRestore，新开窗口并把 tab 绑过去。日志：resolve miss tab=FS-Chrome wid=11031 bound=true … → startRestore → bind 11031 -> 11081。另外 remote-token 扫描固定只扫到 element 2000，长时间运行的 Chrome 的新窗口在 2282 之后，扫不到。
- 2026-11-24 01:29 · local_ab31746c · 改动（未提交）：1) WorkspaceManager.resolve：tab 的窗口仍存在且在某个 Space 上时，按 id 找元素（AX.window），找不到返回新的 .outOfReach，绝不重绑或重开；被 app 关闭但保留的 ordered-out 窗口没有 Space，仍走原来的重绑/重开。2) place()：全屏窗口不调尺寸，但 AX.raise + activate，切到它所在的 Space；.outOfReach 先重试约 2 秒，仍不行就只激活 app。3) showWholeWorkspace 不再最小化别的工作区的全屏窗口（会把窗口踢出全屏）。4) AX.windowsIncludingHidden：扫描上限改成自适应（至少 2000，越过最后一个有效元素 1000），并新增 wanted 参数，被缓存成 unresolved 的目标 id 也会重新查找（窗口进入全屏的动画期间可能暂时查不到）。
- 2026-11-24 01:29 · local_ab31746c · 真机实测（build.sh 编译并重启，测试用 FS测试A/B 两个临时工作区，测完已删除并关掉测试窗口）：Chrome（绿色按钮和 AXFullScreen 两种方式）和 TextEdit 全屏后，切到 B 再切回 A 都回到原全屏 Space，窗口数不变；A 内两个全屏 tab 互相切换正常；B 里也有 Chrome 时，全屏窗口不会被最小化；在全屏 Space 上直接切走正常；用 ⌃→ 滑到全屏 Space 时自动跟到 A；退出全屏后 tab 仍绑在原窗口并被放回内容区；当前 tab 处于全屏时重启 TabStack 不再新开窗口；微信（隐藏后会销毁 AX 元素）切换正常。修复前的旧版本第一次复现时一次切换开出了 3 个 Chrome 窗口，加日志后没再复现；修复后存活的窗口不会再走重开，所以没再深查。
- 2026-11-24 01:29 · local_ab31746c · 状态 → 待验收 — 已修复并在真机上验证 Chrome 和 TextEdit 两种窗口，改动在 AX.swift 和 WorkspaceManager.swift，尚未提交。遗留问题另开了工单：T-0015（重开的浏览器窗口开到别的账号）、T-0016（同标题窗口互相串配方）、T-0017（多显示器 / Split View / 其他桌面等场景未验证）。
