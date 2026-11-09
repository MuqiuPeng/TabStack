import Cocoa

/// A local control channel so other programs (the `tabstack-mcp` server, scripts) can read
/// and change workspaces while TabStack runs.
///
/// Unix domain socket at ~/Library/Application Support/TabStack/control.sock, readable and
/// writable only by this user. One JSON object per line each way:
///   → {"id": 1, "method": "list_workspaces", "params": {}}
///   ← {"id": 1, "result": …}   or   {"id": 1, "error": "…"}
final class ControlServer {
    static var socketPath: String {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TabStack")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("control.sock").path
    }

    private let commands: ControlCommands
    private var listenFD: Int32 = -1

    init(manager: WorkspaceManager) {
        commands = ControlCommands(manager: manager)
    }

    func start() {
        let path = Self.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { debugLog("control socket: socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
        }
        guard ok, listen(fd, 8) == 0 else { debugLog("control socket: bind/listen failed \(errno)"); close(fd); return }
        chmod(path, 0o600)
        listenFD = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        unlink(Self.socketPath)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            if client < 0 { if errno == EINTR { continue }; return }
            Thread.detachNewThread { [weak self] in self?.serve(client) }
        }
    }

    /// Reads requests line by line; each runs on the main thread and may finish later.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                let response = handle(line)
                var out = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
                out.append(0x0A)
                out.withUnsafeBytes { p in _ = write(fd, p.baseAddress, out.count) }
            }
        }
    }

    private func handle(_ line: Data) -> [String: Any] {
        guard let req = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = req["method"] as? String else { return ["error": "invalid request"] }
        let id = req["id"] ?? NSNull()
        let params = req["params"] as? [String: Any] ?? [:]

        let done = DispatchSemaphore(value: 0)
        var result: Result<Any, ControlCommands.Failure> = .failure(.init("timed out"))
        DispatchQueue.main.async {
            self.commands.run(method, params) { r in
                result = r
                done.signal()
            }
        }
        if done.wait(timeout: .now() + 30) == .timedOut { return ["id": id, "error": "timed out"] }
        switch result {
        case .success(let value): return ["id": id, "result": value]
        case .failure(let f): return ["id": id, "error": f.message]
        }
    }
}

/// The commands behind the control socket; all run on the main thread.
final class ControlCommands {
    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
    typealias Done = (Result<Any, Failure>) -> Void

    private let m: WorkspaceManager
    init(manager: WorkspaceManager) { m = manager }

    func run(_ method: String, _ p: [String: Any], _ done: @escaping Done) {
        do {
            switch method {
            case "list_workspaces": done(.success(m.workspaces.map(describe)))
            case "list_windows": done(.success(listWindows(p)))
            case "list_browser_profiles": done(.success(browserProfiles()))
            case "create_workspace": done(.success(try createWorkspace(p)))
            case "update_workspace": done(.success(try updateWorkspace(p)))
            case "delete_workspace": done(.success(try deleteWorkspace(p)))
            case "switch_workspace": done(.success(try switchWorkspace(p)))
            case "add_window": done(.success(try addWindow(p)))
            case "open_window": try openWindow(p, done)
            case "update_tab": done(.success(try updateTab(p)))
            case "remove_tab": done(.success(try removeTab(p)))
            case "restore_workspace":
                let ws = try workspace(p["workspace"])
                m.restoreMissingWindows(in: ws.id)
                done(.success(["restoring": ws.tabs.filter { !m.isBound($0) }.map(\.displayName)]))
            default: throw Failure("unknown method \(method)")
            }
        } catch let f as Failure {
            done(.failure(f))
        } catch {
            done(.failure(Failure("\(error)")))
        }
    }

    // MARK: Lookups

    private func workspace(_ ref: Any?) throws -> Workspace {
        guard let ref = (ref as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
            throw Failure("missing workspace (name or id)")
        }
        if let id = UUID(uuidString: ref), let ws = m.workspaces.first(where: { $0.id == id }) { return ws }
        let lower = ref.lowercased()
        if let ws = m.workspaces.first(where: { $0.name.lowercased() == lower }) { return ws }
        let prefixed = m.workspaces.filter { $0.name.lowercased().hasPrefix(lower) }
        if prefixed.count == 1 { return prefixed[0] }
        if prefixed.count > 1 { throw Failure("workspace “\(ref)” is ambiguous: \(prefixed.map(\.name).joined(separator: ", "))") }
        throw Failure("no workspace “\(ref)”; existing: \(m.workspaces.map(\.name).joined(separator: ", "))")
    }

    /// A tab by id, or by name within `workspace`.
    private func tab(_ p: [String: Any]) throws -> (AppTab, Workspace) {
        guard let ref = p["tab"] as? String, !ref.isEmpty else { throw Failure("missing tab (id or name)") }
        if let id = UUID(uuidString: ref) {
            for ws in m.workspaces { if let t = ws.tabs.first(where: { $0.id == id }) { return (t, ws) } }
            throw Failure("no tab with id \(ref)")
        }
        let ws = try workspace(p["workspace"])
        let lower = ref.lowercased()
        let hits = ws.tabs.filter { $0.displayName.lowercased() == lower || $0.name.lowercased() == lower }
        if hits.count == 1 { return (hits[0], ws) }
        if hits.count > 1 { throw Failure("several tabs named “\(ref)” in \(ws.name); use the tab id") }
        throw Failure("no tab “\(ref)” in \(ws.name)")
    }

    // MARK: Descriptions

    private func describe(_ ws: Workspace) -> [String: Any] {
        var d: [String: Any] = [
            "id": ws.id.uuidString, "name": ws.name,
            "current": ws.id == m.currentWorkspaceID,
            "onOtherDisplay": m.otherDisplay(showing: ws.id) != nil,
            "shownInSidebar": m.activeIDs.contains(ws.id),
            "pinned": ws.pinned == true,
            "tabs": ws.tabs.map(describe),
        ]
        if let c = ws.color { d["color"] = c }
        if let s = ws.claudeSession { d["claudeSession"] = s }
        // The highlighted tab (none while focus is on a window outside the workspace).
        if ws.id == m.currentWorkspaceID, let t = m.selectedTabID(on: m.focusedDisplay) { d["selectedTab"] = t.uuidString }
        if let i = m.activeWorkspaces.firstIndex(of: ws), i < 9 { d["hotkey"] = "⌃⌥\(i + 1)" }
        return d
    }

    private func describe(_ t: AppTab) -> [String: Any] {
        var d: [String: Any] = ["id": t.id.uuidString, "name": t.displayName, "app": t.name,
                                "bundleID": t.bundleID, "windowOpen": m.isBound(t)]
        if let w = t.windowID { d["windowID"] = Int(w) }
        if let p = m.partner(of: t) {
            d["pairedWith"] = p.id.uuidString
            d["side"] = m.primary(of: t).id == t.id ? "left" : "right"
        }
        if let title = t.title { d["windowTitle"] = title }
        if let r = t.reopen, !r.isEmpty {
            var rd: [String: Any] = [:]
            if let f = r.folder { rd["folder"] = f }
            if let u = r.urls { rd["urls"] = u }
            if let doc = r.document { rd["document"] = doc }
            d["reopen"] = rd
        }
        return d
    }

    private func listWindows(_ p: [String: Any]) -> [[String: Any]] {
        m.bindUnboundTabs()
        let filter = (p["app"] as? String)?.lowercased()
        var owners: [CGWindowID: [String]] = [:]
        var knownTitles: [CGWindowID: String] = [:]
        for ws in m.workspaces {
            for t in ws.tabs {
                guard let w = t.windowID else { continue }
                owners[w, default: []].append(ws.name)
                if let title = t.title, !title.isEmpty { knownTitles[w] = title }
            }
        }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { app in
                guard let filter else { return true }
                return (app.localizedName ?? "").lowercased().contains(filter)
                    || (app.bundleIdentifier ?? "").lowercased().contains(filter)
            }
            .compactMap { app -> [String: Any]? in
                let windows: [[String: Any]] = AX.listedWindows(of: app).map { w in
                    // A window found only through WindowServer may carry just the app's name
                    // as its title; a tab holding it remembers the real one.
                    let title = w.element == nil ? knownTitles[w.id] ?? w.title : w.title
                    var d: [String: Any] = ["windowID": Int(w.id), "title": title]
                    if let ws = owners[w.id] { d["inWorkspaces"] = ws }
                    if AppKind.of(app.bundleIdentifier ?? "") == .editor,
                       let root = Restore.editorRootName(fromTitle: title) { d["folderName"] = root }
                    return d
                }
                guard !windows.isEmpty else { return nil }
                return ["app": app.localizedName ?? "", "bundleID": app.bundleIdentifier ?? "", "windows": windows]
            }
    }

    private func browserProfiles() -> [[String: Any]] {
        NewWindow.apps().filter { $0.targets.first?.profile != nil }.map { app in
            ["app": app.name, "bundleID": app.bundleID,
             "profiles": app.targets.compactMap { t in t.profile.map { ["directory": $0.dir, "name": $0.label] } }]
        }
    }

    // MARK: Workspaces

    private func createWorkspace(_ p: [String: Any]) throws -> [String: Any] {
        guard let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw Failure("missing name")
        }
        if m.workspaces.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw Failure("a workspace named “\(name)” already exists")
        }
        let id = m.createWorkspace(named: name)
        if let c = p["color"] as? Int { m.setColor(id, c % WorkspaceColor.palette.count) }
        if p["pinned"] as? Bool == true { m.setPinned(id, true) }
        if p["switch"] as? Bool == true { m.switchWorkspace(id) }
        return describe(m.workspaces.first { $0.id == id }!)
    }

    private func updateWorkspace(_ p: [String: Any]) throws -> [String: Any] {
        let ws = try workspace(p["workspace"])
        if let name = (p["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            m.renameWorkspace(ws.id, to: name)
        }
        if let c = p["color"] as? Int { m.setColor(ws.id, c % WorkspaceColor.palette.count) }
        if let pinned = p["pinned"] as? Bool { m.setPinned(ws.id, pinned) }
        if let s = p["claudeSession"] as? String {
            guard s.isEmpty || s.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
            else { throw Failure("claudeSession must look like local_…, or be empty") }
            m.setClaudeSession(s.isEmpty ? nil : s, for: ws.id)
        }
        if let pos = p["position"] as? Int, let from = m.workspaces.firstIndex(where: { $0.id == ws.id }) {
            let to = min(max(pos - 1, 0), m.workspaces.count - 1)
            m.moveWorkspaces(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
        return describe(m.workspaces.first { $0.id == ws.id }!)
    }

    private func deleteWorkspace(_ p: [String: Any]) throws -> [String: Any] {
        let ws = try workspace(p["workspace"])
        guard m.workspaces.count > 1 else { throw Failure("cannot delete the only workspace") }
        m.removeWorkspace(ws.id)
        return ["deleted": ws.name]
    }

    private func switchWorkspace(_ p: [String: Any]) throws -> [String: Any] {
        let ws = try workspace(p["workspace"])
        var tabID: UUID?
        if p["tab"] != nil { tabID = try tab(p.merging(["workspace": ws.id.uuidString]) { $1 }).0.id }
        m.switchWorkspace(ws.id, to: tabID)
        return describe(ws)
    }

    // MARK: Tabs

    private func addWindow(_ p: [String: Any]) throws -> [String: Any] {
        let ws = try workspace(p["workspace"])
        guard let raw = p["windowID"] as? Int else { throw Failure("missing windowID (from list_windows)") }
        let id = CGWindowID(raw)
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let w = AX.listedWindows(of: app).first(where: { $0.id == id }) {
                if let existing = ws.tabs.first(where: { $0.windowID == id }) { return describe(existing) }
                let known = w.element == nil ? m.allTabs.first(where: { $0.windowID == id && $0.title?.isEmpty == false })?.title : nil
                m.addWindow(id, title: known ?? w.title, of: app, to: ws.id)
                guard let t = m.workspaces.first(where: { $0.id == ws.id })?.tabs.first(where: { $0.windowID == id })
                else { throw Failure("could not add the window") }
                if let name = p["name"] as? String, !name.isEmpty { m.renameTab(t.id, to: name) }
                return describe(m.allTabs.first { $0.id == t.id } ?? t)
            }
        }
        throw Failure("no open window \(raw); call list_windows")
    }

    /// Common names an assistant is likely to use for an app.
    private static let aliases: [String: String] = [
        "vscode": "com.microsoft.VSCode", "code": "com.microsoft.VSCode", "visual studio code": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "chrome": "com.google.Chrome", "google chrome": "com.google.Chrome",
        "edge": "com.microsoft.edgemac", "brave": "com.brave.Browser", "safari": "com.apple.Safari",
        "finder": "com.apple.finder", "terminal": "com.apple.Terminal", "iterm": "com.googlecode.iterm2",
        "iterm2": "com.googlecode.iterm2",
    ]

    private func bundleID(for app: String) throws -> String {
        let key = app.lowercased().trimmingCharacters(in: .whitespaces)
        if let id = Self.aliases[key] { return id }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil { return app }
        for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(app.hasSuffix(".app") ? app : "\(app).app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        if let running = NSWorkspace.shared.runningApplications.first(where: { ($0.localizedName ?? "").lowercased() == key }),
           let id = running.bundleIdentifier { return id }
        throw Failure("unknown app “\(app)”; use a bundle id or the name in /Applications")
    }

    private func openWindow(_ p: [String: Any], _ done: @escaping Done) throws {
        let ws = try workspace(p["workspace"])
        guard let appRef = p["app"] as? String else { throw Failure("missing app") }
        let bundleID = try bundleID(for: appRef)
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw Failure("\(appRef) is not installed")
        }
        let path = (p["path"] as? String).map { ($0 as NSString).expandingTildeInPath }
        if let path, !FileManager.default.fileExists(atPath: path) { throw Failure("no such file or folder: \(path)") }
        let urls = (p["urls"] as? [String]) ?? (p["url"] as? String).map { [$0] } ?? []
        let kind = AppKind.of(bundleID)
        let isChromium = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser"].contains(bundleID)

        var profileDir: String?
        if let profile = p["profile"] as? String, !profile.isEmpty {
            guard isChromium else { throw Failure("profile only applies to Chrome, Edge or Brave") }
            let targets = NewWindow.apps().first { $0.bundleID == bundleID }?.targets ?? []
            let lower = profile.lowercased()
            guard let hit = targets.first(where: { $0.profile?.dir.lowercased() == lower })
                ?? targets.first(where: { $0.profile?.label.lowercased() == lower })
                ?? targets.first(where: { $0.profile?.label.lowercased().contains(lower) == true })
            else { throw Failure("no profile “\(profile)”; call list_browser_profiles") }
            profileDir = hit.profile?.dir
        }

        var reopen = Reopen()
        let trigger: () -> Bool
        var fallback: (() -> AXUIElement?)?
        if isChromium {
            if !urls.isEmpty { reopen.urls = urls }
            trigger = {
                var args = ["-na", appURL.path, "--args", "--new-window"]
                if let profileDir { args.append("--profile-directory=\(profileDir)") }
                args += urls
                return Self.run("/usr/bin/open", args)
            }
        } else if let path {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            if kind == .editor { reopen.folder = path } else { reopen.document = URL(fileURLWithPath: path).absoluteString }
            trigger = {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: appURL, configuration: config)
                return true
            }
            if kind == .editor {
                // VS Code focuses the folder's window when it is already open.
                let name = (path as NSString).lastPathComponent
                let m = self.m
                fallback = {
                    guard let app = m.runningApp(bundleID) else { return nil }
                    return AX.windows(pid: app.processIdentifier).first { w in
                        guard let id = AX.windowID(w), !(ws.tabs.contains { $0.windowID == id }) else { return false }
                        return Restore.editorRootName(fromTitle: AX.title(w)) == name
                    }
                }
            }
        } else if !urls.isEmpty {
            trigger = {
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(urls.compactMap(URL.init(string:)), withApplicationAt: appURL, configuration: config)
                return true
            }
        } else {
            let target = NewWindowTarget(bundleID: bundleID, name: appRef)
            trigger = { NewWindow.open(target) }
        }

        let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let activate = p["switch"] as? Bool ?? true
        m.openNewWindow(bundleID: bundleID, in: ws.id, name: name, reopen: reopen.isEmpty ? nil : reopen,
                        timeout: 15, trigger: trigger, fallback: fallback) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let tab):
                if activate { self.m.switchWorkspace(ws.id, to: tab.id) }
                done(.success(self.describe(tab)))
            case .failure(let e):
                done(.failure(Failure(e.message)))
            }
        }
    }

    private func updateTab(_ p: [String: Any]) throws -> [String: Any] {
        var (t, ws) = try tab(p)
        if let name = p["name"] as? String { m.renameTab(t.id, to: name) }
        if let dest = p["moveTo"] as? String {
            let target = try workspace(dest)
            if target.id != ws.id { m.moveTab(t.id, from: ws.id, to: target.id); ws = target }
        }
        if let ref = p["pairWith"] as? String {
            if ref.isEmpty {
                m.unpair(t)
            } else {
                let (other, ows) = try tab(["tab": ref, "workspace": ws.id.uuidString])
                guard ows.id == ws.id else { throw Failure("a tab can only be paired with a tab of the same workspace") }
                if let existing = m.partner(of: t), existing.id != other.id { m.unpair(t) }
                if let existing = m.partner(of: other), existing.id != t.id { m.unpair(other) }
                m.pair(t.id, with: other.id)
            }
        }
        if let pos = p["position"] as? Int, let current = m.workspaces.first(where: { $0.id == ws.id }),
           let from = current.tabs.firstIndex(where: { $0.id == t.id }) {
            let to = min(max(pos - 1, 0), current.tabs.count - 1)
            m.moveTabs(in: ws.id, from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
        t = m.allTabs.first { $0.id == t.id } ?? t
        return describe(t).merging(["workspace": ws.name]) { $1 }
    }

    private func removeTab(_ p: [String: Any]) throws -> [String: Any] {
        let (t, ws) = try tab(p)
        var closed: Bool?
        if p["closeWindow"] as? Bool == true {
            closed = false
            if let id = t.windowID, let app = m.runningApp(t.bundleID),
               let w = AX.windowsIncludingHidden(pid: app.processIdentifier).first(where: { AX.windowID($0) == id }) {
                closed = AX.close(w)
            }
        }
        m.removeTab(t.id, from: ws.id)
        var result: [String: Any] = ["removed": t.displayName, "workspace": ws.name]
        if let closed { result["windowClosed"] = closed }
        return result
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        return (try? p.run()) != nil
    }
}
