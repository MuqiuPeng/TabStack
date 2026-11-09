import Cocoa
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: inout CGWindowID) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

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

    /// Like `windows(pid:)`, but also finds the windows that the AXWindows attribute leaves
    /// out: a hidden app reports none there, so do apps whose windows sit on another Space.
    /// When WindowServer knows of more windows than AXWindows returns, the app's AX elements
    /// are looked up by id through a remote token (the lookup AltTab uses), with a time budget.
    ///
    /// The scan is remembered per process, so repeated calls stay cheap: windows it found are
    /// reused while they exist, a scan cut short by the budget resumes where it stopped, and
    /// ids a full scan could not find (some apps keep windows with no AX element) are not
    /// searched for again until a window id appears that has not been looked for yet.
    static func windowsIncludingHidden(pid: pid_t) -> [AXUIElement] {
        var result = windows(pid: pid)
        var seen = Set(result.compactMap(windowID))
        let expected = serverWindowIDs(pid: pid)

        hiddenScanLock.lock()
        defer { hiddenScanLock.unlock() }
        hiddenScans = hiddenScans.filter { $0.key == pid || NSRunningApplication(processIdentifier: $0.key) != nil }
        var scan = hiddenScans[pid] ?? HiddenScan()
        defer { hiddenScans[pid] = scan }
        // Forget windows that closed, and those AXWindows reports again (the app was shown).
        scan.found = scan.found.filter { expected.contains($0.key) && !seen.contains($0.key) }
        scan.unresolved.formIntersection(expected.subtracting(seen))

        for (id, w) in scan.found where windowID(w) == id {
            seen.insert(id)
            result.append(w)
        }
        let missing = expected.subtracting(seen).subtracting(scan.unresolved)
        guard !missing.isEmpty else { return result }

        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f_636f)) { Data($0) })
        let deadline = Date().addingTimeInterval(0.1)
        var elementID = scan.resumeAt
        while elementID < hiddenScanLimit, !missing.isSubset(of: seen) {
            if Date() > deadline {
                scan.resumeAt = elementID
                return result
            }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            elementID += 1
            guard let w = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  isStandardEvenIfHidden(w), let id = windowID(w), !seen.contains(id) else { continue }
            seen.insert(id)
            scan.found[id] = w
            result.append(w)
        }
        // The scan got through: what it did not find has no element in the searched range.
        scan.resumeAt = 0
        scan.unresolved.formUnion(missing.subtracting(seen))
        return result
    }

    private struct HiddenScan {
        var found: [CGWindowID: AXUIElement] = [:]
        var unresolved: Set<CGWindowID> = []
        var resumeAt: UInt64 = 0
    }
    private static let hiddenScanLimit: UInt64 = 2000
    private static var hiddenScans: [pid_t: HiddenScan] = [:]
    private static let hiddenScanLock = NSLock()

    /// While its app is hidden, a document window reports the AXDialog subrole. It keeps
    /// its minimize and zoom buttons though, which a real dialog does not have.
    private static func isStandardEvenIfHidden(_ w: AXUIElement) -> Bool {
        switch attr(w, kAXSubroleAttribute) as String? {
        case kAXStandardWindowSubrole?: return true
        case kAXDialogSubrole?:
            return (attr(w, kAXMinimizeButtonAttribute) as AXUIElement?) != nil
                && (attr(w, kAXZoomButtonAttribute) as AXUIElement?) != nil
        default: return false
        }
    }

    /// A window as listed to the user: its WindowServer id and title, and its AX element
    /// when one could be found.
    struct ListedWindow {
        let id: CGWindowID
        let title: String
        let element: AXUIElement?
    }

    /// The app's windows for listing and adopting: everything `windowsIncludingHidden` finds,
    /// plus, while the app is hidden, the windows it has no AX element for at all. Some apps
    /// (WeChat) tear down the accessibility element of a window when hidden, so neither
    /// AXWindows nor the remote-token lookup can reach it; WindowServer still knows it, and a
    /// tab only needs its id and title. Only windows that still belong to a Space are taken
    /// from there: an app's ordered-out windows (prebuilt dialogs, login panels) belong to none.
    /// The same rule applies to windows only the remote-token scan found (WeChat keeps an
    /// untitled, ordered-out standard window), except minimized ones, which may have no Space.
    static func listedWindows(of app: NSRunningApplication) -> [ListedWindow] {
        let pid = app.processIdentifier
        let direct = Set(windows(pid: pid).compactMap(windowID))
        var result = windowsIncludingHidden(pid: pid).compactMap { w -> ListedWindow? in
            guard let id = windowID(w) else { return nil }
            if !direct.contains(id), !isOnSpace(id), (attr(w, kAXMinimizedAttribute) as Bool?) != true { return nil }
            return ListedWindow(id: id, title: title(w), element: w)
        }
        guard app.isHidden else { return result }
        let known = Set(result.map(\.id))
        for (id, name) in serverWindows(pid: pid) where !known.contains(id) && isOnSpace(id) {
            // Without screen recording permission WindowServer withholds window titles;
            // the app's name is the best stand-in (these are typically its main window).
            let title = (name?.isEmpty == false ? name : nil) ?? app.localizedName ?? ""
            result.append(ListedWindow(id: id, title: title, element: nil))
        }
        return result
    }

    private static func isOnSpace(_ id: CGWindowID) -> Bool {
        let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 0x7, [id] as CFArray)?
            .takeRetainedValue() as? [Any]
        return !(spaces ?? []).isEmpty
    }

    /// WindowServer ids of an app's normal-layer windows, on screen or not. Strips no taller
    /// than the menu bar (apps keep a few per display) are left out: they are never windows.
    private static func serverWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        Set(serverWindows(pid: pid).map(\.id))
    }

    /// The same windows with their WindowServer titles, front to back (a title is nil
    /// without the screen recording permission).
    private static func serverWindows(pid: pid_t) -> [(id: CGWindowID, title: String?)] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.height > 60,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { return nil }
            return (id, info[kCGWindowName as String] as? String)
        }
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
    static func setFrame(_ w: AXUIElement, _ rect: CGRect, center: Bool = true) {
        if (attr(w, kAXMinimizedAttribute) as Bool?) == true {
            set(w, kAXMinimizedAttribute, kCFBooleanFalse)
        }
        // Chromium and Electron apps switch on "enhanced user interface" once an assistive
        // app talks to them, and then delay or drop window moves. Turn it off while
        // moving, as other window managers do, and restore it afterwards.
        var pid: pid_t = 0
        AXUIElementGetPid(w, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = (attr(app, "AXEnhancedUserInterface") as Bool?) == true
        if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { set(app, "AXEnhancedUserInterface", kCFBooleanTrue) } }

        // Position → size → position: moving first lets the size apply on the target
        // display, the second move corrects any clamping the app did while resizing.
        var rect = rect
        setPosition(w, rect.origin)
        // macOS keeps windows below a display's menu bar even when the screen's visible
        // frame does not account for it; some apps (Chrome) then refuse a size that no
        // longer fits. Shrink to the space actually left below where the window landed.
        if let p = position(w), abs(p.x - rect.minX) < 2, p.y > rect.minY + 1, p.y < rect.maxY - 100 {
            rect.size.height -= p.y - rect.minY
            rect.origin.y = p.y
        }
        setSize(w, rect.size)
        setPosition(w, rect.origin)

        // Some apps (Chrome) apply moves a moment later; reading back the old frame then
        // says nothing about the size, so only center when the move already took.
        if center, let s = size(w), abs(s.width - rect.width) > 2 || abs(s.height - rect.height) > 2,
           let p = position(w), abs(p.x - rect.minX) < 2 {
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

extension AX {
    /// Presses the window's close button, as clicking the red light would.
    @discardableResult
    static func close(_ w: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXCloseButtonAttribute as CFString, &value) == .success,
              let button = value, CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }
}
