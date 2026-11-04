import Cocoa
import SwiftUI

/// A brief, click-through overlay in the middle of the screen, shown when switching
/// with the keyboard so you can see where you landed.
final class HUD {
    static let shared = HUD()

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(title: String, subtitle: String? = nil, icon: NSImage? = nil, color: Color? = nil) {
        let view = HUDView(title: title, subtitle: subtitle, icon: icon, color: color)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = hosting

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let vf = screen?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2,
                                  width: size.width, height: size.height), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel?.animator().alphaValue = 0
            }, completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        return p
    }
}

private struct HUDView: View {
    let title: String
    let subtitle: String?
    let icon: NSImage?
    let color: Color?

    var body: some View {
        VStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 64, height: 64)
            } else if let color {
                Text(String(title.prefix(1)).uppercased())
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 64, height: 64)
                    .background(RoundedRectangle(cornerRadius: 16).fill(color))
            }
            Text(title).font(.system(size: 18, weight: .semibold))
            if let subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 22)
        .frame(minWidth: 180)
        .background(VisualEffectHUD())
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .scaleEffect(appeared || Motion.reduce ? 1 : 0.9)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) { appeared = true }
        }
    }

    @State private var appeared = false
}

private struct VisualEffectHUD: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
