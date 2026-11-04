import Cocoa
import SwiftUI

/// Shared timing for every animation, so the whole app moves with one feel.
enum Motion {
    /// Honors System Settings → Accessibility → Display → Reduce motion.
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Selection highlight sliding between tabs.
    static let selection = Animation.spring(response: 0.32, dampingFraction: 0.82)
    /// Workspace page change in the sidebar.
    static let page = Animation.spring(response: 0.38, dampingFraction: 0.86)
    /// Hover / press feedback.
    static let press = Animation.spring(response: 0.22, dampingFraction: 0.7)

    static let curtainIn: TimeInterval = 0.10
    static let curtainOut: TimeInterval = 0.22
    /// Minimum time the curtain stays fully up, covering the app's first redraw.
    static let curtainHold: TimeInterval = 0.08
    static let sidebarIn: TimeInterval = 0.24
    static let sidebarOut: TimeInterval = 0.18

    /// User toggle for the switch curtain (menu bar menu → 切换动画).
    static var curtainEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "switchAnimation") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "switchAnimation") }
    }
}

/// A frosted layer over the content area that hides the window juggling of a switch
/// (un-hiding, moving, resizing, raising, hiding the others). It fades in, the switch
/// runs behind it, and it fades out once the new window is in place — so a switch reads
/// as one crossfade instead of several visible jumps.
final class SwitchCurtain {
    static let shared = SwitchCurtain()

    private var panel: NSPanel?
    private var token = 0
    private var raisedAt = Date.distantPast

    /// Fades the curtain in over `frame` (Cocoa coordinates), then runs `action` once it
    /// covers the screen. A newer call supersedes an older one that hasn't run yet.
    func cover(_ frame: NSRect, icon: NSImage?, then action: @escaping () -> Void) {
        guard Motion.curtainEnabled else { action(); return }
        token += 1
        let t = token
        let p = panel ?? makePanel()
        panel = p

        p.contentView = NSHostingView(rootView: CurtainView(icon: icon))
        p.setFrame(frame, display: true)

        let fade = Motion.reduce ? 0.06 : Motion.curtainIn
        let remaining = p.isVisible ? fade * Double(1 - p.alphaValue) : fade
        if !p.isVisible {
            p.alphaValue = 0
            p.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = remaining
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            guard let self, self.token == t else { return }
            self.raisedAt = Date()
            action()
        }
        // Never get stuck over the screen, e.g. when an app takes long to open a window.
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 1.5) { [weak self] in
            guard let self, self.token == t else { return }
            self.lower()
        }
    }

    /// Call when the target window is in place.
    func reveal() {
        guard let p = panel, p.isVisible else { return }
        let t = token
        let wait = max(0, Motion.curtainHold - Date().timeIntervalSince(raisedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.token == t else { return }
            self.lower()
        }
    }

    private func lower() {
        guard let p = panel else { return }
        let t = token
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.reduce ? 0.1 : Motion.curtainOut
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            if self?.token == t { p.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Above regular app windows, below the sidebar (which is .floating).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return p
    }
}

private struct CurtainView: View {
    let icon: NSImage?
    @State private var settled = false

    var body: some View {
        ZStack {
            FrostedBackground()
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                    .scaleEffect(settled || Motion.reduce ? 1 : 0.86)
                    .opacity(settled ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { settled = true }
        }
    }
}

private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
