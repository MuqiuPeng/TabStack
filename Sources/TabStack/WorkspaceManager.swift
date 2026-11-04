import Cocoa
import SwiftUI
import UniformTypeIdentifiers

/// One tab = one specific window of an app (a Chrome app can back several tabs).
///
/// `windowID` is the WindowServer id, valid only while that window exists. When the window
/// is closed or the app restarts, the tab becomes *unbound* and re-binds the next time it
/// is used: to a window with the same title if there is one, otherwise to a window of the
/// app that no other tab is using.
struct AppTab: Identifiable, Codable, Equatable {
    var id: UUID
    var bundleID: String
    /// App name.
    var name: String
    /// Name the user gave the tab, shown instead of the window title.
    var customName: String?
    /// Last seen window title, used for display and for re-binding.
    var title: String?
    var windowID: CGWindowID?

    init(bundleID: String, name: String, title: String? = nil, windowID: CGWindowID? = nil) {
        self.id = UUID()
        self.bundleID = bundleID
        self.name = name
        self.title = title
        self.windowID = windowID
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, customName, title, windowID }

    /// Also reads tabs saved by the app-level version (no id / window fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        windowID = try c.decodeIfPresent(CGWindowID.self, forKey: .windowID)
    }

    /// Identity is the tab, not its changing title.
    static func == (a: AppTab, b: AppTab) -> Bool { a.id == b.id }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        if let title, !title.isEmpty { return title }
        return name
    }
}

/// A saved set of windows. Switching workspaces hides the previous set and brings back
/// the tab that was last selected in the new one.
struct Workspace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var tabs: [AppTab] = []
    var lastTabID: UUID?
    /// Index into WorkspaceColor.palette. Stored, so reordering keeps each color.
    var color: Int?
}

enum Layout {
    static let sidebarWidth: CGFloat = 64
    static let columnSpacing: CGFloat = 4
    static let columnPadding: CGFloat = 4

    /// Width while the sidebar shows every workspace as a column, capped to the screen
    /// (beyond that the columns scroll).
    static func expandedWidth(columns: Int, maxWidth: CGFloat) -> CGFloat {
        let n = CGFloat(max(columns, 1))
        let full = n * sidebarWidth + (n - 1) * columnSpacing + 2 * columnPadding
        return min(full, maxWidth)
    }
}

/// A running app and its windows, for the "add" menu.
struct AddableApp {
    let app: NSRunningApplication
    let windows: [(id: CGWindowID, title: String)]
}

final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var currentWorkspaceID = UUID()
    /// Selected tab of the current workspace.
    @Published private(set) var currentID: UUID?
    /// +1 when the last workspace switch went to a later workspace, -1 to an earlier one;
    /// drives the direction of the sidebar's page transition.
    @Published private(set) var workspaceDirection = 1
    @Published private(set) var runningIDs: Set<String> = []
    @Published private(set) var liveWindowIDs: Set<CGWindowID> = []
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var trusted = AX.isTrusted

    /// The docked sidebar panel.
    weak var panel: NSPanel?
    /// Set by the app delegate, which owns the panel.
    var onToggleSidebar: (() -> Void)?
    /// Opens the settings window, optionally on a workspace. Set by the app delegate.
    var onOpenSettings: ((UUID?) -> Void)?
    /// Whether the user wants the sidebar (⌥⌘0). It may still be hidden temporarily
    /// while a full-screen app is in front; layout follows this flag, not visibility.
    var sidebarShown = true
    /// The sidebar is temporarily showing the full workspace list (keyboard switching).
    @Published var expanded = false
    /// Mouse is over the sidebar; keeps the expanded list open.
    var hoveringSidebar = false

    private var iconCache: [String: NSImage] = [:]
    private var timer: Timer?
    /// Bumped on every placement request so stale retry loops stop.
    private var placeToken = 0
    private let watcher = WindowWatcher()
    /// The switch in progress. Until it expires, focus changes are side effects of the
    /// switch itself (apps being hidden hand focus around) and must not move the selection.
    private var pending: (tabID: UUID, until: Date)?

    private enum Keys {
        static let workspaces = "workspaces"
        static let current = "currentWorkspace"
        static let legacyTabs = "tabs"
    }

    init() {
        load()
        refreshRunning()
        refreshLiveWindows()
        observeWorkspace()
        watcher.onFocusChange = { [weak self] pid in self?.handleFocus(pid: pid) }
        syncWatcher()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    var currentWorkspace: Workspace {
        workspaces.first { $0.id == currentWorkspaceID } ?? workspaces[0]
    }

    var tabs: [AppTab] { currentWorkspace.tabs }

    var currentTab: AppTab? { tabs.first { $0.id == currentID } }

    private func updateCurrent(_ change: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return }
        change(&workspaces[i])
        save()
    }

    /// Applies `change` to the tab with this id, in whichever workspace holds it.
    private func updateTab(_ id: UUID, _ change: (inout AppTab) -> Void) {
        for w in workspaces.indices {
            if let t = workspaces[w].tabs.firstIndex(where: { $0.id == id }) {
                change(&workspaces[w].tabs[t])
                save()
                return
            }
        }
    }

    // MARK: Switching tabs

    /// Switches to `tab`. `alsoHide` lists extra apps (bundle ids) to hide in the same
    /// motion: the apps of the workspace being left.
    func select(_ tab: AppTab, alsoHide: [String] = []) {
        currentID = tab.id
        updateCurrent { $0.lastTabID = tab.id }
        guard AX.isTrusted else { AX.requestTrust(); return }

        pending = (tab.id, Date().addingTimeInterval(1.2))

        // The sidebar highlight already moved; the windows change behind the curtain.
        // Nothing to cover when that exact window is already in front.
        let alreadyFront: Bool = {
            guard alsoHide.isEmpty, let app = runningApp(tab.bundleID), app.isActive,
                  let w = AX.focusedWindow(pid: app.processIdentifier) else { return false }
            return AX.windowID(w) == tab.windowID
        }()
        if !alreadyFront, let frame = contentFrameCocoa {
            SwitchCurtain.shared.cover(frame, icon: icon(for: tab.bundleID)) { [weak self] in
                self?.performSwitch(to: tab, alsoHide: alsoHide)
            }
        } else {
            performSwitch(to: tab, alsoHide: alsoHide)
        }
    }

    private func performSwitch(to tab: AppTab, alsoHide: [String]) {
        guard currentID == tab.id else { return } // superseded by a newer switch

        // Activate the target *before* hiding the others: hiding the frontmost app makes
        // macOS hand focus to some other app first.
        if let app = runningApp(tab.bundleID) {
            app.unhide()
            AX.activate(app)
            place(tab)
        } else {
            launch(tab)
        }

        // Other apps are hidden. Other tabs of the *same* app can't be hidden one by one;
        // they share the content frame, so the raised window simply covers them.
        let others = Set(tabs.map(\.bundleID) + alsoHide).subtracting([tab.bundleID])
        for id in others { runningApp(id)?.hide() }
    }

    func selectIndex(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// Moves to the previous (-1) or next (+1) tab of the current workspace, wrapping around.
    @discardableResult
    func cycleTab(_ offset: Int) -> AppTab? {
        guard !tabs.isEmpty else { return nil }
        let i = tabs.firstIndex { $0.id == currentID }
        let next = i.map { wrap($0 + offset, tabs.count) } ?? (offset > 0 ? 0 : tabs.count - 1)
        let tab = tabs[next]
        select(tab)
        return tab
    }

    /// Moves to the previous (-1) or next (+1) workspace, wrapping around.
    @discardableResult
    func cycleWorkspace(_ offset: Int) -> Workspace? {
        guard workspaces.count > 1,
              let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return nil }
        let ws = workspaces[wrap(i + offset, workspaces.count)]
        switchWorkspace(ws.id)
        return ws
    }

    private func wrap(_ i: Int, _ n: Int) -> Int { ((i % n) + n) % n }

    // MARK: Switching workspaces

    /// Switches workspace; `tabID` picks the tab to show there instead of the last one used.
    func switchWorkspace(_ id: UUID, to tabID: UUID? = nil) {
        if id == currentWorkspaceID {
            if let tab = tabs.first(where: { $0.id == tabID }) { select(tab) }
            return
        }
        guard let next = workspaces.first(where: { $0.id == id }) else { return }
        let from = workspaces.firstIndex { $0.id == currentWorkspaceID } ?? 0
        let to = workspaces.firstIndex { $0.id == id } ?? 0
        workspaceDirection = to >= from ? 1 : -1

        let keep = Set(next.tabs.map(\.bundleID))
        let leaving = Array(Set(tabs.map(\.bundleID)).subtracting(keep))
        currentWorkspaceID = id
        currentID = nil
        save()

        if let target = next.tabs.first(where: { $0.id == tabID })
            ?? next.tabs.first(where: { $0.id == next.lastTabID }) ?? next.tabs.first {
            select(target, alsoHide: leaving)
        } else {
            // Empty workspace: nothing to show, just put the old set away.
            for id in leaving { runningApp(id)?.hide() }
        }
    }

    func switchWorkspace(index: Int) {
        guard workspaces.indices.contains(index) else { return }
        switchWorkspace(workspaces[index].id)
    }

    func newWorkspace() {
        guard let name = Dialogs.prompt(title: "新建工作区", message: "给这组窗口起个名字", value: "工作区 \(workspaces.count + 1)")
        else { return }
        switchWorkspace(createWorkspace(named: name))
    }

    func renameCurrentWorkspace() {
        guard let name = Dialogs.prompt(title: "重命名工作区", message: "", value: currentWorkspace.name) else { return }
        updateCurrent { $0.name = name }
    }

    func deleteCurrentWorkspace() {
        guard workspaces.count > 1,
              Dialogs.confirm(title: "删除工作区“\(currentWorkspace.name)”？", message: "只删除这组标签，不会关闭其中的窗口或应用。")
        else { return }
        let removed = currentWorkspaceID
        let fallback = workspaces.first { $0.id != removed }!.id
        switchWorkspace(fallback)
        workspaces.removeAll { $0.id == removed }
        save()
        syncWatcher()
    }

    func moveCurrentWorkspace(by offset: Int) {
        guard let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return }
        let j = i + offset
        guard workspaces.indices.contains(j) else { return }
        workspaces.swapAt(i, j)
        save()
    }

    /// Starts every app of the current workspace that is not running yet, hidden.
    func launchAllInWorkspace() {
        let current = currentTab?.bundleID
        for id in Set(tabs.map(\.bundleID)) where runningApp(id) == nil && id != current {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    // MARK: Windows of a tab

    private var allTabs: [AppTab] { workspaces.flatMap(\.tabs) }

    /// Windows that some tab (in any workspace) is bound to.
    private func claimedWindowIDs(except tabID: UUID? = nil) -> Set<CGWindowID> {
        Set(allTabs.filter { $0.id != tabID }.compactMap(\.windowID))
    }

    func isBound(_ tab: AppTab) -> Bool {
        tab.windowID.map(liveWindowIDs.contains) ?? false
    }

    /// Whether clicking the tab can show something right away: the app runs and the window
    /// still exists, or the tab is waiting to be bound to one.
    func isAvailable(_ tab: AppTab) -> Bool {
        runningIDs.contains(tab.bundleID) && (tab.windowID == nil || isBound(tab))
    }

    private enum Resolution {
        case window(AXUIElement)
        /// The app has no windows at all (yet).
        case noWindows
        /// Every window of the app already belongs to another tab.
        case allClaimed
    }

    /// Finds the tab's window, re-binding an unbound tab when needed.
    private func resolve(_ tab: AppTab, pid: pid_t) -> Resolution {
        let windows = AX.windows(pid: pid)
        if windows.isEmpty { return .noWindows }
        if let id = tab.windowID, let w = windows.first(where: { AX.windowID($0) == id }) {
            return .window(w)
        }
        let claimed = claimedWindowIDs(except: tab.id)
        let free = windows.filter { AX.windowID($0).map { !claimed.contains($0) } ?? false }
        guard let pick = free.first(where: { !(tab.title ?? "").isEmpty && AX.title($0) == tab.title }) ?? free.first,
              let id = AX.windowID(pick)
        else { return .allClaimed }
        bind(tab.id, to: id, title: AX.title(pick))
        return .window(pick)
    }

    /// Binds every tab that has no live window to one of its app's free windows
    /// (same title first). Runs in the background so migrated or orphaned tabs settle
    /// without needing a click.
    private func bindUnboundTabs() {
        guard AX.isTrusted else { return }
        refreshLiveWindows()
        // Tabs that remember a title go first, so they get their own window back.
        let unbound = allTabs.filter { !isBound($0) && runningIDs.contains($0.bundleID) }
            .sorted { ($0.title?.isEmpty == false ? 0 : 1) < ($1.title?.isEmpty == false ? 0 : 1) }
        for tab in unbound {
            guard let app = runningApp(tab.bundleID) else { continue }
            _ = resolve(tab, pid: app.processIdentifier)
        }
    }

    private func bind(_ tabID: UUID, to windowID: CGWindowID, title: String) {
        updateTab(tabID) {
            $0.windowID = windowID
            $0.title = title
        }
        liveWindowIDs.insert(windowID)
    }

    // MARK: Placement

    /// Re-fits the current tab after the screen layout changed or the sidebar was toggled.
    func layoutChanged() {
        guard let tab = currentTab, let app = runningApp(tab.bundleID), !app.isHidden else { return }
        place(tab)
    }

    /// The area windows are fitted into: the screen's visible frame (no menu bar / Dock)
    /// minus the sidebar when it is shown.
    private var contentFrameCocoa: NSRect? {
        guard let screen = panel?.screen ?? NSScreen.screens.first else { return nil }
        var frame = screen.visibleFrame
        if sidebarShown {
            frame.origin.x += Layout.sidebarWidth
            frame.size.width -= Layout.sidebarWidth
        }
        return frame
    }

    private var contentFrameAX: CGRect? { contentFrameCocoa.map(AX.toAX) }

    /// Fits the tab's window into the content area and raises it. Apps that are still
    /// launching or have no window are retried for a few seconds; halfway through, a
    /// "reopen" is sent, which makes most apps open a new window.
    private func place(_ tab: AppTab) {
        placeToken += 1
        place(tabID: tab.id, token: placeToken, attempt: 0)
    }

    private func place(tabID: UUID, token: Int, attempt: Int) {
        guard token == placeToken else { return }
        guard let tab = allTabs.first(where: { $0.id == tabID }),
              let app = runningApp(tab.bundleID), !app.isTerminated,
              let frame = contentFrameAX
        else { SwitchCurtain.shared.reveal(); return }

        switch resolve(tab, pid: app.processIdentifier) {
        case .window(let w):
            // A full-screen window lives in its own Space; leave it alone.
            if AX.isFullScreen(w) { SwitchCurtain.shared.reveal(); return }
            AX.setFrame(w, frame)
            AX.raise(w)
            if attempt >= 0 {
                SwitchCurtain.shared.reveal()
                // A second pass catches apps that reposition themselves while un-hiding.
                after(0.25) { [weak self] in self?.place(tabID: tabID, token: token, attempt: -1) }
            }

        case .allClaimed:
            SwitchCurtain.shared.reveal()
            HUD.shared.show(title: "\(tab.name) 没有空闲的窗口",
                            subtitle: "这个标签的窗口已关闭，请在 \(tab.name) 里新建一个窗口",
                            icon: icon(for: tab.bundleID))

        case .noWindows:
            guard attempt >= 0, attempt < 40 else { SwitchCurtain.shared.reveal(); return }
            if attempt == 10 { reopen(app) }
            after(0.1) { [weak self] in self?.place(tabID: tabID, token: token, attempt: attempt + 1) }
        }
    }

    private func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private func launch(_ tab: AppTab) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tab.bundleID) else {
            NSSound.beep()
            SwitchCurtain.shared.reveal()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, app != nil, self.currentID == tab.id else { return }
                self.place(tab)
            }
        }
    }

    // MARK: Editing tabs

    /// Running apps with their windows that no tab has yet.
    func addableApps() -> [AddableApp] {
        bindUnboundTabs() // so windows already backing a tab are recognized as taken
        let taken = claimedWindowIDs()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            .compactMap { app in
                let windows: [(id: CGWindowID, title: String)] = AX.isTrusted
                    ? AX.windows(pid: app.processIdentifier).compactMap { w in
                        guard let id = AX.windowID(w), !taken.contains(id) else { return nil }
                        return (id, AX.title(w))
                    }
                    : []
                let hasAnyWindow = AX.isTrusted && !AX.windows(pid: app.processIdentifier).isEmpty
                let hasTab = allTabs.contains { $0.bundleID == app.bundleIdentifier }
                // Leave out apps whose every window is already a tab, and window-less apps
                // that already have a tab waiting for a window.
                if windows.isEmpty && (hasAnyWindow || hasTab) { return nil }
                return AddableApp(app: app, windows: windows)
            }
    }

    /// Adds one window of a running app as a tab.
    func add(window id: CGWindowID, title: String, of app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        if let existing = tabs.first(where: { $0.windowID == id }) { select(existing); return }
        let tab = AppTab(bundleID: bundleID, name: app.localizedName ?? bundleID, title: title, windowID: id)
        updateCurrent { $0.tabs.append(tab) }
        liveWindowIDs.insert(id)
        syncWatcher()
        select(tab)
    }

    /// Adds an app without picking a window; it binds to one when first shown.
    func add(app bundleID: String, name: String) {
        if let existing = tabs.first(where: { $0.bundleID == bundleID && $0.windowID == nil }) {
            select(existing)
            return
        }
        let tab = AppTab(bundleID: bundleID, name: name)
        updateCurrent { $0.tabs.append(tab) }
        syncWatcher()
        select(tab)
    }

    func remove(_ tab: AppTab) {
        updateCurrent {
            $0.tabs.removeAll { $0 == tab }
            if $0.lastTabID == tab.id { $0.lastTabID = nil }
        }
        if currentID == tab.id { currentID = nil }
        runningApp(tab.bundleID)?.unhide()
        syncWatcher()
    }

    func move(_ tab: AppTab, by offset: Int) {
        updateCurrent { ws in
            guard let i = ws.tabs.firstIndex(of: tab), ws.tabs.indices.contains(i + offset) else { return }
            ws.tabs.swapAt(i, i + offset)
        }
    }

    func rename(_ tab: AppTab) {
        guard let name = Dialogs.prompt(title: "重命名标签", message: "留空则显示窗口标题",
                                        value: tab.customName ?? tab.title ?? "", allowEmpty: true)
        else { return }
        updateTab(tab.id) { $0.customName = name.isEmpty ? nil : name }
    }

    /// Points the tab at the app's currently focused window.
    func rebindToFocusedWindow(_ tab: AppTab) {
        guard let app = runningApp(tab.bundleID),
              let w = AX.focusedWindow(pid: app.processIdentifier) ?? AX.windows(pid: app.processIdentifier).first,
              let id = AX.windowID(w)
        else { NSSound.beep(); return }
        bind(tab.id, to: id, title: AX.title(w))
        select(tab)
    }

    func quit(_ tab: AppTab) {
        runningApp(tab.bundleID)?.terminate()
    }

    /// Picks apps from /Applications; adds them to `workspaceID` (default: current).
    func chooseApplication(to workspaceID: UUID? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            let name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
            if let workspaceID { addApp(id, name: name, to: workspaceID) } else { add(app: id, name: name) }
        }
    }

    /// Un-hides every app of every workspace, so quitting TabStack never leaves apps invisible.
    func unhideAll() {
        for id in Set(allTabs.map(\.bundleID)) { runningApp(id)?.unhide() }
    }

    // MARK: Settings window

    private func update(_ workspaceID: UUID, _ change: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        change(&workspaces[i])
        save()
    }

    @discardableResult
    func createWorkspace(named name: String) -> UUID {
        var ws = Workspace(name: name)
        let used = Set(workspaces.compactMap(\.color))
        ws.color = (0..<WorkspaceColor.palette.count).first { !used.contains($0) }
            ?? workspaces.count % WorkspaceColor.palette.count
        workspaces.append(ws)
        save()
        return ws.id
    }

    func moveWorkspaces(from source: IndexSet, to destination: Int) {
        workspaces.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func renameWorkspace(_ id: UUID, to name: String) {
        update(id) { $0.name = name }
    }

    func setColor(_ id: UUID, _ color: Int) {
        update(id) { $0.color = color }
    }

    /// Deletes after confirmation; leaving the current workspace first if needed.
    func deleteWorkspace(_ id: UUID) {
        guard workspaces.count > 1, let ws = workspaces.first(where: { $0.id == id }),
              Dialogs.confirm(title: "删除工作区“\(ws.name)”？", message: "只删除这组标签，不会关闭其中的窗口或应用。")
        else { return }
        if id == currentWorkspaceID, let other = workspaces.first(where: { $0.id != id }) {
            switchWorkspace(other.id)
        }
        workspaces.removeAll { $0.id == id }
        save()
        syncWatcher()
    }

    func moveTabs(in workspaceID: UUID, from source: IndexSet, to destination: Int) {
        update(workspaceID) { $0.tabs.move(fromOffsets: source, toOffset: destination) }
    }

    func renameTab(_ id: UUID, to name: String) {
        updateTab(id) { $0.customName = name.isEmpty ? nil : name }
    }

    func removeTab(_ tabID: UUID, from workspaceID: UUID) {
        if workspaceID == currentWorkspaceID, let tab = tabs.first(where: { $0.id == tabID }) {
            remove(tab)
            return
        }
        update(workspaceID) {
            $0.tabs.removeAll { $0.id == tabID }
            if $0.lastTabID == tabID { $0.lastTabID = nil }
        }
        syncWatcher()
    }

    /// Moves a tab (with its window binding) to another workspace.
    func moveTab(_ tabID: UUID, from source: UUID, to destination: UUID) {
        guard source != destination,
              let tab = workspaces.first(where: { $0.id == source })?.tabs.first(where: { $0.id == tabID })
        else { return }
        update(source) {
            $0.tabs.removeAll { $0.id == tabID }
            if $0.lastTabID == tabID { $0.lastTabID = nil }
        }
        if source == currentWorkspaceID && currentID == tabID { currentID = nil }
        update(destination) { ws in
            if let id = tab.windowID, ws.tabs.contains(where: { $0.windowID == id }) { return }
            ws.tabs.append(tab)
        }
    }

    /// Adds a window to any workspace; only the current one switches to it.
    func addWindow(_ id: CGWindowID, title: String, of app: NSRunningApplication, to workspaceID: UUID) {
        if workspaceID == currentWorkspaceID { add(window: id, title: title, of: app); return }
        guard let bundleID = app.bundleIdentifier else { return }
        update(workspaceID) { ws in
            guard !ws.tabs.contains(where: { $0.windowID == id }) else { return }
            ws.tabs.append(AppTab(bundleID: bundleID, name: app.localizedName ?? bundleID, title: title, windowID: id))
        }
        liveWindowIDs.insert(id)
        syncWatcher()
    }

    func addApp(_ bundleID: String, name: String, to workspaceID: UUID) {
        if workspaceID == currentWorkspaceID { add(app: bundleID, name: name); return }
        update(workspaceID) { ws in
            guard !ws.tabs.contains(where: { $0.bundleID == bundleID && $0.windowID == nil }) else { return }
            ws.tabs.append(AppTab(bundleID: bundleID, name: name))
        }
        syncWatcher()
    }

    // MARK: Lookups

    func runningApp(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    func icon(for bundleID: String) -> NSImage {
        if let cached = iconCache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        iconCache[bundleID] = image
        return image
    }

    func badge(for tab: AppTab) -> String? {
        if let b = badges[tab.name] { return b }
        if let name = runningApp(tab.bundleID)?.localizedName { return badges[name] }
        return nil
    }

    /// Text under the icon: the custom name, or the window title when the workspace holds
    /// several windows of the same app (otherwise the icon alone is clear enough).
    func label(for tab: AppTab) -> String? {
        if let c = tab.customName, !c.isEmpty { return c }
        guard tabs.filter({ $0.bundleID == tab.bundleID }).count > 1 else { return nil }
        if let t = tab.title, !t.isEmpty { return t }
        return tab.name
    }

    // MARK: Observation

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
            self?.syncWatcher()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
            self?.refreshLiveWindows()
            self?.syncWatcher()
        }
        // ⌘Tab / Dock switches arrive as app activations; clicks between windows of the
        // same app arrive through the WindowWatcher. Both end up in handleFocus.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.handleFocus(pid: app.processIdentifier)
        }
    }

    /// Keeps the highlight in sync with the focused window and fits that window next to
    /// the sidebar. A focused window that is no tab's yet is taken by an unbound tab of
    /// the same app.
    private func handleFocus(pid: pid_t) {
        if let p = pending {
            if Date() < p.until { return }
            pending = nil
        }
        guard AX.isTrusted,
              let app = NSRunningApplication(processIdentifier: pid), !app.isHidden,
              let bundleID = app.bundleIdentifier,
              tabs.contains(where: { $0.bundleID == bundleID }),
              let w = AX.focusedWindow(pid: pid), let wid = AX.windowID(w)
        else { return }
        refreshLiveWindows()

        if let tab = tabs.first(where: { $0.windowID == wid }) {
            guard currentID != tab.id else { return }
            currentID = tab.id
            updateCurrent { $0.lastTabID = tab.id }
            place(tab)
        } else if let tab = tabs.first(where: { $0.bundleID == bundleID && !isBound($0) }),
                  !claimedWindowIDs(except: tab.id).contains(wid) {
            bind(tab.id, to: wid, title: AX.title(w))
            currentID = tab.id
            updateCurrent { $0.lastTabID = tab.id }
            place(tab)
        }
    }

    /// Focus is watched for every running app that backs a tab in any workspace.
    private func syncWatcher() {
        let ids = Set(allTabs.map(\.bundleID))
        let pids = Set(ids.compactMap { runningApp($0)?.processIdentifier })
        watcher.watch(AX.isTrusted ? pids : [])
    }

    private func refreshRunning() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if ids != runningIDs { runningIDs = ids }
    }

    private func refreshLiveWindows() {
        let ids = AX.existingWindowIDs()
        if ids != liveWindowIDs { liveWindowIDs = ids }
    }

    /// Keeps titles of the current workspace's windows fresh (a browser window's title
    /// follows its active tab).
    private func refreshTitles() {
        let bound = tabs.filter { $0.windowID != nil }
        for bundleID in Set(bound.map(\.bundleID)) {
            guard let app = runningApp(bundleID) else { continue }
            var titles: [CGWindowID: String] = [:]
            for w in AX.windows(pid: app.processIdentifier) {
                if let id = AX.windowID(w) { titles[id] = AX.title(w) }
            }
            for tab in bound where tab.bundleID == bundleID {
                if let id = tab.windowID, let t = titles[id], !t.isEmpty, t != tab.title {
                    updateTab(tab.id) { $0.title = t }
                }
            }
        }
    }

    private func tick() {
        let t = AX.isTrusted
        if t != trusted {
            trusted = t
            syncWatcher()
        }
        refreshLiveWindows()
        guard t else { return }
        bindUnboundTabs()
        refreshTitles()
        let b = AX.dockBadges()
        if b != badges { badges = b }
    }

    // MARK: Persistence

    private func load() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Keys.workspaces),
           let saved = try? JSONDecoder().decode([Workspace].self, from: data), !saved.isEmpty {
            workspaces = saved
        } else {
            // First run, or upgrade from the single-list version.
            var first = Workspace(name: "默认")
            if let data = defaults.data(forKey: Keys.legacyTabs),
               let tabs = try? JSONDecoder().decode([AppTab].self, from: data) {
                first.tabs = tabs
            }
            workspaces = [first]
        }
        if let s = defaults.string(forKey: Keys.current), let id = UUID(uuidString: s),
           workspaces.contains(where: { $0.id == id }) {
            currentWorkspaceID = id
        } else {
            currentWorkspaceID = workspaces[0].id
        }
        currentID = currentWorkspace.lastTabID
        // Pin each workspace's color to the one it showed so far (it used to follow position).
        for i in workspaces.indices where workspaces[i].color == nil {
            workspaces[i].color = i % WorkspaceColor.palette.count
        }
        save() // persists ids given to tabs migrated from the app-level format
    }

    private func save() {
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: Keys.workspaces)
        }
        UserDefaults.standard.set(currentWorkspaceID.uuidString, forKey: Keys.current)
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// Small modal dialogs. TabStack is a background (accessory) app, so it activates itself first.
enum Dialogs {
    static func prompt(title: String, message: String, value: String, allowEmpty: Bool = false) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty && !allowEmpty ? nil : text
    }

    static func confirm(title: String, message: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }
}
