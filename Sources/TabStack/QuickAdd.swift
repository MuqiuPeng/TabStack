import Cocoa
import SwiftUI

/// ⌃⌥A: a Spotlight-style box for adding a window or app to the current workspace.
/// Empty, the window you were just using comes first (so ⌃⌥A ↩ adopts it), then the other
/// open windows and fresh windows of Finder / terminals / browsers; typing also finds
/// installed apps that are not running.
final class QuickAddController: NSObject, NSWindowDelegate {
    private let manager: WorkspaceManager
    private let model = QuickAddModel()
    private var panel: SearchPanel?
    private var keyMonitor: Any?
    private var all: [QuickAddItem] = []

    init(manager: WorkspaceManager) {
        self.manager = manager
        super.init()
    }

    func toggle() { panel?.isVisible == true ? close() : show() }

    func show() {
        guard AX.isTrusted else { AX.requestTrust(); return }
        let workspaceID = manager.currentWorkspaceID
        model.workspaceName = manager.currentWorkspace.name
        all = buildItems(workspaceID: workspaceID)
        model.query = ""
        filter()
        model.focusToken += 1

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.22 - size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        focusField(in: panel)
        DispatchQueue.main.async { [weak self] in self?.focusField(in: panel) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusField(in: panel) }

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.panel?.isKeyWindow == true else { return e }
                if let editor = self.panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return e }
                switch e.keyCode {
                case 53: self.close(); return nil
                case 36, 76: self.run(self.model.selection); return nil
                case 125: self.move(1); return nil
                case 126: self.move(-1); return nil
                default: return e
                }
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Items

    private func buildItems(workspaceID: UUID) -> [QuickAddItem] {
        let m = manager
        var items: [QuickAddItem] = []

        // The window in front (the panel does not take focus from it).
        // Claude's window may sit in several workspaces, so leave out only what this one has.
        let here = Set(m.workspaces.first { $0.id == workspaceID }?.tabs.compactMap(\.windowID) ?? [])
        let addable = m.addableApps().compactMap { entry -> AddableApp? in
            let windows = entry.windows.filter { !here.contains($0.id) }
            if windows.isEmpty && !entry.windows.isEmpty { return nil }
            return AddableApp(app: entry.app, windows: windows)
        }
        var frontID: CGWindowID?
        if let app = NSWorkspace.shared.frontmostApplication,
           app.bundleIdentifier != Bundle.main.bundleIdentifier,
           let entry = addable.first(where: { $0.app == app }),
           let w = AX.focusedWindow(pid: app.processIdentifier), let id = AX.windowID(w),
           let win = entry.windows.first(where: { $0.id == id }) {
            frontID = id
            let name = app.localizedName ?? app.bundleIdentifier ?? "?"
            items.append(QuickAddItem(
                id: "front", section: "当前窗口", title: win.title.isEmpty ? name : win.title,
                subtitle: name, icon: m.icon(for: app.bundleIdentifier ?? ""), keywords: name, bundleID: app.bundleIdentifier ?? "") {
                    m.addWindow(id, title: win.title, of: app, to: workspaceID)
                })
        }

        for entry in addable {
            let app = entry.app
            let bundleID = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? bundleID
            if entry.windows.isEmpty {
                items.append(QuickAddItem(
                    id: "app-\(bundleID)", section: "已打开的窗口", title: name, subtitle: "没有窗口，出现后自动绑定",
                    icon: m.icon(for: bundleID), keywords: bundleID, bundleID: bundleID) {
                        m.addApp(bundleID, name: name, to: workspaceID)
                    })
            }
            for w in entry.windows where w.id != frontID {
                items.append(QuickAddItem(
                    id: "win-\(w.id)", section: "已打开的窗口", title: w.title.isEmpty ? "未命名窗口" : w.title,
                    subtitle: name, icon: m.icon(for: bundleID), keywords: name, bundleID: bundleID) {
                        m.addWindow(w.id, title: w.title, of: app, to: workspaceID)
                    })
            }
        }

        for app in NewWindow.apps() {
            for target in app.targets {
                let profile = target.profile?.label
                items.append(QuickAddItem(
                    id: "new-\(app.bundleID)-\(target.profile?.dir ?? "")", section: "新建窗口",
                    title: "新建\(app.name)窗口", subtitle: profile ?? "",
                    icon: m.icon(for: app.bundleID), keywords: "\(app.name) new 新建 \(profile ?? "")", bundleID: app.bundleID) {
                        m.createWindow(target, in: workspaceID)
                    })
            }
        }

        for (tab, ws) in m.windowsInOtherWorkspaces(than: workspaceID) {
            items.append(QuickAddItem(
                id: "share-\(tab.windowID ?? 0)", section: "其他工作区的窗口（两边都会保留）",
                title: tab.displayName, subtitle: "\(tab.name) · 在“\(ws.name)”",
                icon: m.icon(for: tab.bundleID), keywords: "\(tab.bundleID) \(ws.name)", bundleID: tab.bundleID) {
                    m.shareWindow(of: tab, into: workspaceID)
                })
        }

        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for app in InstalledApps.list() where !running.contains(app.bundleID) {
            items.append(QuickAddItem(
                id: "launch-\(app.bundleID)", section: "打开应用", title: app.name, subtitle: "打开并添加",
                icon: NSWorkspace.shared.icon(forFile: app.url.path), keywords: app.bundleID, bundleID: app.bundleID, onlyWhenSearching: true) {
                    m.addApp(app.bundleID, name: app.name, to: workspaceID)
                })
        }
        return items
    }

    private func filter() {
        let q = model.query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty {
            model.results = all.filter { !$0.onlyWhenSearching }
        } else {
            let words = q.split(separator: " ").map(String.init)
            let hits = all.filter { item in
                let text = "\(item.title) \(item.subtitle) \(item.keywords) \(AppNames.aliases(item.bundleID))".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            // Names that start with the query first, then the rest in their usual order.
            model.results = hits.filter { $0.title.lowercased().hasPrefix(q) || $0.subtitle.lowercased().hasPrefix(q) }
                + hits.filter { !($0.title.lowercased().hasPrefix(q) || $0.subtitle.lowercased().hasPrefix(q)) }
        }
        model.selection = 0
    }

    private func move(_ d: Int) {
        guard !model.results.isEmpty else { return }
        model.selection = min(max(model.selection + d, 0), model.results.count - 1)
    }

    private func run(_ index: Int) {
        guard model.results.indices.contains(index) else { NSSound.beep(); return }
        let item = model.results[index]
        close()
        item.action()
        HUD.shared.show(title: "已添加到“\(model.workspaceName)”", subtitle: item.title, icon: item.icon)
    }

    // MARK: Panel

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

    private func makePanel() -> SearchPanel {
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
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
        let view = QuickAddView(model: model,
                                onQuery: { [weak self] _ in self?.filter() },
                                onRun: { [weak self] i in self?.run(i) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        return panel
    }
}

struct QuickAddItem: Identifiable {
    let id: String
    let section: String
    let title: String
    let subtitle: String
    let icon: NSImage
    let keywords: String
    var bundleID = ""
    var onlyWhenSearching = false
    let action: () -> Void
}

final class QuickAddModel: ObservableObject {
    @Published var query = ""
    @Published var results: [QuickAddItem] = []
    @Published var selection = 0
    @Published var focusToken = 0
    @Published var workspaceName = ""
}

/// Apps in the Applications folders, for adding one that is not running yet.
enum InstalledApps {
    struct App { let bundleID: String; let name: String; let url: URL }

    private static var cache: (at: Date, apps: [App])?

    static func list() -> [App] {
        if let cache, Date().timeIntervalSince(cache.at) < 300 { return cache.apps }
        let fm = FileManager.default
        let dirs = ["/Applications", "/Applications/Utilities", "/System/Applications",
                    "/System/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var apps: [App] = []
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasSuffix(".app") {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let id = Bundle(url: url)?.bundleIdentifier, seen.insert(id).inserted else { continue }
                let display = fm.displayName(atPath: url.path)
                apps.append(App(bundleID: id, name: display.hasSuffix(".app") ? String(display.dropLast(4)) : display, url: url))
            }
        }
        apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = (Date(), apps)
        return apps
    }
}

private struct QuickAddView: View {
    @ObservedObject var model: QuickAddModel
    let onQuery: (String) -> Void
    let onRun: (Int) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.square.on.square").foregroundColor(.secondary)
                TextField("添加到“\(model.workspaceName)”", text: $model.query)
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
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { i, item in
                            if i == 0 || model.results[i - 1].section != item.section {
                                Text(item.section)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.top, i == 0 ? 0 : 6)
                                    .padding(.bottom, 2)
                            }
                            row(item, index: i).id(item.id)
                        }
                        if model.results.isEmpty {
                            Text("没有匹配的窗口或应用")
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
                Text("↑↓ 选择   ↩ 添加   esc 关闭")
                Spacer()
                Text("输入名称可以搜索未打开的应用")
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 26)
        }
        .frame(width: 520, height: 400)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
    }

    private func row(_ item: QuickAddItem, index: Int) -> some View {
        let selected = index == model.selection
        return Button { onRun(index) } label: {
            HStack(spacing: 10) {
                Image(nsImage: item.icon).resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { model.selection = index } }
    }
}

/// Every name an app goes by (英文名、中文名…), so "微信" finds WeChat.
enum AppNames {
    private static var cache: [String: String] = [:]

    static func aliases(_ bundleID: String) -> String {
        guard !bundleID.isEmpty else { return "" }
        if let hit = cache[bundleID] { return hit }
        var names = Set<String>()
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID), let bundle = Bundle(url: url) {
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let n = bundle.infoDictionary?[key] as? String { names.insert(n) }
            }
            names.insert(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            for loc in bundle.localizations {
                for table in ["InfoPlist", "InfoPlist.loctable"] {
                    guard let path = bundle.path(forResource: table.components(separatedBy: ".").first,
                                                 ofType: table.hasSuffix("loctable") ? "loctable" : "strings",
                                                 inDirectory: nil, forLocalization: loc),
                          let dict = NSDictionary(contentsOfFile: path) else { continue }
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let n = dict[key] as? String { names.insert(n) }
                    }
                }
            }
            // A .loctable keeps every language in one file, keyed by language first.
            if let path = bundle.path(forResource: "InfoPlist", ofType: "loctable"),
               let dict = NSDictionary(contentsOfFile: path) as? [String: [String: Any]] {
                for strings in dict.values {
                    for key in ["CFBundleDisplayName", "CFBundleName"] {
                        if let n = strings[key] as? String { names.insert(n) }
                    }
                }
            }
        }
        let joined = names.joined(separator: " ")
        cache[bundleID] = joined
        return joined
    }
}
