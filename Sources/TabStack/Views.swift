import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var manager: WorkspaceManager
    @Namespace private var selectionNS
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
                TabButton(manager: manager, tab: tab, index: index,
                          selectionNS: selectionNS, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
            }
            AddMenu(manager: manager)
        }
        .padding(.vertical, 4)
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

// MARK: Workspaces

enum WorkspaceColor {
    static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .red]
    static func color(at index: Int) -> Color { palette[index % palette.count] }
}

struct WorkspaceMenu: View {
    @ObservedObject var manager: WorkspaceManager
    @State private var hovering = false

    var body: some View {
        let current = manager.currentWorkspace
        let index = manager.workspaces.firstIndex(of: current) ?? 0

        Button { showMenu() } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(WorkspaceColor.color(at: index))
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
            .animation(Motion.page, value: current.name)
            .animation(Motion.press, value: hovering)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help("工作区：\(current.name)（点击切换或管理）")
    }

    /// Built with AppKit: SwiftUI's borderless Menu flattens custom labels.
    private func showMenu() {
        let m = manager
        let current = m.currentWorkspace
        let index = m.workspaces.firstIndex(of: current) ?? 0
        let menu = NSMenu()
        menu.autoenablesItems = false

        for (i, ws) in m.workspaces.enumerated() {
            let item = ClosureMenuItem(ws.name) { m.switchWorkspace(ws.id) }
            item.state = ws.id == current.id ? .on : .off
            if i < 9 {
                item.keyEquivalent = "\(i + 1)"
                item.keyEquivalentModifierMask = [.control, .option]
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("新建工作区…") { m.newWorkspace() })
        menu.addItem(ClosureMenuItem("重命名“\(current.name)”…") { m.renameCurrentWorkspace() })
        menu.addItem(ClosureMenuItem("上移工作区", enabled: index > 0) { m.moveCurrentWorkspace(by: -1) })
        menu.addItem(ClosureMenuItem("下移工作区", enabled: index < m.workspaces.count - 1) { m.moveCurrentWorkspace(by: 1) })
        menu.addItem(ClosureMenuItem("删除“\(current.name)”…", enabled: m.workspaces.count > 1) { m.deleteCurrentWorkspace() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("启动本工作区所有应用") { m.launchAllInWorkspace() })
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
        let selected = manager.currentID == tab.bundleID
        let running = manager.runningIDs.contains(tab.bundleID)
        let badge = manager.badge(for: tab)
        // Scoped per workspace so the outgoing and incoming pages never share a highlight.
        let matchID = "selection-\(manager.currentWorkspaceID)"

        Button { manager.select(tab) } label: {
            Image(nsImage: manager.icon(for: tab.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .opacity(running ? 1 : 0.45)
                .saturation(running ? 1 : 0.3)
                .scaleEffect(hovering && !reduceMotion ? 1.06 : 1)
                .frame(width: 48, height: 46)
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
                .animation(.easeInOut(duration: 0.3), value: running)
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(index < 9 ? "\(tab.name)   ⌥⌘\(index + 1)" : tab.name)
        .contextMenu {
            Button("上移") { manager.move(tab, by: -1) }.disabled(index == 0)
            Button("下移") { manager.move(tab, by: 1) }.disabled(index == manager.tabs.count - 1)
            Divider()
            if running {
                Button("退出 \(tab.name)") { manager.quit(tab) }
            }
            Button("从工作区移除") { manager.remove(tab) }
        }
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
        Menu {
            let candidates = manager.candidates()
            if candidates.isEmpty {
                Text("没有其他正在运行的应用")
            }
            ForEach(candidates, id: \.processIdentifier) { app in
                Button(app.localizedName ?? app.bundleIdentifier ?? "?") { manager.add(app) }
            }
            Divider()
            Button("从“应用程序”文件夹选择…") { manager.chooseApplication() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 40, height: 32)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 44)
        .help("添加应用到“\(manager.currentWorkspace.name)”")
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
