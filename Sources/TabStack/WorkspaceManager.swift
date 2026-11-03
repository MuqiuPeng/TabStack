import Cocoa
import SwiftUI
import UniformTypeIdentifiers

struct AppTab: Identifiable, Codable, Equatable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

/// A saved combination of apps. Switching workspaces hides the previous set and
/// brings back the app that was last selected in the new one.
struct Workspace: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var tabs: [AppTab] = []
    var lastBundleID: String?
}

enum Layout {
    static let sidebarWidth: CGFloat = 64
}

final class WorkspaceManager: ObservableObject {
    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var currentWorkspaceID = UUID()
    @Published private(set) var currentID: String?
    @Published private(set) var runningIDs: Set<String> = []
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var trusted = AX.isTrusted

    /// The docked sidebar panel.
    weak var panel: NSPanel?
    /// Set by the app delegate, which owns the panel.
    var onToggleSidebar: (() -> Void)?
    /// Whether the user wants the sidebar (⌥⌘0). It may still be hidden temporarily
    /// while a full-screen app is in front; layout follows this flag, not visibility.
    var sidebarShown = true

    private var iconCache: [String: NSImage] = [:]
    private var timer: Timer?
    /// Bumped on every placement request so stale retry loops stop.
    private var placeToken = 0

    private enum Keys {
        static let workspaces = "workspaces"
        static let current = "currentWorkspace"
        static let legacyTabs = "tabs"
    }

    init() {
        load()
        refreshRunning()
        observeWorkspace()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    var currentWorkspace: Workspace {
        workspaces.first { $0.id == currentWorkspaceID } ?? workspaces[0]
    }

    var tabs: [AppTab] { currentWorkspace.tabs }

    private func updateCurrent(_ change: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return }
        change(&workspaces[i])
        save()
    }

    // MARK: Switching apps

    func select(_ tab: AppTab) {
        currentID = tab.bundleID
        updateCurrent { $0.lastBundleID = tab.bundleID }
        guard AX.isTrusted else { AX.requestTrust(); return }

        // While this switch settles, activations of other apps are side effects of it
        // (see the activation observer) and must not change the selection.
        pending = (tab.bundleID, Date().addingTimeInterval(1.0))

        // Activate the target *before* hiding the others: hiding the frontmost app makes
        // macOS hand focus to some other app first, which used to hijack the selection.
        if let app = runningApp(tab.bundleID) {
            app.unhide()
            AX.activate(app)
            place(app)
        } else {
            launch(tab)
        }

        for other in tabs where other.bundleID != tab.bundleID {
            runningApp(other.bundleID)?.hide()
        }
    }

    /// The selection in progress and until when it is considered settling.
    private var pending: (id: String, until: Date)?

    func selectIndex(_ index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index])
    }

    /// Moves to the previous (-1) or next (+1) app of the current workspace, wrapping around.
    @discardableResult
    func cycleTab(_ offset: Int) -> AppTab? {
        guard !tabs.isEmpty else { return nil }
        let i = tabs.firstIndex { $0.bundleID == currentID }
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

    func switchWorkspace(_ id: UUID) {
        guard id != currentWorkspaceID, let next = workspaces.first(where: { $0.id == id }) else { return }
        let keep = Set(next.tabs.map(\.bundleID))
        for tab in tabs where !keep.contains(tab.bundleID) {
            runningApp(tab.bundleID)?.hide()
        }
        currentWorkspaceID = id
        currentID = nil
        save()

        if let target = next.tabs.first(where: { $0.bundleID == next.lastBundleID }) ?? next.tabs.first {
            select(target)
        }
    }

    func switchWorkspace(index: Int) {
        guard workspaces.indices.contains(index) else { return }
        switchWorkspace(workspaces[index].id)
    }

    func newWorkspace() {
        guard let name = Dialogs.prompt(title: "新建工作区", message: "给这组应用起个名字", value: "工作区 \(workspaces.count + 1)")
        else { return }
        let ws = Workspace(name: name)
        workspaces.append(ws)
        save()
        switchWorkspace(ws.id)
    }

    func renameCurrentWorkspace() {
        guard let name = Dialogs.prompt(title: "重命名工作区", message: "", value: currentWorkspace.name) else { return }
        updateCurrent { $0.name = name }
    }

    func deleteCurrentWorkspace() {
        guard workspaces.count > 1,
              Dialogs.confirm(title: "删除工作区“\(currentWorkspace.name)”？", message: "只删除这组标签，不会退出其中的应用。")
        else { return }
        let removed = currentWorkspaceID
        let fallback = workspaces.first { $0.id != removed }!.id
        switchWorkspace(fallback)
        workspaces.removeAll { $0.id == removed }
        save()
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
        for tab in tabs where runningApp(tab.bundleID) == nil && tab.bundleID != currentID {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tab.bundleID) else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            config.hides = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    // MARK: Placement

    /// Re-fits the current app after the screen layout changed or the sidebar was toggled.
    func layoutChanged() {
        guard let id = currentID, let app = runningApp(id), !app.isHidden else { return }
        place(app)
    }

    /// The area apps are fitted into: the screen's visible frame (no menu bar / Dock)
    /// minus the sidebar when it is shown.
    private var contentFrameAX: CGRect? {
        guard let screen = panel?.screen ?? NSScreen.screens.first else { return nil }
        var frame = screen.visibleFrame
        if sidebarShown {
            frame.origin.x += Layout.sidebarWidth
            frame.size.width -= Layout.sidebarWidth
        }
        return AX.toAX(frame)
    }

    /// Fits the app's main window into the content area. Apps that are still launching or
    /// have no open window are retried for a few seconds; halfway through, a "reopen" is
    /// sent, which makes most apps open a new window.
    private func place(_ app: NSRunningApplication) {
        placeToken += 1
        place(app, token: placeToken, attempt: 0)
    }

    private func place(_ app: NSRunningApplication, token: Int, attempt: Int) {
        guard token == placeToken, !app.isTerminated, let frame = contentFrameAX else { return }

        if let w = AX.mainWindow(pid: app.processIdentifier) {
            // A full-screen window lives in its own Space; leave it alone.
            if AX.isFullScreen(w) { return }
            AX.setFrame(w, frame)
            AX.raise(w)
            // A second pass catches apps that reposition themselves while un-hiding.
            if attempt >= 0 {
                after(0.25) { [weak self] in self?.place(app, token: token, attempt: -1) }
            }
            return
        }

        guard attempt >= 0, attempt < 40 else { return }
        if attempt == 10 { reopen(app) }
        after(0.1) { [weak self] in self?.place(app, token: token, attempt: attempt + 1) }
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
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let app, self.currentID == tab.bundleID else { return }
                self.place(app)
            }
        }
    }

    // MARK: Editing tabs

    func add(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        add(AppTab(bundleID: id, name: app.localizedName ?? id))
    }

    func add(_ tab: AppTab) {
        if !tabs.contains(tab) {
            updateCurrent { $0.tabs.append(tab) }
        }
        select(tab)
    }

    func remove(_ tab: AppTab) {
        updateCurrent {
            $0.tabs.removeAll { $0 == tab }
            if $0.lastBundleID == tab.bundleID { $0.lastBundleID = nil }
        }
        if currentID == tab.bundleID { currentID = nil }
        runningApp(tab.bundleID)?.unhide()
    }

    func move(_ tab: AppTab, by offset: Int) {
        updateCurrent { ws in
            guard let i = ws.tabs.firstIndex(of: tab), ws.tabs.indices.contains(i + offset) else { return }
            ws.tabs.swapAt(i, i + offset)
        }
    }

    func quit(_ tab: AppTab) {
        runningApp(tab.bundleID)?.terminate()
    }

    /// Running regular apps that are not yet in the current workspace.
    func candidates() -> [NSRunningApplication] {
        let existing = Set(tabs.map(\.bundleID))
        return NSWorkspace.shared.runningApplications
            .filter {
                guard let id = $0.bundleIdentifier else { return false }
                return $0.activationPolicy == .regular
                    && id != Bundle.main.bundleIdentifier
                    && !existing.contains(id)
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    func chooseApplication() {
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
            add(AppTab(bundleID: id, name: name))
        }
    }

    /// Un-hides every app of every workspace, so quitting TabStack never leaves apps invisible.
    func unhideAll() {
        for tab in workspaces.flatMap(\.tabs) { runningApp(tab.bundleID)?.unhide() }
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

    // MARK: Observation

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRunning()
        }
        // Keep the highlight in sync when the user switches with ⌘Tab or the Dock,
        // and fit that app's window next to the sidebar.
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier
            else { return }
            if let p = self.pending {
                if p.id == id || Date() > p.until {
                    self.pending = nil
                } else {
                    // Focus briefly passing through another app during our own switch.
                    return
                }
            }
            guard self.tabs.contains(where: { $0.bundleID == id }),
                  self.currentID != id,
                  !app.isHidden,
                  AX.isTrusted
            else { return }
            self.currentID = id
            self.updateCurrent { $0.lastBundleID = id }
            self.place(app)
        }
    }

    private func refreshRunning() {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if ids != runningIDs { runningIDs = ids }
    }

    private func tick() {
        let t = AX.isTrusted
        if t != trusted { trusted = t }
        guard t else { return }
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
        currentID = currentWorkspace.lastBundleID
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
    static func prompt(title: String, message: String, value: String) -> String? {
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
        return text.isEmpty ? nil : text
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
