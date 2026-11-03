import Cocoa
import SwiftUI

/// Borderless panel docked to the left screen edge. It never becomes key or main,
/// so clicking it does not take focus away from the app being shown.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SidebarPanel!
    private var manager: WorkspaceManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = WorkspaceManager()

        panel = SidebarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        // No .fullScreenAuxiliary: the sidebar belongs to desktops, not full-screen Spaces.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: SidebarView(manager: manager))
        manager.panel = panel
        manager.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        dock()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.dock()
            self?.manager.layoutChanged()
        }

        // Hide while a full-screen app is in front, show again on a normal desktop.
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateVisibility()
                // The focused window's full-screen state can lag the notification a little.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.updateVisibility() }
            }
        }

        HotKeys.handler = { [weak self] action in
            guard let self else { return }
            switch action {
            case .tab(let i): self.manager.selectIndex(i)
            case .workspace(let i):
                self.manager.switchWorkspace(index: i)
                self.showWorkspaceHUD()
            case .toggleSidebar: self.toggleSidebar()
            case .cycleTab(let offset):
                if let tab = self.manager.cycleTab(offset) {
                    HUD.shared.show(title: tab.name, icon: self.manager.icon(for: tab.bundleID))
                }
            case .cycleWorkspace(let offset):
                if self.manager.cycleWorkspace(offset) != nil { self.showWorkspaceHUD() }
            }
        }
        HotKeys.register()

        if !AX.isTrusted { AX.requestTrust() }

        // Bring back the app that was selected when TabStack last quit.
        if let tab = manager.tabs.first(where: { $0.bundleID == manager.currentID }),
           manager.runningApp(tab.bundleID) != nil, AX.isTrusted {
            manager.select(tab)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.unhideAll()
    }

    /// Pins the panel to the left edge of the primary screen's visible area.
    private func dock() {
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: Layout.sidebarWidth, height: vf.height), display: true)
    }

    private func showWorkspaceHUD() {
        let ws = manager.currentWorkspace
        let index = manager.workspaces.firstIndex(of: ws) ?? 0
        HUD.shared.show(title: ws.name,
                        subtitle: "工作区 \(index + 1) / \(manager.workspaces.count)",
                        color: WorkspaceColor.color(at: index))
    }

    /// Hidden by the user with ⌥⌘0 (as opposed to hidden because of full screen).
    private var userHidden = false
    private var fullScreenInFront = false

    private func toggleSidebar() {
        userHidden.toggle()
        manager.sidebarShown = !userHidden
        updateVisibility()
        manager.layoutChanged()
    }

    private func updateVisibility() {
        if let fs = AX.frontmostIsFullScreen() { fullScreenInFront = fs }
        let show = !userHidden && !fullScreenInFront
        if show && !panel.isVisible {
            dock()
            panel.orderFrontRegardless()
        } else if !show && panel.isVisible {
            panel.orderOut(nil)
        }
    }
}
