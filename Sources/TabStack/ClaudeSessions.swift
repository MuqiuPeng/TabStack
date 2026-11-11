import Cocoa

/// Claude desktop's Code sessions. One Claude window can be a tab in several workspaces;
/// whenever it is shown, it is switched to the workspace's session through Claude's own
/// deep link (`claude://code/continue?session=local_…`).
///
/// This leans on Claude's private storage and link format, so every step fails quietly.
enum ClaudeSessions {
    static let bundleID = "com.anthropic.claudefordesktop"

    /// Settings toggle; on unless turned off.
    static var syncEnabled: Bool {
        UserDefaults.standard.object(forKey: "syncClaudeSession") as? Bool ?? true
    }

    struct Session: Identifiable, Equatable {
        let id: String          // local_…
        let title: String
        let cwd: String
        let originCwd: String?
        let lastActivity: Double
        let lastFocused: Double
    }

    private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    private static var cache: (at: Date, sessions: [Session])?
    private static let cacheLock = NSLock()

    /// `all()`, reused for a few seconds; for menus, which SwiftUI may build often.
    static func recent() -> [Session] {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let cache, Date().timeIntervalSince(cache.at) < 3 { return cache.sessions }
        let sessions = all()
        cache = (Date(), sessions)
        return sessions
    }

    /// Every session that is not archived, newest activity first.
    static func all() -> [Session] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Session] = []
        for case let url as URL in e {
            let name = url.lastPathComponent
            guard name.hasPrefix("local_"), name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: url),
                  let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = d["sessionId"] as? String, let cwd = d["cwd"] as? String,
                  (d["isArchived"] as? Bool) != true
            else { continue }
            out.append(Session(
                id: id,
                title: (d["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (cwd as NSString).lastPathComponent,
                cwd: cwd,
                originCwd: d["originCwd"] as? String,
                lastActivity: (d["lastActivityAt"] as? Double) ?? 0,
                lastFocused: (d["lastFocusedAt"] as? Double) ?? 0))
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The session Claude shows now (the one focused last).
    static func focused(in sessions: [Session]) -> Session? {
        sessions.max { $0.lastFocused < $1.lastFocused }
    }

    /// Folders a workspace is about: its editors' project folders and the folders its
    /// Terminal / Finder windows show, except the home folder (that says nothing).
    static func folders(of ws: Workspace) -> [String] {
        let home = NSHomeDirectory()
        var result: [String] = []
        for tab in ws.tabs {
            var path = tab.reopen?.folder
            if path == nil, let doc = tab.reopen?.document, let url = URL(string: doc), url.isFileURL,
               (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                path = url.path
            }
            guard var p = path.map({ ($0 as NSString).expandingTildeInPath }) else { continue }
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            if p != home, p != "/", !result.contains(p) { result.append(p) }
        }
        return result
    }

    /// Sessions that belong to the workspace, best first: working in one of its folders
    /// (or below), else in a folder named like the workspace.
    static func matching(_ ws: Workspace, in sessions: [Session]) -> [Session] {
        let folders = folders(of: ws)
        func inFolders(_ s: Session) -> Bool {
            [s.cwd, s.originCwd].compactMap { $0 }.contains { c in
                folders.contains { c == $0 || c.hasPrefix($0 + "/") }
            }
        }
        let byFolder = sessions.filter(inFolders)
        if !byFolder.isEmpty { return byFolder }
        let name = ws.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return [] }
        return sessions.filter { s in
            [s.cwd, s.originCwd].compactMap { $0 }
                .contains { ($0 as NSString).lastPathComponent.lowercased() == name }
        }
    }

    /// The session to show for a workspace: the one chosen for it, else the latest match.
    static func target(for ws: Workspace, in sessions: [Session]) -> Session? {
        if let chosen = ws.claudeSession, let s = sessions.first(where: { $0.id == chosen }) { return s }
        return matching(ws, in: sessions).first
    }

    /// Opens a new Claude Code session in `folder` with `prompt` in its input box; the user
    /// sends it (Claude never sends a prompt from a link by itself).
    static func newSession(prompt: String, folder: String) {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/new"
        c.queryItems = [URLQueryItem(name: "q", value: String(prompt.prefix(14_000))),
                        URLQueryItem(name: "folder", value: folder),
                        URLQueryItem(name: "source", value: "url_external")]
        guard let url = c.url else { return }
        NSWorkspace.shared.open(url)
    }

    static func open(_ id: String) {
        guard id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil,
              let url = URL(string: "claude://code/continue?session=\(id)&source=url_external") else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(url, configuration: config)
    }
}
