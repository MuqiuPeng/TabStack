import SwiftUI
import AppKit

/// Owns the settings window. TabStack normally runs as a background (accessory) app; while
/// this window is open it becomes a regular app, so it shows in ⌘Tab and gets a menu bar
/// (copy/paste in text fields, ⌘W).
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let manager: WorkspaceManager
    private let model = SettingsModel()
    private var window: NSWindow?

    init(manager: WorkspaceManager) {
        self.manager = manager
    }

    /// Opens the window, optionally on one workspace.
    func show(workspace: UUID? = nil) {
        if let workspace { model.selection = workspace.uuidString }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 580),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = "TabStack 设置"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 700, height: 440)
            w.contentView = NSHostingView(rootView: SettingsView(manager: manager, model: model))
            w.center()
            w.setFrameAutosaveName("TabStackSettings")
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

final class SettingsModel: ObservableObject {
    /// "general" or a workspace id.
    @Published var selection: String? = "general"
}

struct SettingsView: View {
    @ObservedObject var manager: WorkspaceManager
    @ObservedObject var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                Label("通用", systemImage: "gearshape")
                    .tag("general")

                Section("工作区") {
                    ForEach(Array(manager.workspaces.enumerated()), id: \.element.id) { i, ws in
                        HStack(spacing: 8) {
                            WorkspaceBadge(workspace: ws, index: i, size: 20)
                            Text(ws.name.isEmpty ? "未命名" : ws.name)
                                .lineLimit(1)
                            Spacer()
                            if ws.id == manager.currentWorkspaceID {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                                    .help("当前工作区")
                            }
                            Text("\(ws.tabs.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }
                        .tag(ws.id.uuidString)
                    }
                    .onMove { manager.moveWorkspaces(from: $0, to: $1) }
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    Button { addWorkspace() } label: {
                        Image(systemName: "plus").frame(width: 22, height: 20)
                    }
                    .help("新建工作区")
                    Button { deleteSelected() } label: {
                        Image(systemName: "minus").frame(width: 22, height: 20)
                    }
                    .help("删除所选工作区")
                    .disabled(selectedWorkspaceID == nil || manager.workspaces.count < 2)
                    Spacer()
                    Text("拖动可排序")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        } detail: {
            if model.selection == "general" {
                GeneralSettings(manager: manager)
            } else if let id = selectedWorkspaceID {
                WorkspaceDetail(manager: manager, workspaceID: id)
                    .id(id)
            } else {
                Text("选择左侧的一个工作区")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var selectedWorkspaceID: UUID? {
        guard let s = model.selection, let id = UUID(uuidString: s),
              manager.workspaces.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func addWorkspace() {
        let id = manager.createWorkspace(named: "新工作区")
        model.selection = id.uuidString
    }

    private func deleteSelected() {
        guard let id = selectedWorkspaceID,
              let index = manager.workspaces.firstIndex(where: { $0.id == id }) else { return }
        manager.deleteWorkspace(id)
        if !manager.workspaces.contains(where: { $0.id == id }) {
            let next = manager.workspaces[min(index, manager.workspaces.count - 1)]
            model.selection = next.id.uuidString
        }
    }
}

// MARK: Workspace detail

private struct WorkspaceDetail: View {
    @ObservedObject var manager: WorkspaceManager
    let workspaceID: UUID

    var body: some View {
        if let index = manager.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            let ws = manager.workspaces[index]
            let others = manager.workspaces.filter { $0.id != workspaceID }

            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    WorkspaceBadge(workspace: ws, index: index, size: 48)
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("工作区名称", text: Binding(
                            get: { ws.name },
                            set: { manager.renameWorkspace(workspaceID, to: $0) }))
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .frame(maxWidth: 320)
                        HStack(spacing: 8) {
                            ForEach(WorkspaceColor.palette.indices, id: \.self) { c in
                                Circle()
                                    .fill(WorkspaceColor.palette[c])
                                    .frame(width: 18, height: 18)
                                    .overlay(Circle().stroke(Color.primary.opacity(0.7),
                                                             lineWidth: (ws.color ?? index) == c ? 2 : 0)
                                                .padding(-3))
                                    .onTapGesture { manager.setColor(workspaceID, c) }
                            }
                        }
                        .padding(.leading, 3)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if ws.id == manager.currentWorkspaceID {
                            Label("当前工作区", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.secondary)
                        } else {
                            Button("切换到此工作区") { manager.switchWorkspace(ws.id) }
                        }
                        if index < 9 {
                            Text("快捷键 ⌃⌥\(index + 1)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                HStack {
                    Text("窗口").font(.headline)
                    Text("\(ws.tabs.count) 个 · 拖动可排序")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button {
                        manager.restoreMissingWindows(in: workspaceID)
                    } label: {
                        Label("恢复缺失窗口", systemImage: "arrow.counterclockwise")
                    }
                    .help("重新打开这个工作区里已关闭的窗口（比如重启之后）")
                    Button {
                        WindowPicker.popUp(manager: manager, workspaceID: workspaceID)
                    } label: {
                        Label("添加窗口…", systemImage: "plus")
                    }
                }

                List {
                    ForEach(ws.tabs) { tab in
                        TabSettingsRow(manager: manager, tab: tab, workspaceID: workspaceID, others: others)
                    }
                    .onMove { manager.moveTabs(in: workspaceID, from: $0, to: $1) }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if ws.tabs.isEmpty {
                        Text("还没有窗口，点击“添加窗口…”")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(22)
        }
    }
}

private struct TabSettingsRow: View {
    @ObservedObject var manager: WorkspaceManager
    let tab: AppTab
    let workspaceID: UUID
    let others: [Workspace]

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: manager.icon(for: tab.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .opacity(manager.isAvailable(tab) ? 1 : 0.5)

            VStack(alignment: .leading, spacing: 2) {
                TextField("", text: Binding(
                    get: { tab.customName ?? "" },
                    set: { manager.renameTab(tab.id, to: $0) }),
                    prompt: Text(tab.title?.isEmpty == false ? tab.title! : tab.name))
                    .textFieldStyle(.plain)
                    .help("标签名称，留空则显示窗口标题")
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Menu {
                ForEach(others) { ws in
                    Button(ws.name.isEmpty ? "未命名" : ws.name) {
                        manager.moveTab(tab.id, from: workspaceID, to: ws.id)
                    }
                }
            } label: {
                Text("移到")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(others.isEmpty)

            Button {
                manager.removeTab(tab.id, from: workspaceID)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("从工作区移除")
        }
        .padding(.vertical, 3)
    }

    private var status: String {
        let state: String
        if !manager.runningIDs.contains(tab.bundleID) {
            state = "应用未运行"
        } else if manager.isBound(tab) {
            state = (tab.customName != nil && tab.title?.isEmpty == false) ? tab.title! : "窗口已绑定"
        } else if let summary = tab.reopen?.summary {
            state = "窗口未打开 · 可恢复：\(summary)"
        } else if tab.windowID == nil {
            state = "等待绑定窗口"
        } else {
            state = "窗口已关闭，下次使用时重新绑定"
        }
        var text = "\(tab.name) · \(state)"
        if manager.isBound(tab), let summary = tab.reopen?.summary { text += " · 重启后可恢复：\(summary)" }
        return text
    }
}

// MARK: General

private struct GeneralSettings: View {
    @ObservedObject var manager: WorkspaceManager
    @AppStorage("switchAnimation") private var curtain = true
    @AppStorage("restoreOnSwitch") private var restoreOnSwitch = true

    var body: some View {
        Form {
            Section("切换") {
                Toggle("切换窗口时显示磨砂过渡", isOn: $curtain)
                Text("系统开启“减弱动态效果”时，所有动画会改为淡入淡出。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("恢复") {
                Toggle("切换工作区时自动恢复缺失的窗口", isOn: $restoreOnSwitch)
                Text("TabStack 会记住每个窗口怎么重新打开：VS Code 记项目文件夹，Chrome 记所有标签页网址，文档窗口记文件。重启后会先认回已经自动恢复的窗口，真正缺失的才重新打开。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("权限") {
                HStack {
                    Label(manager.trusted ? "已获得辅助功能权限" : "未获得辅助功能权限",
                          systemImage: manager.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(manager.trusted ? .green : .orange)
                    Spacer()
                    Button("打开系统设置") { AX.openSettings() }
                }
            }

            Section("快捷键") {
                ShortcutRow(keys: "⌥⌘1 … 9", action: "切换到当前工作区的第 1–9 个窗口")
                ShortcutRow(keys: "⌃⌥↑ / ↓", action: "上一个 / 下一个窗口")
                ShortcutRow(keys: "⌃⌥1 … 9", action: "切换到第 1–9 个工作区")
                ShortcutRow(keys: "⌃⌥← / →", action: "上一个 / 下一个工作区（展开工作区总览）")
                ShortcutRow(keys: "⌥⌘0", action: "显示 / 隐藏侧边栏")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ShortcutRow: View {
    let keys: String
    let action: String

    var body: some View {
        HStack {
            Text(action)
            Spacer()
            Text(keys)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: Shared

struct WorkspaceBadge: View {
    let workspace: Workspace
    let index: Int
    let size: CGFloat

    var body: some View {
        Text(String(workspace.name.prefix(1)).uppercased())
            .font(.system(size: size * 0.45, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26)
                .fill(WorkspaceColor.color(for: workspace, fallback: index)))
    }
}
