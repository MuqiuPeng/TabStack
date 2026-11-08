# TabStack for Windows

Mac 版的 Windows 移植，需求与分期见 [docs/windows-port.md](../docs/windows-port.md)。当前完成 **P0** 和 **P1** 主体（布局快照/恢复、平铺与并排、设置窗口）。

## 构建与运行

需要 .NET SDK 8 或更高（目标框架 `net8.0`，x64）。

```bash
cd windows
dotnet build
dotnet test
src/TabStack.App/bin/Debug/net8.0-windows10.0.19041.0/TabStack.exe
```

## 工程结构

| 项目 | 职责 |
|---|---|
| `TabStack.Core` | 模型、Frecency、workspace 状态机、JSON 持久化、隐藏窗口账本（无 Win32） |
| `TabStack.Platform.Windows` | `IWindowPlatform` 的 Win32 实现（CsWin32）、WinEvent、AppBar、全局热键 |
| `TabStack.App` | WPF 侧边栏、托盘、看门狗进程 |
| `TabStack.Core.Tests` | xUnit，用假平台跑状态机 |

## 用法

- 侧边栏停靠在主显示器左边（AppBar，最大化窗口自动避开）。
- 顶部色块：切换 / 新建工作区。中间：当前工作区的标签，点击显示并置前；右键重命名、绑定窗口、与另一个标签并排、移到其他工作区、排序、移除。底部 `＋` 添加已打开的窗口，`⚙` 管理工作区（重命名、颜色、固定、平铺模式、删除）、设置与退出。
- **切走 / 切回**：离开时记下每个窗口的状态（普通 / 最大化 / 最小化 / 贴靠）、位置、所在显示器、DPI、叠放顺序和前台窗口，然后隐藏；回来时原样恢复。原显示器不在了或 DPI 变了，就按 DPI 比例缩放并移到最近显示器的可见区。当前工作区里窗口移动、最小化、换前台后 500ms 会自动更新快照。
- **平铺模式**（按工作区开关，`Ctrl+Alt+T`）：点标签让窗口铺满侧边栏右侧；并排的两个标签左右分屏。
- 默认热键（都可在设置里改，被占用的显示为红色）：

  | 操作 | 热键 |
  |---|---|
  | 切到第 N 个工作区 | `Ctrl+Alt+1…9` |
  | 切到第 N 个标签 | `Ctrl+Alt+Shift+1…9` |
  | 上 / 下一个标签 | `Ctrl+Alt+↑ / ↓` |
  | 上 / 下一个工作区 | `Ctrl+Alt+← / →` |
  | 把当前窗口加入工作区 | `Ctrl+Alt+Shift+A` |
  | 切换平铺模式 | `Ctrl+Alt+T` |

- 切走的窗口默认 `SW_HIDE` 隐藏；设置里可以把某些应用改为最小化。窗口被隐藏后几秒内自己关闭的应用会被自动加进这个名单。托盘菜单“显示所有隐藏的窗口”是兜底。

## 数据与崩溃恢复

都在 `%LOCALAPPDATA%\TabStack\`：

- `state.json`：工作区与标签（字段名与 Mac 版一致，另加 Windows 字段）。
- `hidden.json`：隐藏前先写入 `{hwnd, pid, 进程启动时间}`。启动时会把仍存在的窗口全部显示；另有一个 `TabStack.exe --watchdog <pid>` 进程在主进程退出（包括被强杀）后做同样的事。
- `TabStack.log`：日志。

诊断：`TabStack.exe --describe [hwnd...] > out.json` 输出平台层看到的窗口信息。

## 已知限制

- 用模态对话框（WinForms `ShowDialog` 之类）做主窗口的程序被隐藏时会自行关闭；TabStack 会察觉并以后改为最小化它，但第一次那个窗口已经没了。
- 侧边栏只在主显示器上一个；每个显示器各一个侧边栏还没做。
- 休眠属于 P2；MCP 与浏览器扩展属于 P3。
