import Cocoa
import ApplicationServices

/// How to bring a tab's window back after its app or the Mac restarted, when the old
/// window id no longer exists.
struct Reopen: Codable, Equatable {
    /// Project folder of an editor window (VS Code and forks).
    var folder: String?
    /// Every tab of a browser window, in order.
    var urls: [String]?
    /// File shown by a document window (from the window's AXDocument).
    var document: String?

    var isEmpty: Bool { folder == nil && (urls ?? []).isEmpty && document == nil }

    /// Short description for the settings window.
    var summary: String? {
        if let folder { return (folder as NSString).abbreviatingWithTildeInPath }
        if let urls, !urls.isEmpty {
            let host = URL(string: urls[0])?.host ?? urls[0]
            return urls.count == 1 ? host : "\(host) 等 \(urls.count) 个标签页"
        }
        if let document { return (URL(string: document)?.path ?? document as String).replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        return nil
    }
}

enum AppKind {
    case editor   // VS Code and forks: windows are project folders
    case browser  // Chromium browsers with the Chrome AppleScript dictionary
    case other

    static func of(_ bundleID: String) -> AppKind {
        if editorBundles.contains(bundleID) { return .editor }
        if browserNames[bundleID] != nil { return .browser }
        return .other
    }

    static let editorBundles: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92", // Cursor
    ]

    /// AppleScript names of Chromium browsers sharing Chrome's scripting dictionary.
    static let browserNames: [String: String] = [
        "com.google.Chrome": "Google Chrome",
        "com.microsoft.edgemac": "Microsoft Edge",
        "com.brave.Browser": "Brave Browser",
    ]
}

/// Appends a line to ~/Library/Logs/TabStack.log (and the system log).
func debugLog(_ message: String) {
    NSLog("TabStack: %@", message)
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TabStack.log")
    let line = "\(Date()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Reads reopen recipes from live windows and performs restores.
enum Restore {
    // MARK: Editors

    /// Last path component of the project shown in an editor window title,
    /// e.g. "server.ts — Dcard" → "Dcard", "Dcard" → "Dcard".
    static func editorRootName(fromTitle title: String) -> String? {
        let parts = title.components(separatedBy: " — ")
        let root = parts.last?.trimmingCharacters(in: .whitespaces) ?? ""
        return root.isEmpty ? nil : root
    }

    /// Folders VS Code reports as open (its own window state file), by app.
    static func editorFolders(bundleID: String) -> [String] {
        let support: String
        switch bundleID {
        case "com.microsoft.VSCodeInsiders": support = "Code - Insiders"
        case "com.vscodium": support = "VSCodium"
        case "com.todesktop.230313mzl4w4u92": support = "Cursor"
        default: support = "Code"
        }
        let path = NSHomeDirectory() + "/Library/Application Support/\(support)/User/globalStorage/storage.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = json["windowsState"] as? [String: Any] else { return [] }
        var windows = (state["openedWindows"] as? [[String: Any]]) ?? []
        if let last = state["lastActiveWindow"] as? [String: Any] { windows.append(last) }
        return windows.compactMap { ($0["folder"] as? String).flatMap { URL(string: $0)?.path } }
    }

    /// The project folder of an editor window: the open file's ancestor named like the
    /// title's project, else a folder the editor reports with that name.
    static func editorFolder(window: AXUIElement, title: String, bundleID: String) -> String? {
        guard let root = editorRootName(fromTitle: title) else { return nil }
        if let doc = document(of: window), var url = URL(string: doc) {
            while url.pathComponents.count > 1 {
                url.deleteLastPathComponent()
                if url.lastPathComponent == root { return url.path }
            }
        }
        return editorFolders(bundleID: bundleID).first { ($0 as NSString).lastPathComponent == root }
    }

    // MARK: Documents

    static func document(of window: AXUIElement) -> String? {
        let doc: String? = AX.attr(window, kAXDocumentAttribute)
        return (doc?.isEmpty == false) ? doc : nil
    }

    // MARK: Browsers

    /// Every window of a running Chromium browser: its title (= active tab title, the same
    /// as the AX window title) and all tab URLs. Needs the user's one-time Automation
    /// permission; returns [] until granted. NSAppleScript must run on the main thread.
    static func browserWindows(bundleID: String) -> [(title: String, urls: [String])] {
        guard let name = AppKind.browserNames[bundleID],
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
        else { return [] }
        let source = """
        set out to ""
        set AppleScript's text item delimiters to (ASCII character 31)
        tell application "\(name)"
            repeat with w in windows
                set out to out & (title of active tab of w) & (ASCII character 30) & ((URL of tabs of w) as text) & linefeed
            end repeat
        end tell
        return out
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            debugLog("reading \(name) windows failed: \(error ?? [:])")
            return []
        }
        return result.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: "\u{1E}")
            guard parts.count == 2 else { return nil }
            let urls = parts[1].components(separatedBy: "\u{1F}").filter { !$0.isEmpty }
            return (parts[0], urls)
        }
    }

    // MARK: Performing a restore

    /// Opens what `reopen` describes with the tab's app. Returns false when there is
    /// nothing to open (then the caller just launches the app).
    @discardableResult
    static func perform(_ reopen: Reopen, bundleID: String, activate: Bool = true) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate

        if let folder = reopen.folder, FileManager.default.fileExists(atPath: folder) {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: config)
            return true
        }
        if let urls = reopen.urls, !urls.isEmpty, let name = AppKind.browserNames[bundleID] {
            let quoted = urls.map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
            let rest = quoted.dropFirst().map { "tell w to make new tab with properties {URL:\($0)}" }.joined(separator: "\n")
            let source = """
            tell application "\(name)"
                set w to make new window
                set URL of active tab of w to \(quoted[0])
                \(rest)
                \(activate ? "activate" : "")
            end tell
            """
            DispatchQueue.main.async {
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
                if let error { debugLog("restoring \(name) window failed: \(error)") }
            }
            return true
        }
        if let doc = reopen.document, let url = URL(string: doc), FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
            return true
        }
        return false
    }
}
