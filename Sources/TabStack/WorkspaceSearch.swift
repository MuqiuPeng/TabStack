import Cocoa
import SwiftUI

/// ⌃⌥F: a Spotlight-style box for jumping to any workspace, including the ones the
/// sidebar keeps out of sight. Empty, it lists recommendations (by frecency).
///
/// The panel is non-activating yet can become key, so you can type into it while the app
/// you were using stays frontmost; Esc or a click elsewhere just closes it.
final class WorkspaceSearchController: NSObject, NSWindowDelegate {
    private let manager: WorkspaceManager
    private let model = SearchModel()
    private var panel: SearchPanel?
    private var keyMonitor: Any?

    init(manager: WorkspaceManager) {
        self.manager = manager
        super.init()
    }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        model.query = ""
        model.selection = 0
        model.results = manager.searchWorkspaces("")
        model.focusToken += 1

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.22 - size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        // SwiftUI focus set while the panel was hidden does not stick; put the caret in
        // the field through AppKit once the panel is key.
        focusField(in: panel)
        DispatchQueue.main.async { [weak self] in self?.focusField(in: panel) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusField(in: panel) }

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.panel?.isKeyWindow == true else { return e }
                // While an input method is composing (pinyin), its keys belong to it.
                if let editor = self.panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return e }
                switch e.keyCode {
                case 53: self.close(); return nil                  // esc
                case 36, 76: self.open(self.model.selection); return nil // return / enter
                case 125: self.move(1); return nil                 // down
                case 126: self.move(-1); return nil                // up
                default: return e
                }
            }
        }
    }

    private func focusField(in panel: NSPanel) {
        guard panel.isVisible else { return }
        if !panel.isKeyWindow { panel.makeKey() }
        if let editor = panel.firstResponder as? NSTextView, editor.isFieldEditor { return }
        if let field = findTextField(panel.contentView) { panel.makeFirstResponder(field) }
    }

    private func findTextField(_ view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for sub in view.subviews { if let f = findTextField(sub) { return f } }
        return nil
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func move(_ d: Int) {
        guard !model.results.isEmpty else { return }
        model.selection = min(max(model.selection + d, 0), model.results.count - 1)
    }

    private func open(_ index: Int) {
        guard model.results.indices.contains(index) else { NSSound.beep(); return }
        let id = model.results[index].id
        close()
        manager.switchWorkspace(id)
    }

    private func makePanel() -> SearchPanel {
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                                styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        let view = SearchView(model: model, manager: manager,
                              onQuery: { [weak self] q in
                                  guard let self else { return }
                                  self.model.results = self.manager.searchWorkspaces(q)
                                  self.model.selection = 0
                              },
                              onOpen: { [weak self] i in self?.open(i) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        return panel
    }
}

final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SearchModel: ObservableObject {
    @Published var query = ""
    @Published var results: [Workspace] = []
    @Published var selection = 0
    @Published var focusToken = 0
}

private struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var manager: WorkspaceManager
    let onQuery: (String) -> Void
    let onOpen: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索工作区", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onChange(of: model.query) { onQuery($0) }
            }
            .padding(.horizontal, 16)
            .frame(height: 54)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if model.query.isEmpty {
                            sectionHeader("推荐")
                        }
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { i, ws in
                            row(ws, index: i).id(ws.id)
                        }
                        if model.results.isEmpty {
                            Text("没有匹配的工作区")
                                .foregroundColor(.secondary)
                                .padding(.top, 30)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: model.selection) { i in
                    if model.results.indices.contains(i) { proxy.scrollTo(model.results[i].id) }
                }
            }

            Divider()
            HStack {
                Text("↑↓ 选择   ↩ 打开   esc 关闭")
                Spacer()
                Text("侧边栏显示 \(manager.activeIDs.count) 个，其余收起")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 26)
        }
        .frame(width: 460, height: 360)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }

    private func row(_ ws: Workspace, index: Int) -> some View {
        let selected = index == model.selection
        let shown = manager.activeIDs.contains(ws.id)
        let fallback = manager.workspaces.firstIndex(of: ws) ?? 0
        return Button { onOpen(index) } label: {
            HStack(spacing: 10) {
                Text(String(ws.name.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7).fill(WorkspaceColor.color(for: ws, fallback: fallback)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(ws.name).font(.system(size: 13, weight: .medium))
                    Text(ws.tabs.prefix(4).map(\.displayName).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if ws.id == manager.currentWorkspaceID {
                    tag("当前")
                } else if !shown {
                    tag("已收起")
                }
                if ws.pinned == true {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selection = index } }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}
