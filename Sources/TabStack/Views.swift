import SwiftUI
import AppKit

struct SidebarView: View {
    @ObservedObject var manager: WorkspaceManager

    var body: some View {
        VStack(spacing: 6) {
            WorkspaceMenu(manager: manager)
                .padding(.top, 10)

            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 36, height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(manager.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButton(manager: manager, tab: tab, index: index)
                    }
                    AddMenu(manager: manager)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }

            if !manager.trusted {
                Button { AX.openSettings() } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .frame(width: 40, height: 28)
                }
                .buttonStyle(.plain)
                .help("需要“辅助功能”权限，点击打开系统设置")
            }

            Spacer().frame(height: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffect())
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
        }
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
                Text(String(current.name.prefix(1)).uppercased())
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(WorkspaceColor.color(at: index)))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(hovering ? 0.6 : 0), lineWidth: 1.5))
                Text(current.name)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: Layout.sidebarWidth - 8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @State private var hovering = false

    var body: some View {
        let selected = manager.currentID == tab.bundleID
        let running = manager.runningIDs.contains(tab.bundleID)

        Button { manager.select(tab) } label: {
            Image(nsImage: manager.icon(for: tab.bundleID))
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .opacity(running ? 1 : 0.45)
                .frame(width: 48, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(selected ? Color.accentColor.opacity(0.28)
                                       : (hovering ? Color.primary.opacity(0.08) : .clear))
                )
                .overlay(alignment: .topTrailing) {
                    if let badge = manager.badge(for: tab) {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 3, y: -2)
                    }
                }
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule().fill(Color.accentColor).frame(width: 3, height: 22).offset(x: -6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
