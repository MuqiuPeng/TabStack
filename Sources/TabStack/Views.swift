import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var manager: WorkspaceManager
    @Namespace private var selectionNS
    @State private var dragging: UUID?
    @State private var dragY: CGFloat = 0
    @State private var dragStartMid: CGFloat = 0
    /// Where the dragged tab's slot is now (it moves as the others make room).
    @State private var draggedMid: CGFloat = 0
    @State private var draggedHeight: CGFloat = 46
    @State private var rowFrames: [UUID: CGRect] = [:]

    /// Drag a tab up or down to reorder; a plain click still selects it.
    private func reorderGesture(_ tab: AppTab) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("tabColumn"))
            .onChanged { v in
                if dragging != tab.id {
                    let f = rowFrames[tab.id] ?? CGRect(x: 0, y: v.startLocation.y - 23, width: 52, height: 46)
                    dragging = tab.id
                    dragStartMid = f.midY
                    draggedMid = f.midY
                    draggedHeight = f.height
                }
                dragY = v.translation.height
                let y = dragStartMid + dragY
                guard let i = manager.tabs.firstIndex(of: tab) else { return }
                // Swap with a neighbor once the pointer crosses that neighbor's middle.
                var j = i
                while j + 1 < manager.tabs.count, let f = rowFrames[manager.tabs[j + 1].id], y > f.midY { j += 1 }
                if j == i {
                    while j - 1 >= 0, let f = rowFrames[manager.tabs[j - 1].id], y < f.midY { j -= 1 }
                }
                guard j != i, let f = rowFrames[manager.tabs[j].id] else { return }
                draggedMid = j > i ? f.maxY - draggedHeight / 2 : f.minY + draggedHeight / 2
                withAnimation(Motion.selection) { manager.moveTab(tab.id, onto: manager.tabs[j].id) }
            }
            .onEnded { _ in
                withAnimation(Motion.selection) { dragging = nil; dragY = 0 }
            }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            WorkspaceMenu(manager: manager)
                .padding(.top, 10)

            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 36, height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                ZStack(alignment: .top) {
                    tabColumn
                        .id(manager.currentWorkspaceID)
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Motion.page, value: manager.currentWorkspaceID)

            if !manager.trusted {
                Button { AX.openSettings() } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .frame(width: 40, height: 28)
                }
                .buttonStyle(.plain)
                .help("需要“辅助功能”权限，点击打开系统设置")
                .transition(.opacity)
            }

            SettingsMenuButton(manager: manager)

            Spacer().frame(height: 6)
        }
        .animation(.easeInOut(duration: 0.2), value: manager.trusted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
        }
    }

    private var tabColumn: some View {
        VStack(spacing: 6) {
            ForEach(Array(manager.tabs.enumerated()), id: \.element.id) { index, tab in
                let isDragged = dragging == tab.id
                TabButton(manager: manager, tab: tab, index: index,
                          selectionNS: selectionNS, reduceMotion: reduceMotion)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowFrameKey.self, value: [tab.id: g.frame(in: .named("tabColumn"))])
                    })
                    // The dragged tab follows the pointer; the others slide into the gap.
                    .scaleEffect(isDragged ? 1.08 : 1)
                    .shadow(color: .black.opacity(isDragged ? 0.3 : 0), radius: 6, y: 2)
                    .offset(y: isDragged ? dragStartMid + dragY - draggedMid : 0)
                    .zIndex(isDragged ? 1 : 0)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                    .highPriorityGesture(reorderGesture(tab))
            }
            AddMenu(manager: manager)
        }
        .padding(.vertical, 4)
        .coordinateSpace(name: "tabColumn")
        .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
        .onChange(of: manager.currentWorkspaceID) { _ in dragging = nil }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : Motion.selection, value: manager.currentID)
        .animation(Motion.selection, value: manager.tabs)
    }

    /// The incoming workspace slides in from the direction you moved (next: from below,
    /// previous: from above); the outgoing one just fades back.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let dy = CGFloat(manager.workspaceDirection) * 22
        return .asymmetric(
            insertion: .offset(y: dy).combined(with: .opacity),
            removal: .scale(scale: 0.96).combined(with: .opacity))
    }
}

private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: Workspaces

enum WorkspaceColor {
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
    static func color(at index: Int) -> Color { palette[index % palette.count] }
    static func color(for ws: Workspace, fallback index: Int) -> Color { color(at: ws.color ?? index) }
}

struct WorkspaceMenu: View {
    @ObservedObject var manager: WorkspaceManager
    @State private var hovering = false

    var body: some View {
        let current = manager.currentWorkspace
        let index = manager.workspaces.firstIndex(of: current) ?? 0

        Button { manager.onExpandSidebar?() } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(WorkspaceColor.color(for: current, fallback: index))
                    Text(String(current.name.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                        .id(current.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.5).combined(with: .opacity),
                            removal: .scale(scale: 1.4).combined(with: .opacity)))
                }
                .frame(width: 34, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(hovering ? 0.6 : 0), lineWidth: 1.5))
                .scaleEffect(hovering ? 1.06 : 1)

                Text(current.name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: Layout.sidebarWidth - 8)
                    .id(current.name)
                    .transition(.opacity)
            }
            .contentShape(Rectangle())
            .animation(Motion.page, value: current.id)
            .animation(Motion.page, value: current.color)
            .animation(Motion.page, value: current.name)
            .animation(Motion.press, value: hovering)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help("工作区：\(current.name)（点击展开所有工作区）")
    }

    /// Built with AppKit: SwiftUI's borderless Menu flattens custom labels.
    static func showMenu(_ m: WorkspaceManager) {
        let current = m.currentWorkspace
        let index = m.workspaces.firstIndex(of: current) ?? 0
        let menu = NSMenu()
        menu.autoenablesItems = false

        WorkspaceMenuItems.add(to: menu, manager: m)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("新建工作区…") { m.newWorkspace() })
        menu.addItem(ClosureMenuItem("工作区设置…") { m.onOpenSettings?(current.id) })
        menu.addItem(ClosureMenuItem("重命名“\(current.name)”…") { m.renameCurrentWorkspace() })
        menu.addItem(ClosureMenuItem("上移工作区", enabled: index > 0) { m.moveCurrentWorkspace(by: -1) })
        menu.addItem(ClosureMenuItem("下移工作区", enabled: index < m.workspaces.count - 1) { m.moveCurrentWorkspace(by: 1) })
        menu.addItem(ClosureMenuItem("删除“\(current.name)”…", enabled: m.workspaces.count > 1) { m.deleteCurrentWorkspace() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("恢复本工作区窗口") { m.restoreMissingWindows(in: current.id) })
        let toggle = ClosureMenuItem("隐藏侧边栏") { m.onToggleSidebar?() }
        toggle.keyEquivalent = "0"
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        menu.addItem(ClosureMenuItem("辅助功能设置…") { AX.openSettings() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 TabStack") { NSApp.terminate(nil) })

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Bottom of the sidebar: the workspace / settings menu.
struct SettingsMenuButton: View {
    @ObservedObject var manager: WorkspaceManager
    @State private var hovering = false

    var body: some View {
        Button { WorkspaceMenu.showMenu(manager) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .regular))
                .foregroundColor(hovering ? .primary : .secondary)
                .frame(width: 40, height: 32)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.press, value: hovering)
        .help("工作区与设置")
    }
}

/// The shown workspaces with their ⌃⌥ numbers, then the stored ones in a submenu and a
/// search entry. Shared by the sidebar's workspace menu and the menu-bar menu.
enum WorkspaceMenuItems {
    static func add(to menu: NSMenu, manager m: WorkspaceManager) {
        for (i, ws) in m.activeWorkspaces.enumerated() {
            let item = ClosureMenuItem(ws.name) { m.switchWorkspace(ws.id) }
            item.state = ws.id == m.currentWorkspaceID ? .on : .off
            if i < 9 {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = [.control, .option]
            }
            menu.addItem(item)
        }
        let stored = m.storedWorkspaces
        if !stored.isEmpty {
            let more = NSMenuItem(title: "其他工作区（\(stored.count)）", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for ws in stored { sub.addItem(ClosureMenuItem(ws.name) { m.switchWorkspace(ws.id) }) }
            more.submenu = sub
            menu.addItem(more)
        }
        let search = ClosureMenuItem("搜索工作区…") { m.onSearch?() }
        search.keyEquivalent = "f"
        search.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(search)
    }
}

/// NSMenuItem that runs a closure. Key equivalents are display-only here; the real
/// shortcuts are the global hotkeys.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() {
        // Let the menu finish closing before a modal dialog may open.
        DispatchQueue.main.async { self.handler() }
    }
}

// MARK: Tabs

struct TabButton: View {
    @ObservedObject var manager: WorkspaceManager
    let tab: AppTab
    let index: Int
    let selectionNS: Namespace.ID
    let reduceMotion: Bool
    @State private var hovering = false

    var body: some View {
        let selected = manager.currentID == tab.id
        let available = manager.isAvailable(tab)
        let running = manager.runningIDs.contains(tab.bundleID)
        let badge = manager.badge(for: tab)
        let label = manager.label(for: tab)
        // Scoped per workspace so the outgoing and incoming pages never share a highlight.
        let matchID = "selection-\(manager.currentWorkspaceID)"

        Button { manager.select(tab) } label: {
            VStack(spacing: 2) {
                Image(nsImage: manager.icon(for: tab.bundleID))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .opacity(available ? 1 : 0.45)
                    .saturation(available ? 1 : 0.3)
                    .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
                if let label {
                    Text(label)
                        .font(.system(size: 8.5))
                        .foregroundColor(selected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: 50)
                        .transition(.opacity)
                }
            }
            .frame(width: 52, height: label == nil ? 46 : 56)
            .background {
                ZStack {
                    if hovering && !selected {
                        RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.08))
                            .transition(.opacity)
                    }
                    if selected {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.28))
                            .matchedGeometryEffect(id: matchID, in: selectionNS)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 3, y: -2)
                        .transition(.scale(scale: 0.3, anchor: .center).combined(with: .opacity))
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.accentColor)
                        .frame(width: 3, height: 22)
                        .offset(x: -6)
                        .matchedGeometryEffect(id: matchID + "-bar", in: selectionNS)
                }
            }
            .contentShape(Rectangle())
            .animation(Motion.press, value: hovering)
            .animation(Motion.press, value: badge)
            .animation(.easeInOut(duration: 0.3), value: available)
            .animation(.easeInOut(duration: 0.2), value: label)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(tooltip)
        .contextMenu {
            Button("重命名…") { manager.rename(tab) }
            if running {
                Button("绑定到 \(tab.name) 当前窗口") { manager.rebindToFocusedWindow(tab) }
            }
            Divider()
            Button("上移") { manager.move(tab, by: -1) }.disabled(index == 0)
            Button("下移") { manager.move(tab, by: 1) }.disabled(index == manager.tabs.count - 1)
            Divider()
            if running {
                Button("退出 \(tab.name)（所有窗口）") { manager.quit(tab) }
            }
            Button("从工作区移除") { manager.remove(tab) }
        }
    }

    private var tooltip: String {
        var text = tab.name
        if let title = tab.customName ?? tab.title, !title.isEmpty, title != tab.name { text += " — \(title)" }
        if !manager.isBound(tab) {
            if manager.isRestorable(tab) { text += "（窗口未打开，点击恢复）" }
            else if manager.runningIDs.contains(tab.bundleID) && tab.windowID != nil { text += "（窗口已关闭，点击重新绑定）" }
        }
        if index < 9 { text += "   ⌥⌘\(index + 1)" }
        return text
    }
}

/// Presses in slightly and springs back, like a physical key.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduce ? 0.9 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct AddMenu: View {
    @ObservedObject var manager: WorkspaceManager

    var body: some View {
        Button { showMenu() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help("添加窗口到“\(manager.currentWorkspace.name)”")
    }

    private func showMenu() {
        WindowPicker.popUp(manager: manager, workspaceID: manager.currentWorkspaceID)
    }
}

/// Lists every running app with its windows. Built when clicked: reading windows through
/// Accessibility is too slow to do on every SwiftUI render.
enum WindowPicker {
    static func popUp(manager m: WorkspaceManager, workspaceID: UUID) {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Fresh windows of interchangeable apps (Finder, terminals, browsers).
        let fresh = NSMenuItem(title: "新建窗口", action: nil, keyEquivalent: "")
        fresh.isEnabled = false
        menu.addItem(fresh)
        for app in NewWindow.apps() {
            let icon = m.icon(for: app.bundleID).copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            let title = "新建\(app.name)窗口"
            if app.targets.count == 1, let target = app.targets.first {
                let item = ClosureMenuItem(title) { m.createWindow(target, in: workspaceID) }
                item.image = icon
                item.indentationLevel = 1
                menu.addItem(item)
            } else {
                // Browser with several profiles: pick which account the window opens in.
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = icon
                item.indentationLevel = 1
                let sub = NSMenu()
                for target in app.targets {
                    sub.addItem(ClosureMenuItem(target.profile?.label ?? app.name) {
                        m.createWindow(target, in: workspaceID)
                    })
                }
                item.submenu = sub
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())

        let existing = NSMenuItem(title: "已打开的窗口", action: nil, keyEquivalent: "")
        existing.isEnabled = false
        menu.addItem(existing)

        let apps = m.addableApps()
        if apps.isEmpty {
            let none = NSMenuItem(title: "没有可添加的窗口", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for (i, entry) in apps.enumerated() {
            let app = entry.app
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            let icon = m.icon(for: app.bundleIdentifier ?? "").copy() as! NSImage
            icon.size = NSSize(width: 16, height: 16)
            if i > 0 { menu.addItem(.separator()) }

            if entry.windows.isEmpty {
                // No window to pick: add the app, it binds to a window once one exists.
                let item = ClosureMenuItem("\(name)（无窗口）") {
                    m.addApp(app.bundleIdentifier ?? "", name: name, to: workspaceID)
                }
                item.image = icon
                menu.addItem(item)
                continue
            }

            let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            header.image = icon
            header.isEnabled = false
            menu.addItem(header)
            for w in entry.windows {
                let title = w.title.isEmpty ? "未命名窗口" : w.title
                let item = ClosureMenuItem(title.count > 60 ? String(title.prefix(60)) + "…" : title) {
                    m.addWindow(w.id, title: w.title, of: app, to: workspaceID)
                }
                item.indentationLevel = 1
                item.toolTip = w.title
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("从“应用程序”文件夹选择…") { m.chooseApplication(to: workspaceID) })

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: Expanded workspace list

/// Root of the sidebar panel: the narrow tab column, or — briefly, while switching
/// workspaces from the keyboard — a wider list of every workspace.
struct SidebarRoot: View {
    @ObservedObject var manager: WorkspaceManager

    var body: some View {
        ZStack(alignment: .leading) {
            if manager.expanded {
                WorkspaceColumns(manager: manager)
                    .transition(.opacity)
            } else {
                SidebarView(manager: manager)
                    .frame(width: Layout.sidebarWidth)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(VisualEffect())
        .onHover { manager.hoveringSidebar = $0 }
        .animation(.easeInOut(duration: Motion.reduce ? 0.1 : 0.18), value: manager.expanded)
    }
}

/// Every workspace as its own column, side by side — the narrow sidebar repeated for
/// each workspace, so ⌃⌥←/→ visibly moves left and right between them.
struct WorkspaceColumns: View {
    @ObservedObject var manager: WorkspaceManager
    @Namespace private var ns

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Layout.columnSpacing) {
                    ForEach(Array(manager.activeWorkspaces.enumerated()), id: \.element.id) { i, ws in
                        WorkspaceColumn(manager: manager, workspace: ws, index: i,
                                        current: ws.id == manager.currentWorkspaceID, ns: ns)
                            .id(ws.id)
                    }
                }
                .padding(.horizontal, Layout.columnPadding)
                .padding(.vertical, 8)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .onAppear { proxy.scrollTo(manager.currentWorkspaceID, anchor: .center) }
            .onChange(of: manager.currentWorkspaceID) { id in
                withAnimation(Motion.page) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .animation(Motion.reduce ? .easeInOut(duration: 0.12) : Motion.selection, value: manager.currentWorkspaceID)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
        }
    }
}

private struct WorkspaceColumn: View {
    @ObservedObject var manager: WorkspaceManager
    let workspace: Workspace
    let index: Int
    let current: Bool
    let ns: Namespace.ID
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 3) {
                Text(String(workspace.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(WorkspaceColor.color(for: workspace, fallback: index)))
                    .scaleEffect(current && !Motion.reduce ? 1.08 : 1)
                Text(workspace.name)
                    .font(.system(size: 9, weight: current ? .semibold : .regular))
                    .foregroundColor(current ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(width: Layout.sidebarWidth - 8)
                Text(index < 9 ? "⌃⌥\(index + 1)" : " ")
                    .font(.system(size: 8, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
            // Click a column's header to switch there; the current one's closes the columns.
            .onTapGesture {
                if current { manager.onExpandSidebar?() } else { manager.switchWorkspace(workspace.id) }
            }
            .help(current ? "收起" : "切换到“\(workspace.name)”")

            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 28, height: 1)

            ForEach(workspace.tabs) { tab in
                Button { manager.switchWorkspace(workspace.id, to: tab.id) } label: {
                    Image(nsImage: manager.icon(for: tab.bundleID))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 30, height: 30)
                        .opacity(manager.isAvailable(tab) ? 1 : 0.45)
                        .frame(width: 44, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.primary.opacity(tab.id == workspace.lastTabID ? 0.12 : 0))
                        )
                }
                .buttonStyle(PressStyle())
                .help(tab.displayName)
            }

            Spacer(minLength: 0)
        }
        .frame(width: Layout.sidebarWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                if hovering && !current {
                    RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.06))
                }
                if current {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                        .matchedGeometryEffect(id: "workspace-column", in: ns)
                }
            }
        }
        .opacity(current ? 1 : 0.72)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { manager.switchWorkspace(workspace.id) }
        .animation(Motion.press, value: hovering)
        .help("\(workspace.name)（点击切换）")
    }
}
