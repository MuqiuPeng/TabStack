import Cocoa

/// Chromium browsers open a link from another app in their frontmost window, which may be
/// a window of another workspace. These scripts find such a tab and move it.
/// NSAppleScript must run on the main thread.
enum BrowserLinks {
    struct Window {
        let id: Int
        let activeTab: Int
        let activeURL: String
        let tabIDs: [Int]
        let title: String
    }

    /// Every window of the browser, frontmost first.
    static func windows(_ bundleID: String) -> [Window]? {
        guard let name = AppKind.browserNames[bundleID],
              NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first != nil
        else { return nil }
        let source = """
        set out to ""
        set AppleScript's text item delimiters to ","
        set RS to (ASCII character 30)
        tell application "\(name)"
            repeat with w in windows
                set t to active tab of w
                set out to out & (id of w) & RS & (id of t) & RS & (URL of t) & RS & ((id of tabs of w) as text) & RS & (title of t) & linefeed
            end repeat
        end tell
        return out
        """
        guard let result = run(source) else { return nil }
        return result.split(separator: "\n").compactMap { line in
            let p = line.components(separatedBy: "\u{1E}")
            guard p.count >= 5, let id = Int(p[0]), let active = Int(p[1]) else { return nil }
            return Window(id: id, activeTab: active, activeURL: p[2],
                          tabIDs: p[3].split(separator: ",").compactMap { Int($0) },
                          title: p[4...].joined(separator: "\u{1E}"))
        }
    }

    /// Reopens `url` as the active tab of window `to` and closes tab `tabID` of window `from`.
    static func move(_ bundleID: String, tab tabID: Int, of from: Int, url: String, to: Int) -> Bool {
        guard let name = AppKind.browserNames[bundleID] else { return false }
        return run("""
        tell application "\(name)"
            tell window id \(to) to make new tab with properties {URL:\(quote(url))}
            close (tab id \(tabID) of window id \(from))
        end tell
        return "ok"
        """) != nil
    }

    /// Reopens `url` in a new window and closes tab `tabID` of window `from`.
    static func moveToNewWindow(_ bundleID: String, tab tabID: Int, of from: Int, url: String) -> Bool {
        guard let name = AppKind.browserNames[bundleID] else { return false }
        return run("""
        tell application "\(name)"
            set w to make new window
            set URL of active tab of w to \(quote(url))
            close (tab id \(tabID) of window id \(from))
        end tell
        return "ok"
        """) != nil
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { debugLog("browser script failed: \(error)") }
        return error == nil ? (result?.stringValue ?? "") : nil
    }
}
