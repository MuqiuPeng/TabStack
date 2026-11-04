import Cocoa

/// Apps whose windows are interchangeable (Finder, terminals, browsers): TabStack can open
/// a fresh window of one and make it a tab of the workspace.
struct NewWindowTarget {
    let bundleID: String
    let name: String
    /// Chromium profile directory ("Default", "Profile 1", …) and its display label.
    var profile: (dir: String, label: String)?
}

enum NewWindow {
    private static let known: [(bundleID: String, name: String)] = [
        ("com.apple.finder", "Finder"),
        ("com.apple.Terminal", "终端"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.google.Chrome", "Chrome"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("com.apple.Safari", "Safari"),
    ]

    /// Chromium "Local State" folders, for listing profiles.
    private static let profileRoots: [String: String] = [
        "com.google.Chrome": "Google/Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
    ]

    /// Installed apps that can make a new window, each with its profiles (if any).
    static func apps() -> [(bundleID: String, name: String, targets: [NewWindowTarget])] {
        known.compactMap { app in
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) != nil else { return nil }
            let profiles = chromiumProfiles(app.bundleID)
            let targets = profiles.count > 1
                ? profiles.map { NewWindowTarget(bundleID: app.bundleID, name: app.name, profile: $0) }
                : [NewWindowTarget(bundleID: app.bundleID, name: app.name)]
            return (app.bundleID, app.name, targets)
        }
    }

    private static func chromiumProfiles(_ bundleID: String) -> [(dir: String, label: String)] {
        guard let root = profileRoots[bundleID] else { return [] }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(root)/Local State")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [] }
        let names = cache.mapValues { ($0["name"] as? String) ?? "" }
        return cache.keys.sorted { a, b in
            // "Default" first, then "Profile 1", "Profile 2", …
            a == "Default" || (b != "Default" && a.localizedStandardCompare(b) == .orderedAscending)
        }.map { dir in
            let name = names[dir] ?? dir
            let email = (cache[dir]?["user_name"] as? String) ?? ""
            // Two profiles may share a name; the account tells them apart.
            let duplicate = names.values.filter { $0 == name }.count > 1
            return (dir, duplicate && !email.isEmpty ? "\(name)（\(email)）" : name)
        }
    }

    /// Sends ⌘⇧G (Go ▸ Go to Folder…) to Finder.
    static func showGoToFolder(pid: pid_t) {
        let g = CGKeyCode(5) // kVK_ANSI_G
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: g, keyDown: down)
            e?.flags = [.maskCommand, .maskShift]
            e?.postToPid(pid)
        }
    }

    /// Asks the app for a new window. Returns false if it could not even be asked.
    @discardableResult
    static func open(_ target: NewWindowTarget) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target.bundleID) else { return false }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).isEmpty

        if profileRoots[target.bundleID] != nil {
            var args = ["-na", appURL.path, "--args", "--new-window"]
            if let profile = target.profile { args.append("--profile-directory=\(profile.dir)") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = args
            return (try? p.run()) != nil
        }

        // A terminal or Safari that is not running opens its first window by itself.
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: target.bundleID).first,
              running else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        // ⌘N (File ▸ New Window) works in every one of these apps and needs only the
        // Accessibility permission TabStack already has, so no Automation prompt.
        AX.activate(app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let n = CGKeyCode(45) // kVK_ANSI_N
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: n, keyDown: down)
                e?.flags = .maskCommand
                e?.postToPid(app.processIdentifier)
            }
        }
        return true
    }
}
