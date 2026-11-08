# TabStack for Windows — 需求与实现方案

> 给在 Windows 上开发的会话（人或 Claude）读的自包含文档。Mac 版（Swift）源码在 `Sources/TabStack/`，本文引用的 Swift 文件仅作行为参考，Windows 版不共享代码。

## 0. 背景：Mac 版做了什么

TabStack 是贴在屏幕左边的侧边栏，把窗口分组成 **workspace**（工作区），一个 **tab** = 一个具体窗口（同一个 Chrome 可以占多个 tab）。

Mac 版行为（参考 `WorkspaceManager.swift`）：
- 点 tab：把该窗口铺满"屏幕减去侧边栏/菜单栏/Dock"的区域并置前（`place()` / `frame(for:)`），可两个 tab 左右并排（`pairedWith`，宽屏）。
- 切 workspace：隐藏上一个 workspace 的整个 app（`NSRunningApplication.hide()`），恢复新 workspace 上次选中的 tab（`switchWorkspace`）。
- 窗口关闭或 app 重启后 tab 变为"未绑定"，下次用到时按标题或空闲窗口重新绑定；还能按 `Reopen` 配方（项目文件夹 / 浏览器所有标签页 URL / 文档路径）重开窗口（`Restore.swift`）。
- 侧边栏只显示少数 workspace，按 Frecency（使用频次 + 半衰期 3 天）排序；其余靠搜索（`WorkspaceSearch.swift`）。
- 多显示器：每个显示器一个侧边栏、各显示一个 workspace（`assignDisplays`）。
- 热键（`HotKeys.swift`）、快速添加（`QuickAdd.swift`）、设置窗口（`SettingsWindow.swift`）。
- 控制接口：本地 socket 上的 JSON 行协议（`ControlServer.swift`），`tabstack-mcp` 把它包装成 MCP 工具：`list_workspaces, list_windows, list_browser_profiles, create_workspace, update_workspace, delete_workspace, switch_workspace, add_window, open_window, update_tab, remove_tab, restore_workspace`。
- 数据持久化为 JSON（`load()` / `save()`），模型见 `AppTab` / `Workspace` / `Reopen`。

## 1. Windows 版与 Mac 版的需求差异

1. **Windows 上窗口大多不是全屏**：离开 workspace 时要记录其中**展示了哪些窗口**、**每个窗口的位置/大小/状态**和**叠放顺序**；回来时原样恢复。
2. **Windows 内存压力大**：非激活的 workspace 要分级**休眠**以释放资源。

其余功能（tab/workspace 概念、Frecency、搜索、快速添加、多显示器、MCP 控制）尽量与 Mac 版对齐。

## 2. 技术选型（已定）

- **C# / .NET 8**，UI 用 **WPF**，Win32 调用用 **CsWin32**（`Microsoft.Windows.CsWin32` 源生成器）。
- 进程 DPI 感知：**Per-Monitor V2**（app.manifest）。
- 最低系统：Windows 10 22H2 / Windows 11。

### 工程结构（放在仓库 `windows/` 下）

| 项目 | 职责 |
|---|---|
| `TabStack.Core` | 纯逻辑、无 Win32：模型、Frecency、workspace 状态机、休眠策略、JSON 持久化 |
| `TabStack.Platform.Windows` | `IWindowPlatform` 实现：窗口枚举/身份、placement 读写、显示/隐藏、WinEvent 订阅、进程控制、崩溃恢复 |
| `TabStack.App` | WPF：AppBar 侧边栏、托盘图标、全局热键、搜索/快速添加/设置窗口 |
| `TabStack.Mcp` | MCP stdio 服务器，经**命名管道** `\\.\pipe\TabStack-<user>` 与 App 通信，协议与 Mac 版 JSON 行协议一致 |
| `TabStack.Core.Tests` | xUnit，可在任何平台跑 |

Core 不得引用 Platform；Platform 通过接口注入，以便单测用假实现。

## 3. 数据模型（JSON 尽量与 Mac 字段同名）

```jsonc
Workspace {
  id, name, tabs: [AppTab], lastTabID, color, pinned, usage: [double],
  // 新增
  zOrder: [tabID],            // 离开时从上到下的叠放顺序（仅可见窗口）
  foregroundTab: tabID?,      // 离开时的前台窗口
  sleep: { level: "awake"|"throttled"|"closed", since: double }?,
  noSleep: bool?              // 用户禁止休眠
}
AppTab {
  id, appID, name, customName, title, reopen, pairedWith, shared,
  // appID：Mac 的 bundleID 在 Windows 上 = AUMID（若有）否则 exe 完整路径（小写）
  hwnd: long?,                // 运行期句柄，等同 Mac windowID
  className: string?,         // 用于重绑定
  placement: {
    state: "normal"|"maximized"|"minimized"|"snapped",
    normalRect: {x,y,w,h},    // GetWindowPlacement.rcNormalPosition（换算为屏幕坐标）
    actualRect: {x,y,w,h},    // GetWindowRect（snapped 时以此为准）
    monitor: string,          // 显示器设备路径（DISPLAYCONFIG target 的 monitorDevicePath）
    dpi: int,
    visible: bool             // 离开时是否展示（非最小化、非被我们隐藏）
  }?,
  noSleep: bool?
}
```

## 4. 平台层要点

### 4.1 收起其他 workspace
- **默认：`ShowWindow(SW_HIDE)`**（无动画、任务栏干净，最接近 Mac 的 app hide）。按 app 可配置回退为**最小化**（遇到不兼容 SW_HIDE 的应用）。
- **崩溃恢复（必须）**：每次隐藏前把 `{hwnd, pid, 进程启动时间}` 追加写入 `%LOCALAPPDATA%\TabStack\hidden.json`；正常显示后移除。App 启动时、以及一个轻量看门狗进程检测到主进程退出时，把仍存在的句柄全部 `SW_SHOWNOACTIVATE`。托盘菜单提供"显示所有窗口"。
- 不使用系统虚拟桌面（无公开 API 移动他进程窗口）。

### 4.2 窗口身份与过滤
- 只管理"任务栏级"顶层窗口：可见、无 owner、非 `WS_EX_TOOLWINDOW`、非 cloaked（`DWMWA_CLOAKED`）、有标题。
- UWP：`ApplicationFrameWindow` 需取其子 `CoreWindow` 的真实进程/AUMID。
- 进程 exe 路径：`QueryFullProcessImageName`；AUMID：`SHGetPropertyStoreForWindow` → `PKEY_AppUserModel_ID`。
- 提权窗口（UIPI）无法操作：检测到后在 tab 上显示锁标记，不报错。
- 重绑定规则沿用 Mac：同 appID 下优先标题匹配，否则取未被其他 tab 占用的窗口。

### 4.3 事件
`SetWinEventHook`（out-of-context）：`EVENT_OBJECT_CREATE/DESTROY/SHOW/HIDE`、`EVENT_OBJECT_NAMECHANGE`（标题）、`EVENT_SYSTEM_FOREGROUND`、`EVENT_SYSTEM_MOVESIZEEND`、`EVENT_SYSTEM_MINIMIZESTART/END`。注意过滤掉我们自己触发的 SHOW/HIDE。

### 4.4 侧边栏
- 用 **AppBar**（`SHAppBarMessage ABM_NEW / ABM_SETPOS`）占住左边缘，最大化窗口自动避开。每个显示器一个。
- 侧边栏点击要能把别的窗口设为前台：注意 `SetForegroundWindow` 前台锁；侧边栏若用 `WS_EX_NOACTIVATE` 需实测，必要时在点击时短暂激活自己再切。
- 热键用 `RegisterHotKey`。Mac 的 ⌃⌥ 映射为 **Ctrl+Alt**，⌥⌘ 映射为 **Win+Alt**（避开系统占用，最终以实测冲突为准，可在设置里改）。

## 5. 需求 1：布局快照与恢复

### 5.1 离开 workspace 时（在隐藏前执行）
1. `EnumWindows`（顺序即 Z 序从上到下）→ 过滤出本 workspace 的 tab 窗口 → 得到 `zOrder`。
2. 每个窗口：`GetWindowPlacement` 得 state 与 `rcNormalPosition`；`GetWindowRect` 得实际矩形。
   - `rcNormalPosition` 是**工作区坐标**，需加上所在显示器 work area 偏移转成屏幕坐标。
   - **Snap 检测**：非最大化、非最小化，且实际矩形 ≠ normalRect → `state = snapped`，以 `actualRect` 为准。
3. 记录显示器设备路径和 DPI（`GetDpiForWindow`）。
4. `foregroundTab` = `GetForegroundWindow` 对应的 tab。
5. 保存，然后隐藏。

### 5.2 持续记录（兜底，防崩溃丢布局）
当前 workspace 内收到 MOVESIZEEND / MINIMIZE / FOREGROUND 事件时，防抖 500ms 更新该 workspace 快照。

### 5.3 回到 workspace
1. 显示器校验：原显示器不存在或分辨率变化 → `MonitorFromRect(MONITOR_DEFAULTTONEAREST)` 夹回可见区，并按 DPI 比例换算尺寸。
2. 按 `zOrder` **从下到上**：`SetWindowPlacement`（normal/maximized/minimized）或 `SetWindowPos`（snapped），用 `BeginDeferWindowPos` 批量提交，避免闪烁；`visible=false` 的保持最小化/隐藏。
3. 最后激活 `foregroundTab`。
4. 窗口已不存在 → 走重绑定 / Reopen 恢复（见 6.3），恢复后再套用 placement。

### 5.4 tab 点击行为
- **默认（自由模式）**：点 tab = 显示并置前该窗口，保持其自身位置。
- **平铺模式（可选，等同 Mac）**：铺满侧边栏右侧区域；宽屏可左右并排。按 workspace 设置。

## 6. 需求 2：非激活 workspace 休眠

### 6.1 分级
| 级别 | 做法 | 默认 |
|---|---|---|
| L1 throttled | `SetProcessInformation(ProcessPowerThrottling, EXECUTION_SPEED)`（EcoQoS）+ `IDLE_PRIORITY_CLASS`；唤醒时还原 | 开 |
| L4 closed | 先抓 Reopen 配方，再 `WM_CLOSE`；唤醒时按配方重开 | **仅内存压力时**触发，且只对白名单 app |
| L5 浏览器丢弃 | 浏览器扩展调 `chrome.tabs.discard`，经 Native Messaging 与 TabStack 通信 | 装了扩展才有（P3） |

不做：`EmptyWorkingSet`（只是挪到页面文件、回来卡顿）、`NtSuspendProcess`（窗口"未响应"、多进程 app 的进程间通信会断）。

### 6.2 何时可以休眠一个进程
**进程级约束**：该进程的所有 tab 窗口都属于休眠候选 workspace 才能动。以下一律跳过：当前或其他显示器正在显示的 workspace 用到的进程、`shared` tab、`noSleep`、提权进程、正在播放音频（`IAudioSessionManager2` 枚举活跃会话）。

### 6.3 触发策略
- 最近使用的 **K=3** 个 workspace 与 pinned 的保持唤醒。
- 离开超过 **N=15 分钟** → L1。
- 内存压力（`CreateMemoryResourceNotification(LowMemoryResourceNotification)` 或 `GlobalMemoryStatusEx.dwMemoryLoad > 80%`）→ 按 Frecency 从低到高对候选执行 L4/L5，直到压力解除。
- K、N、阈值、L4 开关都放进设置。

### 6.4 L4 白名单与配方（移植 `Restore.swift`）
| App | 抓取 | 重开 |
|---|---|---|
| VS Code / Insiders / VSCodium / Cursor | 窗口标题末段 + `%APPDATA%\Code\User\globalStorage\storage.json` 的 `windowsState` 得项目文件夹 | `code.exe --new-window <folder>`（hot exit 保留未保存内容） |
| 文件资源管理器 | Shell COM `IShellWindows` 取每个窗口路径 | `explorer.exe <path>` |
| Chromium 浏览器 | **需扩展**上报每个窗口的所有 URL（Windows 无 AppleScript） | `chrome.exe --new-window url1 url2 ...`（带 `--profile-directory`） |
| 其他 | — | 不关闭，只做 L1 |

### 6.5 唤醒
切回时先恢复目标 tab（L4 的先重开它），其余窗口后台重开，全部就位后套用第 5 节的快照。侧边栏中休眠的 workspace/tab 图标置灰并加月亮标记。

## 7. 分期与验收

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0** | 解决方案骨架；Core 模型 + Frecency（附单测）；`IWindowPlatform` + 窗口枚举/身份；AppBar 侧边栏显示 workspace/tab；切 workspace = SW_HIDE/SW_SHOW；崩溃恢复 | 两个 workspace 来回切，窗口正确隐藏/显示；强杀 TabStack 后重启，所有被隐藏窗口回来 |
| **P1** | 布局快照/恢复、持续记录、多显示器与 DPI、snap、自由/平铺模式 | 在两块不同 DPI 的显示器上摆好普通、最大化、最小化、贴靠窗口，切走再切回，位置、状态、叠放顺序和前台窗口都一致；拔掉一块显示器后窗口落回可见区 |
| **P2** | 休眠 L1 + L4（VS Code、资源管理器）+ 触发策略 + 设置项 + 侧边栏状态 | 任务管理器可见进程进入效率模式；模拟内存压力后 VS Code 窗口被关闭、切回后重开到同一文件夹且位置正确 |
| **P3** | 浏览器扩展（标签页丢弃 + URL 上报）；MCP 服务器经命名管道 | 浏览器 workspace 休眠后内存明显下降、切回标签页齐全；MCP 工具列表与 Mac 版一致 |

每个阶段结束：`dotnet build` 无警告、`dotnet test` 通过、在真实 Windows 上手动走一遍验收。

### 进度

- **P0 完成**（2026-11-08，分支 `feat/windows-p0`）：28 个 Core 单测通过；实机验收两个 workspace 来回切换隐藏/显示正确、强杀后看门狗恢复隐藏窗口、重启后标签仍绑定原窗口、正常退出时恢复所有隐藏窗口。
  - 实测发现：本机 `Win+Alt+1…9` 和 `Ctrl+Alt+A` 已被其他程序占用（注册失败记入日志），热键需要在设置里可改（P1 设置窗口）。
  - 实测发现：以模态对话框为主窗口的程序被 `SW_HIDE` 后会自行关闭，"按 app 回退为最小化"需要尽早做。
  - 侧边栏用 `WS_EX_NOACTIVATE`，但 WPF 弹出菜单要求所属窗口处于激活状态，所以打开菜单时临时激活侧边栏、关闭后把前台还给原窗口。

- **P1 主体完成**（同一分支）：39 个 Core 单测通过；实机验收：
  - 离开前 A 在副屏 (DISPLAY2)、B 最大化、C 前台、D 最小化；切走后用脚本把它们挪动/还原/最小化打乱，切回后 4 个窗口的状态、normalRect、显示器全部与离开前一致，前台回到 C，可见窗口叠放顺序 C→B→A 一致（最小化窗口不参与叠放）。
  - 平铺模式下窗口可见边框正好贴住侧边栏右侧工作区（补偿了 Win11 隐形边框 7px）。
  - 设置窗口改热键、保存后重新注册；`Ctrl+Alt+2` 实测切换成功。
  - `rcNormalPosition` 按所在显示器工作区偏移换算（AppBar 占 64px 时实测与 GetWindowRect 一致）。
  - 未做实机验证：Aero Snap 贴靠窗口的恢复（逻辑有单测）、不同 DPI 的两块显示器（本机两块都是 96 DPI，DPI 换算有单测）、拔显示器、平铺并排的界面操作（逻辑有单测）。
  - 显示器以 `\\.\DISPLAYn` 设备名标识（不是文档原定的 DISPLAYCONFIG monitorDevicePath），重插后编号可能变化；Fit 时设备名不匹配会按矩形重叠找最近显示器，所以只影响"是否需要搬家"的判断。
  - 侧边栏仍只在主显示器上一个；"每个显示器一个侧边栏、各显示一个 workspace"留到后面。
- 热键默认值调整（实测冲突）：标签 `Ctrl+Alt+Shift+1…9`（`Win+Alt+数字` 是系统任务栏跳转列表）、加入窗口 `Ctrl+Alt+Shift+A`（`Ctrl+Alt+A` 常被 QQ/TIM/微信截图占用）、新增 `Ctrl+Alt+T` 切换平铺。全部可在设置里改，被占用的显示为红色。
- "按 app 回退为最小化"已做：设置里可手动维护名单；窗口在被隐藏后 3 秒内自己销毁时自动把该应用加入名单并弹托盘通知（已丢的那个窗口救不回来）。

## 8. 待用户确认（已给默认值，可改）
- 收起方式默认 SW_HIDE（按 app 可回退为最小化）。
- L4 默认只在内存压力时触发。
- 热键映射（Ctrl+Alt / Ctrl+Alt+Shift，见进度说明）。
