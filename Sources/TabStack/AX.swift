import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

/// Thin wrapper over the Accessibility API used to move, resize and raise
/// windows that belong to other applications.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Attributes

    static func attr<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    @discardableResult
    static func set(_ element: AXUIElement, _ name: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    static func position(_ w: AXUIElement) -> CGPoint? {
        guard let v: AXValue = attr(w, kAXPositionAttribute) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v, .cgPoint, &p) ? p : nil
    }

    static func size(_ w: AXUIElement) -> CGSize? {
        guard let v: AXValue = attr(w, kAXSizeAttribute) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v, .cgSize, &s) ? s : nil
    }

    static func setPosition(_ w: AXUIElement, _ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { set(w, kAXPositionAttribute, v) }
    }

    static func setSize(_ w: AXUIElement, _ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { set(w, kAXSizeAttribute, v) }
    }

    // MARK: Windows

    private static func isStandard(_ w: AXUIElement) -> Bool {
        (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
    }

    /// The WindowServer id of a window. Stable for the window's lifetime, which is what
    /// lets a tab point at one specific window of an app (private but long-standing API,
    /// used by most window managers).
    static func windowID(_ w: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(w, &id) == .success && id != 0 ? id : nil
    }

    /// The app's regular document windows (minimized ones included), front to back.
    static func windows(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        let all: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        return all.filter(isStandard)
    }

    static func title(_ w: AXUIElement) -> String {
        (attr(w, kAXTitleAttribute) as String?) ?? ""
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute), isStandard(w) { return w }
        if let w: AXUIElement = attr(app, kAXMainWindowAttribute), isStandard(w) { return w }
        return nil
    }

    /// Ids of every window that currently exists, on screen or not (hidden apps, minimized,
    /// other Spaces). Needs no Accessibility permission.
    static func existingWindowIDs() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
    }

    /// The window that best represents the app: main, then focused, then the first standard window.
    static func mainWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = attr(app, kAXMainWindowAttribute), isStandard(w) { return w }
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute), isStandard(w) { return w }
        let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        return windows.first(where: isStandard)
    }

    /// Fits a window into `rect` (AX coordinates, top-left origin). Windows that refuse
    /// the size (fixed-size or with a max size) are centered in the rect instead.
    static func setFrame(_ w: AXUIElement, _ rect: CGRect) {
        if (attr(w, kAXMinimizedAttribute) as Bool?) == true {
            set(w, kAXMinimizedAttribute, kCFBooleanFalse)
        }
        // Position → size → position: moving first lets the size apply on the target
        // display, the second move corrects any clamping the app did while resizing.
        setPosition(w, rect.origin)
        setSize(w, rect.size)
        setPosition(w, rect.origin)

        if let s = size(w), abs(s.width - rect.width) > 2 || abs(s.height - rect.height) > 2 {
            let origin = CGPoint(x: rect.minX + max(0, (rect.width - s.width) / 2),
                                 y: rect.minY + max(0, (rect.height - s.height) / 2))
            setPosition(w, origin)
        }
    }

    static func isFullScreen(_ w: AXUIElement) -> Bool {
        (attr(w, "AXFullScreen") as Bool?) == true
    }

    /// Whether the frontmost app is showing a native full-screen window. Returns nil when
    /// that can't be told (no permission, or TabStack itself is frontmost).
    static func frontmostIsFullScreen() -> Bool? {
        guard isTrusted, let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        guard let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute)
        else { return false }
        return isFullScreen(w)
    }

    static func raise(_ w: AXUIElement) {
        set(w, kAXMainAttribute, kCFBooleanTrue)
        AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    }

    /// Brings an app to the front. `NSRunningApplication.activate` alone is refused on
    /// macOS 14+ when we are not the active app (e.g. when triggered by a hotkey),
    /// setting AXFrontmost works regardless.
    static func activate(_ app: NSRunningApplication) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        set(element, kAXFrontmostAttribute, kCFBooleanTrue)
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: Coordinates

    /// Cocoa rect (bottom-left origin) → AX rect (top-left origin of the primary screen).
    static func toAX(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: Dock badges

    /// Reads the red badges shown on Dock icons, keyed by the Dock item title (app name).
    static func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        let lists: [AXUIElement] = attr(app, kAXChildrenAttribute) ?? []
        for list in lists {
            let items: [AXUIElement] = attr(list, kAXChildrenAttribute) ?? []
            for item in items {
                if let title: String = attr(item, kAXTitleAttribute),
                   let label: String = attr(item, "AXStatusLabel"),
                   !label.isEmpty {
                    result[title] = label
                }
            }
        }
        return result
    }
}
