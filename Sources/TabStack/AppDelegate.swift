import Cocoa
import SwiftUI

/// Borderless panel docked to the left screen edge. It never becomes key or main,
/// so clicking it does not take focus away from the app being shown.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: SidebarPanel!
    private var manager: WorkspaceManager!
    /// Menu bar icon: the always-available way back when the sidebar is hidden.
    private var statusItem: NSStatusItem!
    private lazy var settings = SettingsWindowController(manager: manager)
    private lazy var search = WorkspaceSearchController(manager: manager)
    private lazy var control = ControlServer(manager: manager)

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
        panel.contentView = NSHostingView(rootView: SidebarRoot(manager: manager))
        manager.panel = panel
        manager.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        manager.onOpenSettings = { [weak self] id in self?.settings.show(workspace: id) }
        manager.onSearch = { [weak self] in self?.search.show() }
        manager.onExpandSidebar = { [weak self] in
            guard let self else { return }
            if self.manager.expanded { self.collapseList(animated: true) } else { self.flashWorkspaceList() }
        }
        buildMainMenu()
        dock()
        panel.orderFrontRegardless()
        setUpStatusItem()

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
                self.flashWorkspaceList()
            case .toggleSidebar: self.toggleSidebar()
            case .cycleTab(let offset):
                if let tab = self.manager.cycleTab(offset) {
                    HUD.shared.show(title: tab.displayName,
                                    subtitle: tab.displayName == tab.name ? nil : tab.name,
                                    icon: self.manager.icon(for: tab.bundleID))
                }
            case .cycleWorkspace(let offset):
                if self.manager.cycleWorkspace(offset) != nil { self.flashWorkspaceList() }
            case .search:
                self.search.toggle()
            case .closeWindow:
                self.manager.closeFocusedWindow()
            }
        }
        HotKeys.register()
        control.start()

        if !AX.isTrusted { AX.requestTrust() }

        // Bring back the tab that was selected when TabStack last quit.
        if let tab = manager.currentTab,
           manager.runningApp(tab.bundleID) != nil, AX.isTrusted {
            manager.select(tab)
        }
    }

    /// Opening TabStack again (Finder, Spotlight, Launchpad) brings the sidebar back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if userHidden { toggleSidebar() }
        return false
    }

    // MARK: Main menu (only visible while the settings window makes TabStack a regular app)

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(ClosureMenuItem("工作区设置…") { [weak self] in self?.settings.show() })
        appMenu.items.last?.keyEquivalent = ","
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TabStack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard edit actions, so ⌘C / ⌘V / ⌘A work in the settings text fields.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Menu bar item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "TabStack")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "TabStack"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Rebuilt every time it opens, so it always reflects the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        let toggle = ClosureMenuItem(userHidden ? "显示侧边栏" : "隐藏侧边栏") { [weak self] in self?.toggleSidebar() }
        toggle.keyEquivalent = "0"
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "工作区", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        WorkspaceMenuItems.add(to: menu, manager: manager)
        menu.addItem(ClosureMenuItem("新建工作区…") { [weak self] in self?.manager.newWorkspace() })
        let settingsItem = ClosureMenuItem("工作区设置…") { [weak self] in self?.settings.show() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let motion = ClosureMenuItem("切换动画") { Motion.curtainEnabled.toggle() }
        motion.state = Motion.curtainEnabled ? .on : .off
        menu.addItem(motion)
        menu.addItem(ClosureMenuItem("辅助功能设置…") { AX.openSettings() })
        menu.addItem(ClosureMenuItem("退出 TabStack") { NSApp.terminate(nil) })
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.unhideAll()
        control.stop()
    }

    /// Pins the panel to the left edge of the primary screen's visible area.
    private func dock() {
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        panel.setFrame(NSRect(x: vf.minX, y: vf.minY, width: Layout.sidebarWidth, height: vf.height), display: true)
    }

    // MARK: Expanded workspace list

    private var collapseWork: DispatchWorkItem?

    /// Widens the sidebar into the workspace list for a moment, so a keyboard switch shows
    /// where you are among all workspaces. Falls back to the centered HUD when the sidebar
    /// is hidden.
    private func flashWorkspaceList() {
        guard sidebarVisible, panel.isVisible else { showWorkspaceHUD(); return }
        if !manager.expanded {
            manager.expanded = true
            let maxWidth = (panel.screen ?? NSScreen.screens.first)?.visibleFrame.width ?? 1200
            resizePanel(to: Layout.expandedWidth(columns: manager.activeWorkspaces.count, maxWidth: maxWidth * 0.9))
        }
        scheduleCollapse(after: 1.4)
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseIfIdle() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Stays open while the mouse is over it, so a row can be clicked.
    private func collapseIfIdle() {
        if manager.hoveringSidebar { scheduleCollapse(after: 0.6); return }
        collapseList(animated: true)
    }

    private func collapseList(animated: Bool) {
        collapseWork?.cancel()
        guard manager.expanded else { return }
        manager.expanded = false
        resizePanel(to: Layout.sidebarWidth, animated: animated)
    }

    private func resizePanel(to width: CGFloat, animated: Bool = true) {
        var frame = panel.frame
        frame.size.width = width
        guard animated, !Motion.reduce else { panel.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func showWorkspaceHUD() {
        let ws = manager.currentWorkspace
        let index = manager.activeWorkspaces.firstIndex(of: ws) ?? 0
        HUD.shared.show(title: ws.name,
                        subtitle: "工作区 \(index + 1) / \(manager.activeWorkspaces.count)",
                        color: WorkspaceColor.color(for: ws, fallback: index))
    }

    /// Hidden by the user with ⌥⌘0 (as opposed to hidden because of full screen).
    private var userHidden = false
    private var fullScreenInFront = false

    private func toggleSidebar() {
        userHidden.toggle()
        manager.sidebarShown = !userHidden
        updateVisibility(animated: true)
        manager.layoutChanged()
    }

    private func updateVisibility(animated: Bool = false) {
        if let fs = AX.frontmostIsFullScreen() { fullScreenInFront = fs }
        setSidebar(visible: !userHidden && !fullScreenInFront, animated: animated)
    }

    /// The visibility the sidebar is heading to (it may still be mid-slide).
    private var sidebarVisible = true

    /// Slides the sidebar in from / out to the left screen edge. Full-screen changes are
    /// not animated: macOS is already animating its Space transition then.
    private func setSidebar(visible: Bool, animated: Bool) {
        guard visible != sidebarVisible else { return }
        sidebarVisible = visible
        if !visible { collapseList(animated: false) }
        guard let screen = NSScreen.screens.first else { return }
        let vf = screen.visibleFrame
        let docked = NSRect(x: vf.minX, y: vf.minY, width: Layout.sidebarWidth, height: vf.height)
        // Reduce Motion: fade in place instead of sliding.
        let away = Motion.reduce ? docked : docked.offsetBy(dx: -Layout.sidebarWidth, dy: 0)

        guard animated else {
            if visible { panel.setFrame(docked, display: true); panel.alphaValue = 1; panel.orderFrontRegardless() }
            else { panel.orderOut(nil) }
            return
        }

        if visible {
            if !panel.isVisible {
                panel.setFrame(away, display: true)
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = Motion.sidebarIn
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1) // soft ease-out
                panel.animator().setFrame(docked, display: true)
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = Motion.sidebarOut
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(away, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.sidebarVisible else { return }
                self.panel.orderOut(nil)
                self.panel.setFrame(docked, display: false)
                self.panel.alphaValue = 1
            })
        }
    }
}
