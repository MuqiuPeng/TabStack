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
    /// How to reopen this window after a restart (folder, URLs or file).
    var reopen: Reopen?
    /// Shown side by side with this tab (same workspace) on a wide display: this one on
    /// the left, that one on the right. The sidebar shows the pair as one tab.
    var pairedWith: UUID?
    /// The window is also a tab in other workspaces (a chat app you want everywhere). Such
    /// tabs may re-bind to the same window after a restart instead of competing for it.
    var shared: Bool?

    init(bundleID: String, name: String, title: String? = nil, windowID: CGWindowID? = nil) {
        self.id = UUID()
        self.bundleID = bundleID
        self.name = name
        self.title = title
        self.windowID = windowID
    }

    enum CodingKeys: String, CodingKey { case id, bundleID, name, customName, title, windowID, reopen, pairedWith, shared }

    /// Also reads tabs saved by the app-level version (no id / window fields).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        bundleID = try c.decode(String.self, forKey: .bundleID)
        name = try c.decode(String.self, forKey: .name)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        windowID = try c.decodeIfPresent(CGWindowID.self, forKey: .windowID)
        reopen = try c.decodeIfPresent(Reopen.self, forKey: .reopen)
        pairedWith = try c.decodeIfPresent(UUID.self, forKey: .pairedWith)
        shared = try c.decodeIfPresent(Bool.self, forKey: .shared)
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
    /// Always among the workspaces the sidebar shows.
    var pinned: Bool?
    /// When it was used (seconds since 1970), newest last; feeds the frecency ranking.
    var usage: [Double]?
    /// Claude Code session (local_…) Claude showed when this workspace was last left, shown
    /// again on return; nil until then (a session is picked by project folder).
    var claudeSession: String?
}

/// Which workspaces the sidebar shows: only a few are kept at hand, the rest stay saved and
/// are reached through search (⌃⌥F). The choice is "frecency", as browsers rank their
/// address-bar suggestions: every use counts, and its weight halves every few days.
enum Frecency {
    static let halfLife: Double = 3 * 24 * 3600
    static let keep = 60
    /// While you stay in a workspace, another use is counted this often.
    static let dwellInterval: Double = 10 * 60

    static var limit: Int {
        let n = UserDefaults.standard.integer(forKey: "activeWorkspaceLimit")
        return n > 0 ? n : 5
    }

    static func score(_ ws: Workspace, now: Double = Date().timeIntervalSince1970) -> Double {
        (ws.usage ?? []).reduce(0) { $0 + pow(0.5, max(0, now - $1) / halfLife) }
    }

    /// How well `query` names a workspace: 0 = no match. Prefix beats word start beats
    /// substring beats letters in order; a tab title match counts a little.
    static func match(_ query: String, _ ws: Workspace) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 1 }
        let name = ws.name.lowercased()
        if name == q { return 10 }
        if name.hasPrefix(q) { return 8 }
        if name.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(where: { $0.hasPrefix(q) }) { return 6 }
        if name.contains(q) { return 5 }
        if let gaps = subsequenceGaps(q, in: name) { return max(1, 4 - Double(gaps) * 0.3) }
        if ws.tabs.contains(where: { $0.displayName.lowercased().contains(q) || $0.name.lowercased().contains(q) }) { return 1.5 }
        return 0
    }

    /// Letters of `q` appear in order in `s`; returns how many letters were skipped between them.
    private static func subsequenceGaps(_ q: String, in s: String) -> Int? {
        var gaps = 0, started = false
        var it = s.makeIterator()
        for c in q {
            var found = false
            while let x = it.next() {
                if x == c { found = true; break }
                if started { gaps += 1 }
            }
            if !found { return nil }
            started = true
        }
        return gaps
    }
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

    /// Set by the app delegate, which owns the panels.
    var onToggleSidebar: (() -> Void)?
    /// Opens the settings window, optionally on a workspace. Set by the app delegate.
    var onOpenSettings: ((UUID?) -> Void)?
    /// Opens the workspace search (⌃⌥F). Set by the app delegate.
    var onSearch: (() -> Void)?
    /// Widens the sidebar into the workspace columns (or closes them). Set by the app delegate.
    var onExpandSidebar: (() -> Void)?
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
        static let displays = "displays"
        static let focusedDisplay = "focusedDisplay"
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

    // MARK: Shown workspaces

    /// The workspaces the sidebar, hotkeys and menus show (in the user's order). Chosen
    /// only at switches, so the list never shuffles while you are just working.
    @Published private(set) var activeIDs: Set<UUID> = []

    var activeWorkspaces: [Workspace] { workspaces.filter { activeIDs.contains($0.id) } }
    var storedWorkspaces: [Workspace] { workspaces.filter { !activeIDs.contains($0.id) } }

    /// Current + pinned first, then the highest frecency, up to the limit.
    func recomputeActive() {
        let now = Date().timeIntervalSince1970
        var chosen: [UUID] = [currentWorkspaceID]
        for ws in workspaces where otherDisplay(showing: ws.id) != nil && !chosen.contains(ws.id) { chosen.append(ws.id) }
        for ws in workspaces where ws.pinned == true && !chosen.contains(ws.id) { chosen.append(ws.id) }
        let ranked = workspaces.enumerated()
            .filter { !chosen.contains($0.element.id) }
            .sorted { a, b in
                let sa = Frecency.score(a.element, now: now), sb = Frecency.score(b.element, now: now)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
        for (_, ws) in ranked where chosen.count < Frecency.limit { chosen.append(ws.id) }
        let set = Set(chosen)
        if set != activeIDs { activeIDs = set }
    }

    private func recordUse(_ id: UUID) {
        let now = Date().timeIntervalSince1970
        guard let i = workspaces.firstIndex(where: { $0.id == id }) else { return }
        var usage = workspaces[i].usage ?? []
        usage.append(now)
        if usage.count > Frecency.keep { usage.removeFirst(usage.count - Frecency.keep) }
        workspaces[i].usage = usage
        save()
    }

    func setPinned(_ id: UUID, _ pinned: Bool) {
        update(id) { $0.pinned = pinned ? true : nil }
        recomputeActive()
    }

    /// Search results: with no query, every workspace by frecency (the recommendation);
    /// otherwise by how well the name matches, weighted by frecency.
    func searchWorkspaces(_ query: String) -> [Workspace] {
        let now = Date().timeIntervalSince1970
        return workspaces.enumerated()
            .map { (ws: $0.element, offset: $0.offset, match: Frecency.match(query, $0.element),
                    frecency: Frecency.score($0.element, now: now)) }
            .filter { $0.match > 0 }
            .sorted { a, b in
                let sa = a.match * (1 + log1p(a.frecency)), sb = b.match * (1 + log1p(b.frecency))
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.ws)
    }

    // MARK: Closing a window (⌃⌥D)

    /// Closes the focused window and removes every tab bound to it; then, like closing a
    /// browser tab, shows the neighboring tab.
    func closeFocusedWindow() {
        guard AX.isTrusted else { AX.requestTrust(); return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let w = AX.focusedWindow(pid: app.processIdentifier) else { NSSound.beep(); return }
        let title = AX.title(w)
        var next: AppTab?
        if let id = AX.windowID(w) {
            if let i = tabs.firstIndex(where: { $0.windowID == id }), tabs[i].id == currentID, tabs.count > 1 {
                next = i + 1 < tabs.count ? tabs[i + 1] : tabs[i - 1]
            }
            for ws in workspaces {
                for tab in ws.tabs where tab.windowID == id { removeTab(tab.id, from: ws.id) }
            }
        }
        guard AX.close(w) else { NSSound.beep(); return }
        HUD.shared.show(title: "已关闭", subtitle: title.isEmpty ? app.localizedName : title,
                        icon: app.bundleIdentifier.map { icon(for: $0) })
        if let next { after(0.3) { [weak self] in self?.select(next) } }
    }

    /// Drag-to-reorder in the sidebar: puts `tabID` where `targetID` is.
    func moveTab(_ tabID: UUID, onto targetID: UUID) {
        updateCurrent { ws in
            guard let from = ws.tabs.firstIndex(where: { $0.id == tabID }),
                  let to = ws.tabs.firstIndex(where: { $0.id == targetID }), from != to else { return }
            ws.tabs.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    var tabs: [AppTab] { currentWorkspace.tabs }

    var currentTab: AppTab? { tabs.first { $0.id == currentID } }

    private func updateCurrent(_ change: (inout Workspace) -> Void) {
        guard let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return }
        change(&workspaces[i])
        save()
    }

    /// Applies `change` to the tab with this id, in whichever workspace holds it.
    func updateTab(_ id: UUID, _ change: (inout AppTab) -> Void) {
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
        currentID = primary(of: tab).id
        updateCurrent { $0.lastTabID = tab.id } // which half of a pair had focus
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
        guard currentID == primary(of: tab).id else { return } // superseded by a newer switch

        // Activate the target *before* hiding the others: hiding the frontmost app makes
        // macOS hand focus to some other app first.
        if let app = runningApp(tab.bundleID) {
            app.unhide()
            AX.activate(app)
            syncClaudeSession(showing: tab)
            place(tab)
        } else {
            launch(tab)
        }

        // Other apps are hidden. Other tabs of the *same* app can't be hidden one by one;
        // they share the content frame, so the raised window simply covers them.
        var shown: Set<String> = [tab.bundleID]
        if isWide(focusedDisplay), let p = partner(of: tab) { shown.insert(p.bundleID) }
        let others = Set(tabs.map(\.bundleID) + alsoHide).subtracting(shown)
            .subtracting(appsOnOtherDisplays)
        for id in others { runningApp(id)?.hide() }
    }

    func selectIndex(_ index: Int) {
        let shown = shownTabs(currentWorkspace)
        guard shown.indices.contains(index) else { return }
        select(shown[index])
    }

    /// Moves to the previous (-1) or next (+1) tab of the current workspace, wrapping around.
    @discardableResult
    func cycleTab(_ offset: Int) -> AppTab? {
        let tabs = shownTabs(currentWorkspace)
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
        let shown = activeWorkspaces
        guard shown.count > 1,
              let i = shown.firstIndex(where: { $0.id == currentWorkspaceID }) else { return nil }
        let ws = shown[wrap(i + offset, shown.count)]
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

        // Shown on another display already: the two displays trade workspaces, windows and all.
        let swapDisplay = otherDisplay(showing: id)
        let leftID = currentWorkspaceID
        if let d = swapDisplay { otherDisplays[d] = DisplayState(workspace: leftID, tab: currentID) }

        rememberClaudeSession(leaving: leftID)
        let keep = Set(next.tabs.map(\.bundleID)).union(appsOnOtherDisplays)
        let leaving = Array(Set(tabs.map(\.bundleID)).subtracting(keep))
        currentWorkspaceID = id
        currentID = nil
        recordUse(id)
        recomputeActive()
        save()

        let target = next.tabs.first(where: { $0.id == tabID })
            ?? next.tabs.first(where: { $0.id == next.lastTabID }) ?? next.tabs.first
        if let d = swapDisplay {
            gather(leftID, onto: d, raise: otherDisplays[d]?.tab)
            gather(id, onto: focusedDisplay, except: target?.id)
        }
        if let target {
            select(target, alsoHide: leaving)
            if UserDefaults.standard.object(forKey: "restoreOnSwitch") as? Bool ?? true {
                after(0.6) { [weak self] in self?.restoreMissingWindows(in: id, except: target.id) }
            }
        } else {
            // Empty workspace: nothing to show, just put the old set away.
            for id in leaving { runningApp(id)?.hide() }
        }
    }

    func switchWorkspace(index: Int) {
        let shown = activeWorkspaces
        guard shown.indices.contains(index) else { return }
        switchWorkspace(shown[index].id)
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
        switchWorkspace(fallbackWorkspace(for: removed))
        workspaces.removeAll { $0.id == removed }
        assignDisplays()
        save()
        recomputeActive()
        syncWatcher()
    }

    func moveCurrentWorkspace(by offset: Int) {
        guard let i = workspaces.firstIndex(where: { $0.id == currentWorkspaceID }) else { return }
        let j = i + offset
        guard workspaces.indices.contains(j) else { return }
        workspaces.swapAt(i, j)
        save()
    }

    // MARK: Windows of a tab

    var allTabs: [AppTab] { workspaces.flatMap(\.tabs) }

    /// Windows that some tab (in any workspace) is bound to.
    func claimedWindowIDs(except tabID: UUID? = nil) -> Set<CGWindowID> {
        // Claude's one window is shared: each workspace's Claude tab shows it on its own session.
        // Shared tabs of one app don't take a window away from each other either.
        let me = tabID.flatMap { id in allTabs.first { $0.id == id } }
        return Set(allTabs.filter { t in
            t.id != tabID && t.bundleID != ClaudeSessions.bundleID
                && !(me?.shared == true && t.shared == true && t.bundleID == me?.bundleID)
        }.compactMap(\.windowID))
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
        /// A restore was started (or is in progress) and its window hasn't appeared yet.
        case restoring
        /// The app has no windows at all (yet).
        case noWindows
        /// Every window of the app already belongs to another tab.
        case allClaimed
        /// Nothing matches and the tab knows how to reopen its own window, so it must not
        /// grab an unrelated one (background passes only).
        case unmatched
    }

    /// Restores in flight: windows the app had before (anything else is new) and when to
    /// give up. `background` restores hide their app once the window is bound.
    private var restoring: [UUID: (before: Set<CGWindowID>, until: Date, wasRunning: Bool, background: Bool)] = [:]

    func isRestorable(_ tab: AppTab) -> Bool { !(tab.reopen?.isEmpty ?? true) }

    /// Finds the tab's window, re-binding an unbound tab when needed. `interactive` (the user
    /// asked for this tab) may start a restore; background passes only recognize windows.
    private func resolve(_ tab: AppTab, pid: pid_t, interactive: Bool) -> Resolution {
        let windows = AX.windows(pid: pid)
        if let id = tab.windowID, let w = windows.first(where: { AX.windowID($0) == id }) {
            return .window(w)
        }
        var claimed = claimedWindowIDs(except: tab.id)
        // A window that appeared during another tab's restore is that tab's: terminals
        // all open with the same title, so a title match alone would steal it.
        for (other, r) in restoring where other != tab.id && r.wasRunning
            && allTabs.first(where: { $0.id == other })?.bundleID == tab.bundleID {
            claimed.formUnion(windows.compactMap(AX.windowID).filter { !r.before.contains($0) })
        }
        let free = windows.filter { AX.windowID($0).map { !claimed.contains($0) } ?? false }

        // 1. A window that is recognizably this tab's (title, project folder, file, URLs).
        if let w = match(tab, among: free) { return bindResolved(tab, w) }

        // 2. A window that appeared since our restore started.
        if let r = restoring[tab.id] {
            if AppKind.of(tab.bundleID) != .editor, r.wasRunning,
               let w = free.first(where: { AX.windowID($0).map { !r.before.contains($0) } ?? false }) {
                return bindResolved(tab, w)
            }
            if Date() < r.until { return .restoring }
            restoring[tab.id] = nil
        }

        // 3. Reopen what the tab remembers instead of taking someone else's window.
        if isRestorable(tab) {
            guard interactive else { return .unmatched }
            startRestore(tab, background: false)
            return .restoring
        }

        // 4. Apps without a recipe: any free window will do.
        if windows.isEmpty { return .noWindows }
        guard let pick = free.first else { return .allClaimed }
        return bindResolved(tab, pick)
    }

    private func bindResolved(_ tab: AppTab, _ w: AXUIElement) -> Resolution {
        guard let id = AX.windowID(w) else { return .unmatched }
        bind(tab.id, to: id, title: AX.title(w))
        if let r = restoring.removeValue(forKey: tab.id), r.background { settleRestored(tab, w) }
        return .window(w)
    }

    /// A window restored in the background opens wherever its app puts it (a terminal:
    /// small, top left). Fit it into its workspace's content area like the others; then
    /// keep it out of the way: hide its app, or, when that app is on screen, put the
    /// window that was in front back on top.
    private func settleRestored(_ tab: AppTab, _ w: AXUIElement) {
        let ws = workspace(containing: tab.id)
        let display = ws.flatMap { $0.id == currentWorkspaceID ? focusedDisplay : otherDisplay(showing: $0.id) }
            ?? focusedDisplay
        if let frame = frame(for: tab, on: display).map(AX.toAX), !AX.isFullScreen(w) {
            AX.setFrame(w, frame, center: false)
        }
        let onScreen = Set([currentTab, currentTab.flatMap(partner)].compactMap { $0?.bundleID })
            .union(appsOnOtherDisplays)
        if !onScreen.contains(tab.bundleID) {
            runningApp(tab.bundleID)?.hide()
            return
        }
        // Same app as what is showing: raise the shown windows again, the selected one last.
        var front: [AppTab] = otherDisplays.values.compactMap { s in allTabs.first { $0.id == s.tab } }
        if let cur = currentTab {
            let focused = currentWorkspace.tabs.first { $0.id == currentWorkspace.lastTabID } ?? cur
            front += [cur, partner(of: cur)].compactMap { $0 }.filter { $0.id != focused.id } + [focused]
        }
        for t in front where t.bundleID == tab.bundleID && t.id != tab.id {
            guard let wid = t.windowID, let app = runningApp(t.bundleID),
                  let win = AX.windows(pid: app.processIdentifier).first(where: { AX.windowID($0) == wid }) else { continue }
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        }
    }

    /// The free window that is recognizably this tab's, if any.
    private func match(_ tab: AppTab, among free: [AXUIElement]) -> AXUIElement? {
        if let t = tab.title, !t.isEmpty, let w = free.first(where: { AX.title($0) == t }) { return w }
        guard let reopen = tab.reopen else { return nil }

        if let folder = reopen.folder {
            let name = (folder as NSString).lastPathComponent
            if let w = free.first(where: { Restore.editorRootName(fromTitle: AX.title($0)) == name }) { return w }
        }
        if let doc = reopen.document, let w = free.first(where: { Restore.document(of: $0) == doc }) {
            return w
        }
        if let urls = reopen.urls, !urls.isEmpty, let cache = browserCache[tab.bundleID]?.windows {
            let wanted = Set(urls)
            var best: (AXUIElement, Int)?
            for w in free {
                guard let entry = browserEntry(forWindowTitle: AX.title(w), in: cache) else { continue }
                let overlap = wanted.intersection(entry.urls).count
                if overlap > 0, overlap > (best?.1 ?? 0) { best = (w, overlap) }
            }
            if let best { return best.0 }
        }
        return nil
    }

    /// Opens the tab's window again from its recipe, or launches its app.
    private func startRestore(_ tab: AppTab, background: Bool) {
        let app = runningApp(tab.bundleID)
        let before = app.map { Set(AX.windows(pid: $0.processIdentifier).compactMap(AX.windowID)) } ?? []
        restoring[tab.id] = (before, Date().addingTimeInterval(12), app != nil, background)
        if let reopen = tab.reopen, Restore.perform(reopen, bundleID: tab.bundleID, activate: !background) {
            return
        }
        if app == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tab.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = !background
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
    }

    /// Brings back every missing window of a workspace (e.g. after a restart), one after
    /// another so new windows can be told apart.
    func restoreMissingWindows(in workspaceID: UUID, except skip: UUID? = nil) {
        guard AX.isTrusted, let ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        bindUnboundTabs()
        let missing = ws.tabs.filter { tab in
            tab.id != skip && !isBound(tab) && restoring[tab.id] == nil
                && (isRestorable(tab) || !runningIDs.contains(tab.bundleID))
        }
        for (i, tab) in missing.enumerated() {
            after(Double(i) * 1.2) { [weak self] in
                guard let self, let live = self.allTabs.first(where: { $0.id == tab.id }), !self.isBound(live)
                else { return }
                self.startRestore(live, background: true)
            }
        }
        // Bind the restored windows as they show up.
        for delay in stride(from: 1.5, through: Double(missing.count) * 1.2 + 8, by: 1.5) {
            after(delay) { [weak self] in self?.bindUnboundTabs() }
        }
    }

    /// Binds every tab that has no live window to a window it recognizes. Never opens
    /// windows; runs in the background so tabs settle after restarts without a click.
    func bindUnboundTabs() {
        guard AX.isTrusted else { return }
        refreshLiveWindows()
        // Tabs that remember a title go first, so they get their own window back.
        let unbound = allTabs.filter { !isBound($0) && runningIDs.contains($0.bundleID) }
            .sorted { ($0.title?.isEmpty == false ? 0 : 1) < ($1.title?.isEmpty == false ? 0 : 1) }
        for tab in unbound {
            guard let app = runningApp(tab.bundleID) else { continue }
            _ = resolve(tab, pid: app.processIdentifier, interactive: false)
        }
    }

    private func bind(_ tabID: UUID, to windowID: CGWindowID, title: String) {
        updateTab(tabID) {
            $0.windowID = windowID
            $0.title = title
        }
        liveWindowIDs.insert(windowID)
    }

    // MARK: Reopen recipes

    /// Last seen windows of each running browser (title + tab URLs), read via AppleScript.
    private var browserCache: [String: (time: Date, windows: [(title: String, urls: [String])])] = [:]
    private var browserReads: Set<String> = []

    private func refreshBrowserCache(_ bundleID: String, then done: (() -> Void)? = nil) {
        guard !browserReads.contains(bundleID) else { return }
        browserReads.insert(bundleID)
        // NSAppleScript is main-thread only; deferred so it never runs inside a caller's work.
        DispatchQueue.main.async { [weak self] in
            let windows = Restore.browserWindows(bundleID: bundleID)
            guard let self else { return }
            self.browserReads.remove(bundleID)
            self.browserCache[bundleID] = (Date(), windows)
            done?()
        }
    }

    /// The scripted browser window behind an AX window. Chrome's AX title is the active
    /// tab's title plus extras (" - Google Chrome – <profile>", tab group), so it matches
    /// by prefix; the longest title wins.
    private func browserEntry(forWindowTitle axTitle: String,
                              in cache: [(title: String, urls: [String])]) -> (title: String, urls: [String])? {
        if let hit = cache.filter({ !$0.title.isEmpty && axTitle.hasPrefix($0.title) })
            .max(by: { $0.title.count < $1.title.count }) { return hit }
        // A page that failed to load has no title; Chrome then titles the window with its
        // address minus the scheme.
        return cache.first { entry in
            entry.title.isEmpty && entry.urls.contains { url in
                let bare = url.replacingOccurrences(of: "^[a-z]+://", with: "", options: .regularExpression)
                return !bare.isEmpty && axTitle.trimmingCharacters(in: .whitespaces).hasPrefix(bare)
            }
        }
    }

    /// Records, for every bound tab, how to reopen its window later.
    private func captureRecipes() {
        guard AX.isTrusted else { return }
        let bound = allTabs.filter(isBound)
        for bundleID in Set(bound.map(\.bundleID)) {
            guard let app = runningApp(bundleID) else { continue }
            var byID: [CGWindowID: AXUIElement] = [:]
            for w in AX.windows(pid: app.processIdentifier) { if let id = AX.windowID(w) { byID[id] = w } }
            let tabs = bound.filter { $0.bundleID == bundleID }

            switch AppKind.of(bundleID) {
            case .editor:
                for tab in tabs {
                    guard let id = tab.windowID, let w = byID[id],
                          let folder = Restore.editorFolder(window: w, title: AX.title(w), bundleID: bundleID),
                          tab.reopen?.folder != folder else { continue }
                    updateTab(tab.id) { $0.reopen = Reopen(folder: folder) }
                }
            case .browser:
                refreshBrowserCache(bundleID) { [weak self] in
                    guard let self, let cache = self.browserCache[bundleID]?.windows else { return }
                    for tab in tabs {
                        guard let id = tab.windowID, let w = byID[id] else { continue }
                        guard let urls = self.browserEntry(forWindowTitle: AX.title(w), in: cache)?.urls, !urls.isEmpty,
                              self.allTabs.first(where: { $0.id == tab.id })?.reopen?.urls != urls else { continue }
                        self.updateTab(tab.id) { $0.reopen = Reopen(urls: urls) }
                    }
                }
            case .other:
                for tab in tabs {
                    guard let id = tab.windowID, let w = byID[id],
                          let doc = Restore.document(of: w), tab.reopen?.document != doc else { continue }
                    updateTab(tab.id) { $0.reopen = Reopen(document: doc) }
                }
            }
        }
    }

    // MARK: Placement

    /// Re-fits the current tab after the screen layout changed or the sidebar was toggled.
    func layoutChanged() {
        for (d, state) in otherDisplays { gather(state.workspace, onto: d, raise: state.tab) }
        guard let shown = currentTab else { return }
        // Of a pair, keep the half that had focus in front.
        let tab = currentWorkspace.tabs.first { $0.id == currentWorkspace.lastTabID && primary(of: $0).id == shown.id } ?? shown
        guard let app = runningApp(tab.bundleID), !app.isHidden else { return }
        place(tab)
    }

    /// The area windows are fitted into: the screen's visible frame (no menu bar / Dock)
    /// minus the sidebar when it is shown.
    private var contentFrameCocoa: NSRect? { contentFrame(on: focusedDisplay) }

    func contentFrame(on display: DisplayKey) -> NSRect? {
        guard let screen = Displays.screen(display) ?? NSScreen.screens.first else { return nil }
        var frame = screen.visibleFrame
        if sidebarShown {
            frame.origin.x += Layout.sidebarWidth
            frame.size.width -= Layout.sidebarWidth
        }
        return frame
    }


    /// Fits the tab's window into the content area and raises it. A window that is gone is
    /// restored from the tab's recipe; apps that are still launching are retried for a while.
    private func place(_ tab: AppTab) {
        placeToken += 1
        // A pair on a wide display: the other half first, so `tab` ends up focused.
        if isWide(focusedDisplay), let p = partner(of: tab), runningApp(p.bundleID) != nil {
            place(tabID: p.id, token: placeToken, attempt: 0, focus: false)
        }
        place(tabID: tab.id, token: placeToken, attempt: 0)
    }

    /// `focus` is false for the other half of a pair: raised, but not made the app's main window.
    private func place(tabID: UUID, token: Int, attempt: Int, focus: Bool = true) {
        guard token == placeToken else { return }
        guard let tab = allTabs.first(where: { $0.id == tabID }),
              let frame = frame(for: tab, on: focusedDisplay).map(AX.toAX)
        else { SwitchCurtain.shared.reveal(); return }

        guard let app = runningApp(tab.bundleID), !app.isTerminated else {
            // App still starting from a restore: keep waiting for it.
            if restoring[tabID] != nil, attempt >= 0, attempt < 100 {
                after(0.15) { [weak self] in self?.place(tabID: tabID, token: token, attempt: attempt + 1, focus: focus) }
            } else {
                SwitchCurtain.shared.reveal()
            }
            return
        }

        switch resolve(tab, pid: app.processIdentifier, interactive: attempt >= 0) {
        case .window(let w):
            // A full-screen window lives in its own Space; leave it alone.
            if AX.isFullScreen(w) { SwitchCurtain.shared.reveal(); return }
            app.unhide()
            // Passes: 0 (now), -1 and -2 (follow-ups). Some apps (Chrome) apply a move or
            // resize a moment later and report the old frame until then, so centering a
            // window that refuses the size waits for the last pass.
            AX.setFrame(w, frame, center: attempt == -2)
            // Activating an app brings all its windows forward, on every display; put
            // the other displays' own windows back on top first, then this one.
            raiseOtherDisplays()
            if focus {
                AX.raise(w)
                // Raising the other half of a pair can hand it the focus; take it back.
                if attempt < 0, !app.isActive { AX.activate(app) }
            } else {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
            if attempt >= 0 {
                SwitchCurtain.shared.reveal()
                // Follow-ups catch apps that reposition themselves while un-hiding.
                after(0.25) { [weak self] in self?.place(tabID: tabID, token: token, attempt: -1, focus: focus) }
            } else if attempt == -1 {
                after(0.3) { [weak self] in self?.place(tabID: tabID, token: token, attempt: -2, focus: focus) }
            }

        case .restoring:
            guard attempt >= 0, attempt < 100 else { SwitchCurtain.shared.reveal(); return }
            if attempt == 0 {
                SwitchCurtain.shared.reveal()
                HUD.shared.show(title: "正在恢复 \(tab.displayName)", subtitle: tab.reopen?.summary,
                                icon: icon(for: tab.bundleID))
            }
            if AppKind.of(tab.bundleID) == .browser, attempt % 6 == 5 { refreshBrowserCache(tab.bundleID) }
            after(0.15) { [weak self] in self?.place(tabID: tabID, token: token, attempt: attempt + 1, focus: focus) }

        case .allClaimed, .unmatched:
            SwitchCurtain.shared.reveal()
            HUD.shared.show(title: "\(tab.name) 没有空闲的窗口",
                            subtitle: "这个标签的窗口已关闭，请在 \(tab.name) 里新建一个窗口",
                            icon: icon(for: tab.bundleID))

        case .noWindows:
            guard attempt >= 0, attempt < 40 else { SwitchCurtain.shared.reveal(); return }
            if attempt == 10 { reopen(app) }
            after(0.1) { [weak self] in self?.place(tabID: tabID, token: token, attempt: attempt + 1, focus: focus) }
        }
    }

    private func reopen(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    private func launch(_ tab: AppTab) {
        if isRestorable(tab) {
            startRestore(tab, background: false)
            place(tab)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tab.bundleID) else {
            NSSound.beep()
            SwitchCurtain.shared.reveal()
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, app != nil, self.currentID == self.primary(of: tab).id else { return }
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
        let shown = shownTabs(currentWorkspace)
        guard let i = shown.firstIndex(of: tab), shown.indices.contains(i + offset) else { return }
        moveTab(tab.id, onto: shown[i + offset].id)
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

    func update(_ workspaceID: UUID, _ change: (inout Workspace) -> Void) {
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
        ws.usage = [Date().timeIntervalSince1970]
        workspaces.append(ws)
        save()
        recomputeActive()
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

    /// Deletes without asking (the control socket); leaves it first if it is current.
    func removeWorkspace(_ id: UUID) {
        guard workspaces.count > 1 else { return }
        if id == currentWorkspaceID { switchWorkspace(fallbackWorkspace(for: id)) }
        workspaces.removeAll { $0.id == id }
        assignDisplays()
        save()
        recomputeActive()
        syncWatcher()
    }

    /// Deletes after confirmation; leaving the current workspace first if needed.
    func deleteWorkspace(_ id: UUID) {
        guard workspaces.count > 1, let ws = workspaces.first(where: { $0.id == id }),
              Dialogs.confirm(title: "删除工作区“\(ws.name)”？", message: "只删除这组标签，不会关闭其中的窗口或应用。")
        else { return }
        if id == currentWorkspaceID { switchWorkspace(fallbackWorkspace(for: id)) }
        workspaces.removeAll { $0.id == id }
        assignDisplays()
        save()
        recomputeActive()
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

    /// Opens a fresh window of a Finder/terminal/browser app and adds it to `workspaceID`
    /// once it appears.
    func createWindow(_ target: NewWindowTarget, in workspaceID: UUID) {
        openNewWindow(bundleID: target.bundleID, in: workspaceID, trigger: { NewWindow.open(target) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tab):
                if target.bundleID == "com.apple.finder", let app = self.runningApp(tab.bundleID) {
                    // A new Finder window opens on 前往文件夹 so you can type where to go.
                    self.after(0.6) { NewWindow.showGoToFolder(pid: app.processIdentifier) }
                }
            case .failure(let error):
                HUD.shared.show(title: error.message, icon: self.icon(for: target.bundleID))
            }
        }
    }

    struct OpenError: Error { let message: String }

    /// Runs `trigger` (which should make `bundleID` open a window), waits for the new window
    /// and adds it as a tab of `workspaceID`. `fallback` may pick an existing window when the
    /// app reused one instead (VS Code focuses a folder that is already open).
    func openNewWindow(bundleID: String, in workspaceID: UUID, name: String? = nil, reopen: Reopen? = nil,
                       timeout: TimeInterval = 10, trigger: () -> Bool,
                       fallback: (() -> AXUIElement?)? = nil,
                       completion: @escaping (Result<AppTab, OpenError>) -> Void) {
        let appName = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? bundleID
        let before: Set<CGWindowID> = runningApp(bundleID).map {
            Set(AX.windows(pid: $0.processIdentifier).compactMap(AX.windowID))
        } ?? []
        guard trigger() else { completion(.failure(OpenError(message: "无法让\(appName)打开新窗口"))); return }
        let deadline = Date().addingTimeInterval(timeout)
        func finish(_ w: AXUIElement, _ app: NSRunningApplication) {
            guard let id = AX.windowID(w) else { return }
            addWindow(id, title: AX.title(w), of: app, to: workspaceID)
            guard let tab = workspaces.first(where: { $0.id == workspaceID })?.tabs.first(where: { $0.windowID == id })
            else { completion(.failure(OpenError(message: "窗口已打开，但没能加入工作区"))); return }
            if name != nil || reopen != nil {
                updateTab(tab.id) { t in
                    if let name { t.customName = name }
                    if let reopen { t.reopen = reopen }
                }
            }
            completion(.success(allTabs.first { $0.id == tab.id } ?? tab))
        }
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                if let app = self.runningApp(bundleID),
                   let w = AX.windows(pid: app.processIdentifier).first(where: {
                       guard let id = AX.windowID($0) else { return false }
                       return !before.contains(id)
                   }) {
                    finish(w, app)
                    return
                }
                // Past half the wait, accept a window the app reused instead of opening one.
                if Date() > deadline.addingTimeInterval(-timeout / 2), let app = self.runningApp(bundleID),
                   let w = fallback?() {
                    finish(w, app)
                    return
                }
                if Date() < deadline { poll() } else {
                    completion(.failure(OpenError(message: "没有等到新的\(appName)窗口")))
                }
            }
        }
        poll()
    }

    /// Windows that are tabs in other workspaces but not in `workspaceID`, one entry each.
    func windowsInOtherWorkspaces(than workspaceID: UUID) -> [(tab: AppTab, workspace: Workspace)] {
        let here = Set(workspaces.first { $0.id == workspaceID }?.tabs.compactMap(\.windowID) ?? [])
        var seen = Set<CGWindowID>()
        var out: [(AppTab, Workspace)] = []
        for ws in workspaces where ws.id != workspaceID {
            for tab in ws.tabs {
                guard let id = tab.windowID, isBound(tab), !here.contains(id), seen.insert(id).inserted else { continue }
                out.append((tab, ws))
            }
        }
        return out
    }

    /// Also shows another workspace's window in `workspaceID`: both keep a tab for it.
    func shareWindow(of tab: AppTab, into workspaceID: UUID) {
        guard let windowID = tab.windowID else { return }
        updateTab(tab.id) { $0.shared = true }
        var copy = AppTab(bundleID: tab.bundleID, name: tab.name, title: tab.title, windowID: windowID)
        copy.reopen = tab.reopen
        copy.shared = true
        update(workspaceID) { ws in
            guard !ws.tabs.contains(where: { $0.windowID == windowID }) else { return }
            ws.tabs.append(copy)
        }
        syncWatcher()
        if workspaceID == currentWorkspaceID, let added = tabs.first(where: { $0.windowID == windowID }) {
            select(added)
        }
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
              let w = AX.focusedWindow(pid: pid), let wid = AX.windowID(w)
        else { return }
        if bundleID == ClaudeSessions.bundleID { claudeVisited = currentWorkspaceID }
        // Working in a window on another display moves the focus (hotkeys, menus) there.
        if let d = display(ofWindow: wid, w) { focusDisplay(d) }
        guard tabs.contains(where: { $0.bundleID == bundleID }) else { return }
        refreshLiveWindows()

        if let tab = tabs.first(where: { $0.windowID == wid }) {
            let rep = primary(of: tab)
            guard currentID != rep.id else {
                // Focus moved within the pair: just remember the side.
                if currentWorkspace.lastTabID != tab.id { updateCurrent { $0.lastTabID = tab.id } }
                return
            }
            currentID = rep.id
            updateCurrent { $0.lastTabID = tab.id }
            place(tab)
        } else if let tab = tabs.first(where: { $0.bundleID == bundleID && !isBound($0)
                    && (!isRestorable($0) || match($0, among: [w]) != nil) }),
                  !claimedWindowIDs(except: tab.id).contains(wid) {
            bind(tab.id, to: wid, title: AX.title(w))
            currentID = primary(of: tab).id
            updateCurrent { $0.lastTabID = tab.id }
            place(tab)
        }
    }

    /// Focus is watched for every running app that backs a tab in any workspace.
    func syncWatcher() {
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

    private var tickCount = 0

    private func tick() {
        tickCount += 1
        let t = AX.isTrusted
        if t != trusted {
            trusted = t
            syncWatcher()
        }
        refreshLiveWindows()
        if let last = currentWorkspace.usage?.last,
           Date().timeIntervalSince1970 - last > Frecency.dwellInterval { recordUse(currentWorkspaceID) }
        else if currentWorkspace.usage == nil { recordUse(currentWorkspaceID) }
        guard t else { return }
        bindUnboundTabs()
        refreshTitles()
        if tickCount % 5 == 1 { captureRecipes() }
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
        if let data = defaults.data(forKey: Keys.displays),
           let saved = try? JSONDecoder().decode([DisplayKey: DisplayState].self, from: data) {
            rememberedDisplays = saved
        }
        let connected = Displays.keys
        if let f = defaults.string(forKey: Keys.focusedDisplay), connected.contains(f) {
            focusedDisplay = f
        } else {
            focusedDisplay = Displays.primaryKey
        }
        assignDisplays() // also saves; persists ids given to tabs migrated from the app-level format
    }

    private func save() {
        if let data = try? JSONEncoder().encode(workspaces) {
            UserDefaults.standard.set(data, forKey: Keys.workspaces)
        }
        UserDefaults.standard.set(currentWorkspaceID.uuidString, forKey: Keys.current)
        var displays = rememberedDisplays
        for (k, state) in otherDisplays { displays[k] = state }
        displays[focusedDisplay] = DisplayState(workspace: currentWorkspaceID, tab: currentID)
        if let data = try? JSONEncoder().encode(displays) {
            UserDefaults.standard.set(data, forKey: Keys.displays)
        }
        UserDefaults.standard.set(focusedDisplay, forKey: Keys.focusedDisplay)
    }

    // MARK: Side by side

    /// Displays whose visible area is at least this wide (points) show a paired tab's two
    /// windows side by side; narrower ones show just the focused half.
    static var splitMinWidth: CGFloat {
        CGFloat(UserDefaults.standard.object(forKey: "splitMinWidth") as? Double ?? 2400)
    }

    func isWide(_ display: DisplayKey) -> Bool {
        (Displays.screen(display)?.visibleFrame.width ?? 0) >= Self.splitMinWidth
    }

    private func workspace(containing tabID: UUID) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tabID } }
    }

    /// The other half of a paired tab, if any (always in the same workspace).
    func partner(of tab: AppTab) -> AppTab? {
        guard let ws = workspace(containing: tab.id) else { return nil }
        if let id = tab.pairedWith, id != tab.id, let p = ws.tabs.first(where: { $0.id == id }) { return p }
        return ws.tabs.first { $0.pairedWith == tab.id && $0.id != tab.id }
    }

    /// The left half of the pair `tab` is in (the one the sidebar shows), or `tab` itself.
    func primary(of tab: AppTab) -> AppTab {
        if tab.pairedWith == nil, let p = partner(of: tab) { return p }
        return tab
    }

    /// The workspace's tabs as the sidebar shows them: a pair's right half is folded
    /// into its left one.
    func shownTabs(_ ws: Workspace) -> [AppTab] {
        ws.tabs.filter { t in t.pairedWith != nil || !ws.tabs.contains { $0.pairedWith == t.id && $0.id != t.id } }
    }

    /// Puts `right` next to `left` (both in the same workspace, neither paired yet).
    func pair(_ left: UUID, with right: UUID) {
        guard left != right, let ws = workspace(containing: left),
              let l = ws.tabs.first(where: { $0.id == left }), let r = ws.tabs.first(where: { $0.id == right }),
              partner(of: l) == nil, partner(of: r) == nil else { return }
        update(ws.id) { w in
            if let i = w.tabs.firstIndex(where: { $0.id == left }) { w.tabs[i].pairedWith = right }
        }
        if currentID == right { currentID = left }
        for d in otherDisplays.keys where otherDisplays[d]?.tab == right { otherDisplays[d]?.tab = left }
        if ws.id == currentWorkspaceID, currentID == left, let tab = allTabs.first(where: { $0.id == left }) {
            select(tab)
        }
    }

    /// Splits a pair back into two tabs.
    func unpair(_ tab: AppTab) {
        let p = primary(of: tab)
        updateTab(p.id) { $0.pairedWith = nil }
        layoutChanged()
    }

    /// Swaps the pair's left and right windows.
    func swapSides(_ tab: AppTab) {
        let left = primary(of: tab)
        guard let right = partner(of: left), let ws = workspace(containing: left.id) else { return }
        update(ws.id) { w in
            guard let i = w.tabs.firstIndex(where: { $0.id == left.id }),
                  let j = w.tabs.firstIndex(where: { $0.id == right.id }) else { return }
            w.tabs[i].pairedWith = nil
            w.tabs[j].pairedWith = left.id
            w.tabs.swapAt(i, j) // the pair keeps its place in the sidebar
        }
        if currentID == left.id { currentID = right.id }
        for d in otherDisplays.keys where otherDisplays[d]?.tab == left.id { otherDisplays[d]?.tab = right.id }
        layoutChanged()
    }

    /// Where a tab's window goes on a display: the whole content area, or its half when
    /// the tab is paired and the display is wide.
    func frame(for tab: AppTab, on display: DisplayKey) -> NSRect? {
        guard var f = contentFrame(on: display) else { return nil }
        guard isWide(display), partner(of: tab) != nil else { return f }
        let half = (f.width / 2).rounded(.down)
        if primary(of: tab).id != tab.id { f.origin.x += f.width - half }
        f.size.width = half
        return f
    }

    // MARK: Displays

    /// Each display shows its own workspace in its own sidebar. Hotkeys, menus and new
    /// windows act on the focused display (the one last clicked or worked in), whose
    /// workspace and tab are `currentWorkspaceID` / `currentID`.
    @Published private(set) var focusedDisplay: DisplayKey = Displays.primaryKey
    /// Workspace and selected tab of every other connected display.
    @Published private(set) var otherDisplays: [DisplayKey: DisplayState] = [:]
    /// What displays seen before showed, so a reconnected display gets its workspace back.
    private var rememberedDisplays: [DisplayKey: DisplayState] = [:]
    /// Called when the focused display changes. Set by the app delegate.
    var onFocusedDisplayChange: (() -> Void)?

    func workspaceID(on display: DisplayKey) -> UUID? {
        display == focusedDisplay ? currentWorkspaceID : otherDisplays[display]?.workspace
    }

    func selectedTabID(on display: DisplayKey) -> UUID? {
        display == focusedDisplay ? currentID : otherDisplays[display]?.tab
    }

    func workspace(on display: DisplayKey) -> Workspace? {
        workspaceID(on: display).flatMap { id in workspaces.first { $0.id == id } }
    }

    /// The other display showing this workspace, if any.
    func otherDisplay(showing id: UUID) -> DisplayKey? {
        otherDisplays.first { $0.value.workspace == id }?.key
    }

    /// Apps with a tab in a workspace on another display: switching here must not hide them.
    private var appsOnOtherDisplays: Set<String> {
        let ids = Set(otherDisplays.values.map(\.workspace))
        return Set(workspaces.filter { ids.contains($0.id) }.flatMap { $0.tabs.map(\.bundleID) })
    }

    /// The other display a focused window belongs to: by its tab, else by where it is.
    private func display(ofWindow wid: CGWindowID, _ w: AXUIElement) -> DisplayKey? {
        guard !otherDisplays.isEmpty else { return nil }
        // A shared window (Claude) may be a tab here and there; here wins.
        if tabs.contains(where: { $0.windowID == wid }) { return nil }
        for (d, state) in otherDisplays {
            if workspaces.first(where: { $0.id == state.workspace })?.tabs.contains(where: { $0.windowID == wid }) == true {
                return d
            }
        }
        if tabs.contains(where: { $0.windowID == wid }) { return nil }
        guard let p = AX.position(w), let s = AX.size(w),
              let d = Displays.key(containingAX: CGRect(origin: p, size: s)), otherDisplays[d] != nil
        else { return nil }
        return d
    }

    func focusDisplay(_ display: DisplayKey) {
        guard display != focusedDisplay, let state = otherDisplays[display] else { return }
        otherDisplays[focusedDisplay] = DisplayState(workspace: currentWorkspaceID, tab: currentID)
        otherDisplays[display] = nil
        focusedDisplay = display
        currentWorkspaceID = state.workspace
        currentID = state.tab
        save()
        onFocusedDisplayChange?()
    }

    /// Gives every connected display a workspace of its own (no two show the same one):
    /// the one it showed before if still free, else the most used free one. Call after
    /// displays come or go and after workspaces are deleted.
    func assignDisplays() {
        for (k, state) in otherDisplays { rememberedDisplays[k] = state }
        rememberedDisplays[focusedDisplay] = DisplayState(workspace: currentWorkspaceID, tab: currentID)

        let connected = Displays.keys
        if !connected.contains(focusedDisplay) {
            // The focused display went away (its windows land on the others); keep working
            // in its workspace on the primary display.
            focusedDisplay = Displays.primaryKey
            onFocusedDisplayChange?()
        }
        let exists = Set(workspaces.map(\.id))
        if !exists.contains(currentWorkspaceID) {
            currentWorkspaceID = workspaces[0].id
            currentID = currentWorkspace.lastTabID
        }

        var used: Set<UUID> = [currentWorkspaceID]
        var next: [DisplayKey: DisplayState] = [:]
        for d in connected where d != focusedDisplay {
            if let state = otherDisplays[d] ?? rememberedDisplays[d],
               exists.contains(state.workspace), !used.contains(state.workspace) {
                next[d] = state
            } else if let ws = rankedWorkspaces(excluding: used).first {
                next[d] = DisplayState(workspace: ws.id, tab: ws.lastTabID)
            } else {
                continue // fewer workspaces than displays: this one gets no sidebar
            }
            used.insert(next[d]!.workspace)
        }
        // A display that went away hands its windows to the others: put them away.
        let vanished = Set(otherDisplays.values.map(\.workspace)).subtracting(next.values.map(\.workspace))
        if next != otherDisplays { otherDisplays = next }
        if !vanished.isEmpty {
            let keep = Set(tabs.map(\.bundleID)).union(appsOnOtherDisplays)
            let apps = Set(workspaces.filter { vanished.contains($0.id) }.flatMap { $0.tabs.map(\.bundleID) })
            for id in apps.subtracting(keep) { runningApp(id)?.hide() }
        }
        recomputeActive()
        save()
    }

    /// Workspaces not in `used`, most used first.
    private func rankedWorkspaces(excluding used: Set<UUID>) -> [Workspace] {
        let now = Date().timeIntervalSince1970
        return workspaces.enumerated()
            .filter { !used.contains($0.element.id) }
            .sorted { a, b in
                let sa = Frecency.score(a.element, now: now), sb = Frecency.score(b.element, now: now)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Where to go when the current workspace is deleted: preferably one no display shows.
    private func fallbackWorkspace(for removed: UUID) -> UUID {
        let shown = Set(otherDisplays.values.map(\.workspace)).union([removed])
        return (rankedWorkspaces(excluding: shown).first ?? workspaces.first { $0.id != removed }!).id
    }

    /// Brings each other display's selected window back to the front (without activating
    /// its app), after an activation here pulled windows of the same app over it.
    private func raiseOtherDisplays() {
        for (d, state) in otherDisplays {
            guard let tab = allTabs.first(where: { $0.id == state.tab }) else { continue }
            var shown = [tab]
            if isWide(d), let p = partner(of: tab) { shown.append(p) }
            for t in shown {
                guard let wid = t.windowID, let app = runningApp(t.bundleID), !app.isHidden,
                      let w = AX.windows(pid: app.processIdentifier).first(where: { AX.windowID($0) == wid })
                else { continue }
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            }
        }
    }

    /// Moves a workspace's open windows into a display's content area (used when two
    /// displays trade workspaces), raising the selected one.
    private func gather(_ workspaceID: UUID, onto display: DisplayKey, raise tabID: UUID? = nil, except skip: UUID? = nil) {
        guard AX.isTrusted, let ws = workspaces.first(where: { $0.id == workspaceID }) else { return }
        var top: AXUIElement?
        for bundleID in Set(ws.tabs.map(\.bundleID)) {
            guard let app = runningApp(bundleID) else { continue }
            let windows = AX.windows(pid: app.processIdentifier)
            for tab in ws.tabs where tab.bundleID == bundleID && tab.id != skip {
                guard let wid = tab.windowID,
                      let w = windows.first(where: { AX.windowID($0) == wid }), !AX.isFullScreen(w),
                      let frame = frame(for: tab, on: display).map(AX.toAX) else { continue }
                AX.setFrame(w, frame, center: false)
                if tab.id == tabID { top = w }
            }
        }
        if let top { AX.raise(top) }
    }

    // MARK: Claude sessions

    /// The session TabStack last sent Claude to, trusted over Claude's own record for a few
    /// seconds (Claude writes which session has focus with a delay).
    private var claudeSent: (id: String, at: Date)?
    /// The workspace in which Claude was last shown; only that one may record Claude's
    /// session when it is left (elsewhere Claude still shows another workspace's session).
    private var claudeVisited: UUID?

    /// What Claude shows now: the newer of what TabStack sent and Claude's own record.
    private static func shownSession(_ sessions: [ClaudeSessions.Session], sent: (id: String, at: Date)?) -> String? {
        let own = ClaudeSessions.focused(in: sessions)
        guard let sent else { return own?.id }
        guard let own else { return sent.id }
        return own.lastFocused / 1000 > sent.at.timeIntervalSince1970 ? own.id : sent.id
    }

    /// Leaving a workspace whose Claude tab was in use: remember the session Claude shows,
    /// to bring it back on return.
    private func rememberClaudeSession(leaving id: UUID) {
        guard ClaudeSessions.syncEnabled, claudeVisited == id,
              workspaces.first(where: { $0.id == id })?.tabs.contains(where: { $0.bundleID == ClaudeSessions.bundleID }) == true
        else { return }
        claudeVisited = nil
        let sent = claudeSent
        DispatchQueue.global(qos: .userInitiated).async {
            guard let shown = Self.shownSession(ClaudeSessions.all(), sent: sent) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.workspaces.first(where: { $0.id == id })?.claudeSession != shown else { return }
                self.update(id) { $0.claudeSession = shown }
            }
        }
    }

    /// When the Claude window is about to show (alone or as half of a pair), switches Claude
    /// to the current workspace's session.
    private func syncClaudeSession(showing tab: AppTab) {
        guard ClaudeSessions.syncEnabled else { return }
        let claude = ClaudeSessions.bundleID
        guard tab.bundleID == claude || (isWide(focusedDisplay) && partner(of: tab)?.bundleID == claude),
              runningApp(claude) != nil else { return }
        let ws = currentWorkspace
        claudeVisited = ws.id
        let sent = claudeSent
        DispatchQueue.global(qos: .userInitiated).async {
            let sessions = ClaudeSessions.all()
            let shown = Self.shownSession(sessions, sent: sent)
            let target: String?
            if let last = ws.claudeSession, sessions.contains(where: { $0.id == last }) {
                target = last // where Claude was when this workspace was left
            } else {
                // Never left with Claude in use: the project's latest session, unless
                // Claude already shows one of the project's sessions.
                let matches = ClaudeSessions.matching(ws, in: sessions)
                target = matches.contains { $0.id == shown } ? nil : matches.first?.id
            }
            guard let target, target != shown else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.currentWorkspaceID == ws.id else { return }
                self.claudeSent = (target, Date())
                ClaudeSessions.open(target)
            }
        }
    }

    /// Pins a workspace's Claude tab to a session (nil: pick by project folder) and shows it
    /// now if that tab is in front.
    func setClaudeSession(_ id: String?, for workspaceID: UUID) {
        update(workspaceID) { $0.claudeSession = id }
        guard workspaceID == currentWorkspaceID,
              let tab = tabs.first(where: { $0.id == currentID }) else { return }
        if let id {
            let claude = ClaudeSessions.bundleID
            guard tab.bundleID == claude || partner(of: tab)?.bundleID == claude else { return }
            claudeSent = (id, Date())
            ClaudeSessions.open(id)
        } else {
            syncClaudeSession(showing: tab)
        }
    }

    func after(_ seconds: Double, _ work: @escaping () -> Void) {
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
