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
        return all.filter(isStandard) + helperWindows(of: pid)
    }

    /// Standard windows drawn by the app's helper processes (bundle id "<app id>.*"), e.g.
    /// Steam's main window belongs to com.valvesoftware.steam.helper.
    private static func helperWindows(of pid: pid_t) -> [AXUIElement] {
        guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != pid && ($0.bundleIdentifier?.hasPrefix(id + ".") ?? false) }
            .flatMap { helper -> [AXUIElement] in
                let el = AXUIElementCreateApplication(helper.processIdentifier)
                let ws: [AXUIElement] = attr(el, kAXWindowsAttribute) ?? []
                return ws.filter(isStandard)
            }
    }

    /// Like `windows(pid:)`, but also finds the windows that the AXWindows attribute leaves
    /// out: a hidden app reports none there, and windows on another Space (native full
    /// screen included) are never listed there. When WindowServer knows of more windows than
    /// AXWindows returns, the app's AX elements are looked up by id through a remote token
    /// (the lookup AltTab uses), with a time budget.
    ///
    /// Element ids are handed out in order, so a long-running app's newest windows can sit
    /// far up the range (Chrome's past 2000): the scan covers at least `hiddenScanLimit` ids
    /// and goes on while elements keep turning up.
    ///
    /// The scan is remembered per process, so repeated calls stay cheap: windows it found are
    /// reused while they exist, a scan cut short by the budget resumes where it stopped, and
    /// ids a full scan could not find (some apps keep windows with no AX element) are not
    /// searched for again until a window id appears that has not been looked for yet.
    /// `wanted` is searched for even when an earlier scan could not find it (a window can be
    /// out of reach for a moment, e.g. while it animates into full screen).
    static func windowsIncludingHidden(pid: pid_t, wanted: CGWindowID? = nil) -> [AXUIElement] {
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
        if let wanted { scan.unresolved.remove(wanted) }

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
        while elementID < max(hiddenScanLimit, scan.lastLive + hiddenScanMargin), !missing.isSubset(of: seen) {
            if Date() > deadline {
                scan.resumeAt = elementID
                return result
            }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            elementID += 1
            guard let w = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(),
                  let role: String = attr(w, kAXRoleAttribute) else { continue }
            scan.lastLive = max(scan.lastLive, elementID - 1)
            guard role == kAXWindowRole, isStandardEvenIfHidden(w),
                  let id = windowID(w), !seen.contains(id) else { continue }
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
        /// Highest element id that answered; the scan runs `hiddenScanMargin` past it.
        var lastLive: UInt64 = 0
    }
    private static let hiddenScanLimit: UInt64 = 2000
    /// Gaps between live elements measured up to ~600 ids (Chrome, WeChat).
    private static let hiddenScanMargin: UInt64 = 1000
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

    /// One window of the app by its id, wherever it is: AXWindows first, then the
    /// remote-token lookup (another Space, native full screen, a hidden app).
    static func window(_ id: CGWindowID, pid: pid_t) -> AXUIElement? {
        windowsIncludingHidden(pid: pid, wanted: id).first { windowID($0) == id }
    }

    /// Whether the window belongs to a Space: it is shown somewhere (a desktop or a
    /// full-screen Space), as opposed to ordered out (closed but kept by its app).
    static func isOnSpace(_ id: CGWindowID) -> Bool {
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

    /// Whether the app is frontmost, asked of the app itself: unlike `NSRunningApplication`'s
    /// view, this doesn't wait for the activation notice to reach the main thread.
    static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        (attr(AXUIElementCreateApplication(app.processIdentifier), kAXFrontmostAttribute) as Bool?) == true
    }

    /// Panels (an edge panel, a palette, a launcher's bar): windows an app keeps above its
    /// document windows. `focusedWindow` passes over them to the app's main window.
    static func isPanel(_ w: AXUIElement) -> Bool {
        switch attr(w, kAXSubroleAttribute) as String? {
        case kAXFloatingWindowSubrole?, kAXSystemFloatingWindowSubrole?, kAXSystemDialogSubrole?: return true
        default: return false
        }
    }

    /// Whether the app's focused window is one of its panels (see `isPanel`).
    static func focusedIsPanel(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) else { return false }
        return isPanel(w)
    }

    /// Windows on screen, front to back, without the window server's own overlays.
    private static func onScreenWindows() -> [[String: Any]] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.filter {
            ($0[kCGWindowOwnerName as String] as? String) != "Window Server"
                && (($0[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0
        }
    }

    /// Apps that show a panel of their own (an edge panel, a palette): an on-screen window
    /// of a level between document windows and the menu bar. Such a panel shows itself
    /// again whenever its app likes, which un-hides the app and every window it has.
    static func pidsShowingPanels() -> Set<pid_t> {
        let screens = NSScreen.screens.map { toAX($0.frame) }
        let menuBar = Int(CGWindowLevelForKey(.mainMenuWindow))
        return Set(onScreenWindows().compactMap { info -> pid_t? in
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer > 0, layer < menuBar,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b), rect.width >= 4, rect.height >= 4,
                  screens.contains(where: { $0.intersects(rect) }) else { return nil }
            return (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
        })
    }

    /// Whether the pointer is on a window of the app above its document windows: a panel, a
    /// palette, a status item. An app that comes forward meanwhile was clicked there (⌘Tab
    /// and the Dock leave the pointer elsewhere; an edge panel only stays open while the
    /// pointer is on it). Some apps come forward on such a click while AX goes on naming
    /// their main window as the focused one.
    static func pointerOnPanel(pid: pid_t) -> Bool {
        guard let pointer = CGEvent(source: nil)?.location else { return false }
        // The topmost window under the pointer.
        guard let hit = onScreenWindows().first(where: { info in
            (info[kCGWindowBounds as String] as? NSDictionary)
                .flatMap { CGRect(dictionaryRepresentation: $0) }?.contains(pointer) ?? false
        }) else { return false }
        return (hit[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid
            && ((hit[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0) > 0
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute), isStandard(w) { return w }
        if let w: AXUIElement = attr(app, kAXMainWindowAttribute), isStandard(w) { return w }
        return nil
    }

    /// Ids of every window that currently exists, on screen or not (hidden apps, minimized,
    /// other Spaces). Needs no Accessibility permission.
    /// Every window WindowServer knows, with the bundle id of the app that owns it. Window
    /// ids are only unique within one boot: after a restart a tab's old id can name another
    /// app's window, so "bound" must check the owner too.
    static func existingWindowOwners() -> [CGWindowID: String] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }
        var bundles: [pid_t: String] = [:]
        var out: [CGWindowID: String] = [:]
        for info in list {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { continue }
            if bundles[pid] == nil { bundles[pid] = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
            out[id] = bundles[pid]
        }
        return out
    }

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
