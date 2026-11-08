import Cocoa
import ApplicationServices

/// Reports when the focused window changes inside an app, e.g. clicking a second Chrome
/// window. App-level activation notifications don't fire for that, since the app stays
/// frontmost; only a per-app AXObserver sees it.
final class WindowWatcher {
    /// Called on the main thread with the pid of the app whose focused window changed.
    var onFocusChange: ((pid_t) -> Void)?
    /// Called on the main thread when a window passed to `watchClose` goes away.
    var onWindowClosed: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]

    /// Watches exactly these processes: starts new observers, drops ones for apps that
    /// are gone or no longer have tabs.
    func watch(_ pids: Set<pid_t>) {
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            var observer: AXObserver?
            guard AXObserverCreate(pid, windowWatcherCallback, &observer) == .success, let observer else { continue }
            let app = AXUIElementCreateApplication(pid)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, refcon)
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }

    /// Also report when this window closes (its app must be watched).
    func watchClose(_ window: AXUIElement, pid: pid_t) {
        guard let observer = observers[pid] else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Registering a window twice just returns "already registered".
        AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    fileprivate func closed() { onWindowClosed?() }

    fileprivate func fire(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        onFocusChange?(pid)
    }
}

private func windowWatcherCallback(_ observer: AXObserver, _ element: AXUIElement,
                                   _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<WindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    if CFEqual(notification, kAXUIElementDestroyedNotification as CFString) {
        watcher.closed()
    } else {
        watcher.fire(element)
    }
}

