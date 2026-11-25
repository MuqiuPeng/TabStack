import Cocoa
import SwiftUI

/// Borderless panel docked to the left screen edge. It never becomes key or main,
/// so clicking it does not take focus away from the app being shown.
final class SidebarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// Runs before the click reaches SwiftUI, so the display is focused when the
    /// button's action runs.
    var onMouseDown: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { onMouseDown?() }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// One sidebar per display that has a workspace.
    private var panels: [DisplayKey: SidebarPanel] = [:]
    /// The focused display's sidebar: the one that expands into the workspace list.
    private var panel: SidebarPanel? { panels[manager.focusedDisplay] }
    private var manager: WorkspaceManager!
    /// Menu bar icon: the always-available way back when the sidebar is hidden.
    private var statusItem: NSStatusItem!
    private lazy var settings = SettingsWindowController(manager: manager)
    private lazy var search = WorkspaceSearchController(manager: manager)
    private lazy var quickAdd = QuickAddController(manager: manager)
    private lazy var tickets = TicketPanelController(manager: manager)
    private lazy var control = ControlServer(manager: manager)

    func applicationDidFinishLaunching(_ notification: Notification) {
        manager = WorkspaceManager()

        manager.onFocusedDisplayChange = { [weak self] in self?.collapseList(animated: false) }
        manager.onToggleSidebar = { [weak self] in self?.toggleSidebar() }
        manager.onOpenSettings = { [weak self] id in self?.settings.show(workspace: id) }
        manager.onSearch = { [weak self] in self?.search.show() }
        manager.onCollapseSidebar = { [weak self] in
            guard let self, self.manager.expanded else { return false }
            self.collapseList(animated: true)
            return true
        }
        manager.onExpandSidebar = { [weak self] in
            guard let self else { return }
            if self.manager.expanded { self.collapseList(animated: true) } else { self.flashWorkspaceList(fromKeyboard: false) }
        }
        manager.pointerOnSidebar = { [weak self] in self?.pointerOnList() ?? false }
        manager.onAutoHideChanged = { [weak self] in self?.autoHideChanged() }
        manager.sidebarShown = !autoHide
        buildMainMenu()
        dock()
        if autoHide { startEdgeWatch() }
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
                self.quickAdd.close()
                self.tickets.close()
                self.search.toggle()
            case .closeWindow:
                self.manager.closeFocusedWindow()
            case .quickAdd:
                self.search.close()
                self.tickets.close()
                self.quickAdd.toggle()
            case .tickets:
                self.search.close()
                self.quickAdd.close()
                self.tickets.toggle()
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
        if autoHide || userHidden { toggleSidebar() }
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

        let toggle = ClosureMenuItem(autoHide ? "滑出侧边栏" : userHidden ? "显示侧边栏" : "隐藏侧边栏") { [weak self] in self?.toggleSidebar() }
        toggle.keyEquivalent = "0"
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        let auto = ClosureMenuItem("自动隐藏侧边栏") { [weak self] in
            UserDefaults.standard.set(!(self?.autoHide ?? false), forKey: WorkspaceManager.autoHideKey)
            self?.autoHideChanged()
        }
        auto.state = autoHide ? .on : .off
        menu.addItem(auto)
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

    private func makePanel(for display: DisplayKey) -> SidebarPanel {
        let p = SidebarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        // No .fullScreenAuxiliary: the sidebar belongs to desktops, not full-screen Spaces.
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: SidebarRoot(manager: manager).environment(\.sidebarDisplay, display))
        p.onMouseDown = { [weak self] in self?.manager.focusDisplay(display) }
        return p
    }

    /// The sidebar's place on a display: the left edge of its visible area. With auto-hide
    /// it floats like the Dock: a little off the edge, with a small gap above and below.
    private func dockedFrame(_ display: DisplayKey) -> NSRect? {
        guard let vf = Displays.screen(display)?.visibleFrame else { return nil }
        guard autoHide else {
            return NSRect(x: vf.minX, y: vf.minY, width: Layout.sidebarWidth, height: vf.height)
        }
        return NSRect(x: vf.minX + Self.floatInset, y: vf.minY + Self.floatMargin,
                      width: Layout.sidebarWidth, height: vf.height - 2 * Self.floatMargin)
    }

    /// Gap between the floating sidebar and the screen edge.
    private static let floatInset: CGFloat = 6
    /// Gap above and below the floating sidebar (about half a centimeter).
    private static let floatMargin: CGFloat = 24

    /// One sidebar on the left edge of every display that has a workspace.
    private func dock() {
        manager.assignDisplays()
        let wanted = Set(Displays.keys.filter { manager.workspaceID(on: $0) != nil })
        for (d, p) in panels where !wanted.contains(d) {
            p.orderOut(nil)
            panels[d] = nil
            shownPanels.remove(d)
        }
        if let r = revealed, !wanted.contains(r) { revealed = nil }
        manager.expanded = false
        for d in wanted {
            let p = panels[d] ?? makePanel(for: d)
            panels[d] = p
            if let frame = dockedFrame(d) { p.setFrame(frame, display: true) }
            if wantsVisible(d) {
                shownPanels.insert(d)
                p.alphaValue = 1
                p.orderFrontRegardless()
            } else if !shownPanels.contains(d) {
                p.orderOut(nil)
            }
        }
    }

    // MARK: Expanded workspace list

    private var collapseWork: DispatchWorkItem?

    /// Widens the sidebar into the workspace list for a moment, so a keyboard switch shows
    /// where you are among all workspaces. Falls back to the centered HUD when the sidebar
    /// is hidden.
    private func flashWorkspaceList(fromKeyboard: Bool = true) {
        // Auto-hide: slide the sidebar out for the switch; it goes again once the list folds.
        if autoHide, !fullScreenInFront { reveal(manager.focusedDisplay, grace: 0) }
        guard shownPanels.contains(manager.focusedDisplay), let panel, panel.isVisible else { showWorkspaceHUD(); return }
        // A pointer resting where the list happens to open is not choosing from it.
        pointerAnchor = fromKeyboard ? NSEvent.mouseLocation : nil
        if !manager.expanded {
            manager.expanded = true
            let maxWidth = (panel.screen ?? NSScreen.screens.first)?.visibleFrame.width ?? 1200
            resizePanel(panel, display: manager.focusedDisplay, to: Layout.expandedWidth(columns: manager.activeWorkspaces.count, maxWidth: maxWidth * 0.9))
        }
        scheduleCollapse(after: 1.4)
    }

    private func scheduleCollapse(after seconds: TimeInterval) {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.collapseIfIdle() }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Where the pointer was when the keyboard last opened the list; until it moves away
    /// from there it does not count as hovering.
    private var pointerAnchor: NSPoint?

    /// The pointer is on the expanded list and has moved since the keyboard opened it.
    /// Checked against the panel's frame, so it cannot get stuck the way hover tracking can.
    private func pointerOnList() -> Bool {
        guard manager.expanded, let panel, panel.isVisible else { return false }
        let p = NSEvent.mouseLocation
        guard panel.frame.contains(p) else { return false }
        if let a = pointerAnchor {
            if hypot(p.x - a.x, p.y - a.y) < 4 { return false }
            pointerAnchor = nil
        }
        return true
    }

    /// Stays open while the mouse is over it, so a row can be clicked.
    private func collapseIfIdle() {
        if manager.hoveringSidebar { scheduleCollapse(after: 0.6); return }
        collapseList(animated: true)
    }

    private func collapseList(animated: Bool) {
        collapseWork?.cancel()
        manager.expanded = false
        for (d, p) in panels where p.frame.width != Layout.sidebarWidth {
            resizePanel(p, display: d, to: Layout.sidebarWidth, animated: animated)
        }
    }

    /// Resizes from the docked position, so it also takes over a slide-in still under way.
    private func resizePanel(_ panel: NSPanel, display: DisplayKey, to width: CGFloat, animated: Bool = true) {
        var frame = shownPanels.contains(display) ? (dockedFrame(display) ?? panel.frame) : panel.frame
        frame.size.width = width
        guard animated, !Motion.reduce else { panel.setFrame(frame, display: true); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = WorkspaceManager.collapseDuration
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

    /// ⌥⌘0: shows / hides the sidebar; with auto-hide on, slides it out for a while instead.
    private func toggleSidebar() {
        if autoHide {
            if revealed == nil { reveal(manager.focusedDisplay, grace: Self.peekGrace) } else { conceal() }
            return
        }
        userHidden.toggle()
        manager.sidebarShown = !userHidden
        updateVisibility(animated: true)
        manager.layoutChanged()
    }

    private func updateVisibility(animated: Bool = false) {
        if let fs = AX.frontmostIsFullScreen() { fullScreenInFront = fs }
        if fullScreenInFront { revealed = nil }
        applyVisibility(animated: animated)
    }

    /// Displays whose sidebar is shown or sliding in.
    private var shownPanels: Set<DisplayKey> = []

    private func wantsVisible(_ d: DisplayKey) -> Bool {
        if fullScreenInFront { return false }
        if autoHide { return revealed == d }
        return !userHidden
    }

    /// Slides each sidebar in from / out to the left screen edge as needed. Full-screen
    /// changes are not animated: macOS is already animating its Space transition then.
    private func applyVisibility(animated: Bool) {
        for (d, panel) in panels {
            let visible = wantsVisible(d)
            guard visible != shownPanels.contains(d), let docked = dockedFrame(d) else { continue }
            if visible { shownPanels.insert(d) } else {
                shownPanels.remove(d)
                if manager.expanded, d == manager.focusedDisplay { collapseList(animated: false) }
            }
            slide(panel, display: d, docked: docked, visible: visible, animated: animated)
        }
    }

    // MARK: Auto-hide

    /// Pointer within this many points of a display's left edge counts as touching it.
    private static let edgeBand: CGFloat = 2
    /// How long the pointer rests on the edge before the sidebar slides out.
    private static let edgeDwell: TimeInterval = 0.2
    /// How long the pointer is away from the sidebar before it slides back.
    private static let leaveDelay: TimeInterval = 0.5
    /// Extra time a sidebar brought out with ⌥⌘0 waits for the pointer.
    private static let peekGrace: TimeInterval = 2.5

    private var autoHide: Bool { UserDefaults.standard.bool(forKey: WorkspaceManager.autoHideKey) }
    /// The display whose auto-hidden sidebar is slid out.
    private var revealed: DisplayKey?
    private var edgeMonitors: [Any] = []
    private var dwellWork: DispatchWorkItem?
    private var leaveTimer: Timer?
    /// Last moment the sidebar had a reason to stay (pointer on it, list open).
    private var lastWanted = Date()

    private func autoHideChanged() {
        revealed = nil
        for p in panels.values { p.invalidateShadow() }
        if autoHide { startEdgeWatch() } else { stopEdgeWatch() }
        manager.sidebarShown = autoHide ? false : !userHidden
        applyVisibility(animated: true)
        manager.layoutChanged()
    }

    private func startEdgeWatch() {
        guard edgeMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.pointerMoved() }) {
            edgeMonitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.pointerMoved(); return e }) {
            edgeMonitors.append(m)
        }
    }

    private func stopEdgeWatch() {
        edgeMonitors.forEach(NSEvent.removeMonitor)
        edgeMonitors = []
        dwellWork?.cancel()
        leaveTimer?.invalidate()
        leaveTimer = nil
    }

    /// The display whose free left edge the pointer is touching. An edge shared with a
    /// display to its left is skipped, so crossing between displays does not trigger it.
    private func edgeDisplay(at p: NSPoint) -> DisplayKey? {
        for s in NSScreen.screens {
            let f = s.frame
            guard p.y >= f.minY, p.y < f.maxY, p.x >= f.minX, p.x < f.minX + Self.edgeBand else { continue }
            let neighbor = NSScreen.screens.contains { o in
                o != s && abs(o.frame.maxX - f.minX) < 1 && p.y >= o.frame.minY && p.y < o.frame.maxY
            }
            return neighbor ? nil : Displays.key(s)
        }
        return nil
    }

    private func pointerMoved() {
        guard autoHide, revealed == nil, !fullScreenInFront else { dwellWork?.cancel(); dwellWork = nil; return }
        guard let d = edgeDisplay(at: NSEvent.mouseLocation), panels[d] != nil else {
            dwellWork?.cancel(); dwellWork = nil; return
        }
        guard dwellWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.dwellWork = nil
            guard self.revealed == nil, self.edgeDisplay(at: NSEvent.mouseLocation) == d,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.reveal(d, grace: 0)
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.edgeDwell, execute: work)
    }

    /// Slides the auto-hidden sidebar out over the windows (no relayout) on one display.
    private func reveal(_ d: DisplayKey, grace: TimeInterval) {
        guard panels[d] != nil else { return }
        lastWanted = Date().addingTimeInterval(grace)
        if revealed != d {
            if revealed != nil { revealed = nil; applyVisibility(animated: true) }
            revealed = d
            applyVisibility(animated: true)
        }
        guard leaveTimer == nil else { return }
        // Default run loop mode only: the timer pauses while a context menu is open.
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.checkLeave() }
        RunLoop.main.add(t, forMode: .default)
        leaveTimer = t
    }

    private func checkLeave() {
        guard let d = revealed, let p = panels[d] else { conceal(); return }
        let pt = NSEvent.mouseLocation
        // The panel, plus the gap between it and the screen edge.
        let screenMinX = Displays.screen(d)?.frame.minX ?? p.frame.minX
        let onIt = (pt.x >= screenMinX && pt.x <= p.frame.maxX + 1 && pt.y >= p.frame.minY && pt.y <= p.frame.maxY)
            || edgeDisplay(at: pt) == d
        if onIt || manager.expanded || NSEvent.pressedMouseButtons != 0 {
            lastWanted = max(lastWanted, Date())
        } else if Date().timeIntervalSince(lastWanted) >= Self.leaveDelay {
            conceal()
        }
    }

    private func conceal() {
        leaveTimer?.invalidate()
        leaveTimer = nil
        guard revealed != nil else { return }
        revealed = nil
        applyVisibility(animated: true)
    }

    private func slide(_ panel: NSPanel, display: DisplayKey, docked: NSRect, visible: Bool, animated: Bool) {
        // Reduce Motion: fade in place instead of sliding.
        let away = Motion.reduce ? docked : docked.offsetBy(dx: -(docked.width + Self.floatInset + 2), dy: 0)

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
                guard let self, !self.shownPanels.contains(display) else { return }
                panel.orderOut(nil)
                panel.setFrame(docked, display: false)
                panel.alphaValue = 1
            })
        }
    }
}
