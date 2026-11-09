import Cocoa
import SwiftUI

/// ⌃⌥T: the TicketDeck tickets of the current workspace's projects (or of every project), in a
/// floating panel like ⌃⌥F. Tickets live as markdown in each repo's .tickets/; this panel reads
/// and changes them only through the `ticketdeck` CLI, whose location `ticketdeck setup` writes
/// to ~/.ticketdeck/cli.json, so there is one implementation of the format.
///
/// ↩ jumps to the ticket's Claude session (switching to the project's workspace first),
/// ⌘D marks a ticket done, ⌘R sends it back to todo, ⌘⌫ drops it, Tab switches between this
/// workspace and all projects.
final class TicketPanelController: NSObject, NSWindowDelegate {
    private let manager: WorkspaceManager
    private let model = TicketPanelModel()
    private var panel: SearchPanel?
    private var keyMonitor: Any?
    private var refresh: Timer?

    init(manager: WorkspaceManager) {
        self.manager = manager
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() { isVisible ? close() : show() }

    func show() {
        model.query = ""
        model.scopeFolders = ClaudeSessions.folders(of: manager.currentWorkspace)
        model.workspaceName = manager.currentWorkspace.name
        model.focusToken += 1
        model.loadReports()
        // The first ⌃⌥T of the day opens on today's plan.
        let today = DailyReport.today
        if model.reportDates.first == today, UserDefaults.standard.string(forKey: "ticketPlanShown") != today {
            UserDefaults.standard.set(today, forKey: "ticketPlanShown")
            model.reportIndex = 0
            model.showReport = true
        }
        reload()

        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.16 - size.height))
        }
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.focusField() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.focusField() }

        // Agents edit tickets while you look; follow along.
        refresh?.invalidate()
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.reload() }

        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.panel?.isKeyWindow == true else { return e }
                if let editor = self.panel?.firstResponder as? NSTextView, editor.hasMarkedText() { return e }
                let cmd = e.modifierFlags.contains(.command)
                switch e.keyCode {
                case 53: self.close(); return nil                         // esc
                case 36, 76 where self.model.showReport:                 // return on the plan
                    if let f = self.model.currentFocus { self.focusAction(f) } else { NSSound.beep() }
                    return nil
                case 36, 76: self.jump(); return nil                      // return
                case 125 where self.model.showReport: self.model.moveFocus(1); return nil
                case 126 where self.model.showReport: self.model.moveFocus(-1); return nil
                case 125: self.model.move(1); return nil                  // down
                case 126: self.model.move(-1); return nil                 // up
                case 48: self.model.cycleView(); return nil               // tab: workspace → all → report
                case 123 where self.model.showReport: self.model.stepReport(1); return nil  // ← older
                case 124 where self.model.showReport: self.model.stepReport(-1); return nil // → newer
                case 2 where cmd: self.setStatus("done"); return nil       // ⌘D
                case 15 where cmd: self.setStatus("todo"); return nil      // ⌘R
                // ⌘⌫ also clears the search line, so it drops only while the search is empty.
                case 51 where cmd && self.model.query.isEmpty: self.setStatus("dropped"); return nil
                default: return e
                }
            }
        }
    }

    func close() {
        panel?.orderOut(nil)
        refresh?.invalidate()
        refresh = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func focusField() {
        guard let panel, panel.isVisible else { return }
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

    // MARK: Data

    private func reload() {
        TicketDeckCLI.state { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let projects):
                let first = self.model.projects.isEmpty
                self.model.projects = projects
                self.model.error = nil
                // A workspace with no tickets of its own opens on every project.
                if first { self.model.allProjects = self.model.scopedProjects(all: false).isEmpty }
                self.model.clampSelection()
            case .failure(let error):
                self.model.error = error.localizedDescription
            }
        }
    }

    private func setStatus(_ status: String) {
        guard let t = model.selected else { NSSound.beep(); return }
        TicketDeckCLI.run(["set", t.id, "status=\(status)"], in: t.projectPath) { [weak self] ok in
            if !ok { NSSound.beep() }
            self?.reload()
        }
    }

    fileprivate func toggleCheck(_ t: TicketItem, index: Int, on: Bool) {
        TicketDeckCLI.run(["check", t.id, String(index + 1), on ? "on" : "off"], in: t.projectPath) { [weak self] ok in
            if !ok { NSSound.beep() }
            self?.reload()
        }
    }

    /// A focus item's main action: accept it if it waits for review, else go to its session.
    fileprivate func focusAction(_ f: DailyReport.Focus) {
        if f.kind == "review" {
            TicketDeckCLI.run(["set", f.id, "status=done"], in: f.root) { [weak self] ok in
                if !ok { NSSound.beep() }
                self?.reload()
            }
        } else {
            model.showReport = false
            model.allProjects = true
            model.selectedKey = f.root + "#" + f.id
            jump()
        }
    }

    /// To the workspace that holds the ticket's project, with Claude on the ticket's session.
    fileprivate func jump() {
        guard let t = model.selected else { NSSound.beep(); return }
        let claude = ClaudeSessions.bundleID
        func holds(_ ws: Workspace) -> Bool {
            ClaudeSessions.folders(of: ws).contains { TicketPanelModel.folder($0, isIn: t.projectPath) }
        }
        let target = holds(manager.currentWorkspace) ? manager.currentWorkspace : manager.workspaces.first(where: holds)
        close()
        guard let ws = target else {
            if let s = t.session, s.hasPrefix("local_") {
                ClaudeSessions.open(s)
                NSRunningApplication.runningApplications(withBundleIdentifier: claude).first?.activate()
            } else {
                NSSound.beep()
            }
            return
        }
        let claudeTab = ws.tabs.first { $0.bundleID == claude }
        if let s = t.session, s.hasPrefix("local_"), let claudeTab {
            manager.switchWorkspace(ws.id, to: claudeTab.id)
            manager.setClaudeSession(s, for: ws.id)
        } else {
            manager.switchWorkspace(ws.id)
        }
    }

    private func makePanel() -> SearchPanel {
        let panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: TicketPanelView.size.width, height: TicketPanelView.size.height),
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
        let view = TicketPanelView(model: model,
                                   onJump: { [weak self] in self?.jump() },
                                   onStatus: { [weak self] s in self?.setStatus(s) },
                                   onCheck: { [weak self] t, i, on in self?.toggleCheck(t, index: i, on: on) },
                                   onFocus: { [weak self] f in self?.focusAction(f) })
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hosting
        return panel
    }
}

// MARK: CLI

enum TicketDeckCLI {
    struct Location: Decodable { let node: String; let cli: String }

    enum Failure: LocalizedError {
        case notSetUp, failed(String)
        var errorDescription: String? {
            switch self {
            case .notSetUp: return "TicketDeck not found. Run `ticketdeck setup` in the TicketDeck folder, then try again."
            case .failed(let s): return s
            }
        }
    }

    static var location: Location? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ticketdeck/cli.json")
        guard let data = try? Data(contentsOf: file),
              let loc = try? JSONDecoder().decode(Location.self, from: data),
              FileManager.default.isExecutableFile(atPath: loc.node),
              FileManager.default.fileExists(atPath: loc.cli) else { return nil }
        return loc
    }

    private static let queue = DispatchQueue(label: "ticketdeck-cli", qos: .userInitiated)

    /// Runs the CLI off the main thread; calls back on the main thread.
    private static func exec(_ args: [String], in dir: String?, _ done: @escaping (Result<Data, Error>) -> Void) {
        guard let loc = location else { return done(.failure(Failure.notSetUp)) }
        queue.async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: loc.node)
            p.arguments = [loc.cli] + args
            if let dir { p.currentDirectoryURL = URL(fileURLWithPath: dir) }
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let result: Result<Data, Error>
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                result = p.terminationStatus == 0
                    ? .success(data)
                    : .failure(Failure.failed(String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { done(result) }
        }
    }

    static func state(_ done: @escaping (Result<[TicketProject], Error>) -> Void) {
        exec(["state"], in: nil) { r in
            done(r.flatMap { data in
                Result {
                    struct State: Decodable { let projects: [TicketProject] }
                    var projects = try JSONDecoder().decode(State.self, from: data).projects
                    for i in projects.indices {
                        for j in projects[i].tickets.indices {
                            projects[i].tickets[j].projectPath = projects[i].path
                            projects[i].tickets[j].projectName = projects[i].name
                        }
                    }
                    return projects
                }
            })
        }
    }

    static func run(_ args: [String], in dir: String, _ done: @escaping (Bool) -> Void) {
        exec(args, in: dir) { r in
            if case .success = r { done(true) } else { done(false) }
        }
    }
}

struct TicketProject: Decodable {
    let name: String
    let path: String
    var tickets: [TicketItem]
}

struct TicketItem: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let type: String
    let labels: [String]
    let updated: String
    let created_by: String
    let session: String?
    let depends_on: [String]
    let body: String
    var projectPath = ""
    var projectName = ""

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, type, labels, updated, created_by, session, depends_on, body
    }

    /// Unique across projects (ids restart at T-0001 in each).
    var key: String { projectPath + "#" + id }

    /// Body up to the log, and the log lines (newest last).
    var parts: (description: String, log: [String]) {
        // "## 日志" since tickets are written in Chinese; "## Log" in older ones.
        let heading = ["## 日志", "## Log"].lazy.compactMap { h in
            body.range(of: "\n\(h)\n") ?? (body.hasPrefix("\(h)\n") ? body.range(of: "\(h)\n") : nil)
        }.first
        guard let r = heading else { return (body, []) }
        let log = body[r.upperBound...].split(separator: "\n").map { String($0).replacingOccurrences(of: "- ", with: "", options: .anchored) }
        return (String(body[..<r.lowerBound]), log)
    }

    /// Checklist items in body order, matching the CLI's numbering.
    var checklist: [(text: String, done: Bool)] {
        body.split(separator: "\n", omittingEmptySubsequences: false).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["- [", "* [", "+ ["] where s.hasPrefix(prefix) && s.count >= 5 {
                let mark = s[s.index(s.startIndex, offsetBy: 3)]
                guard mark == " " || mark == "x" || mark == "X",
                      s[s.index(s.startIndex, offsetBy: 4)] == "]" else { return nil }
                return (String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces), mark != " ")
            }
            return nil
        }
    }
}

// MARK: Model

final class TicketPanelModel: ObservableObject {
    @Published var projects: [TicketProject] = []
    @Published var query = ""
    @Published var allProjects = false
    /// The daily report instead of the ticket list (TicketDeck writes one each morning).
    @Published var showReport = false
    @Published var reportDates: [String] = []
    @Published var reportIndex = 0
    @Published var report: DailyReport?

    static var reportsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ticketdeck/reports")
    }

    func cycleView() {
        if showReport { showReport = false; allProjects = false }
        else if allProjects { showReport = true; loadReports() }
        else { allProjects = true }
        clampSelection()
    }

    /// Newest first; keeps the date shown if it still exists.
    func loadReports() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.reportsDir.path)) ?? []
        let shown = reportDates.indices.contains(reportIndex) ? reportDates[reportIndex] : nil
        reportDates = names.filter { $0.range(of: #"^\d{4}-\d{2}-\d{2}\.json$"#, options: .regularExpression) != nil }
            .map { String($0.prefix(10)) }.sorted(by: >)
        reportIndex = shown.flatMap { reportDates.firstIndex(of: $0) } ?? 0
        readReport()
    }

    func stepReport(_ d: Int) {
        guard !reportDates.isEmpty else { return }
        reportIndex = min(max(reportIndex + d, 0), reportDates.count - 1)
        readReport()
    }

    private func readReport() {
        guard reportDates.indices.contains(reportIndex),
              let data = try? Data(contentsOf: Self.reportsDir.appendingPathComponent("\(reportDates[reportIndex]).json"))
        else { report = nil; return }
        report = try? JSONDecoder().decode(DailyReport.self, from: data)
        focusIndex = 0
    }

    @Published var focusIndex = 0

    var currentFocus: DailyReport.Focus? {
        guard let f = report?.focus, f.indices.contains(focusIndex) else { return nil }
        return f[focusIndex]
    }

    func moveFocus(_ d: Int) {
        guard let n = report?.focus.count, n > 0 else { return }
        focusIndex = min(max(focusIndex + d, 0), n - 1)
    }

    /// The ticket's status now (the report is a morning snapshot).
    func liveStatus(root: String, id: String) -> String? {
        projects.first { $0.path == root }?.tickets.first { $0.id == id }?.status
    }

    /// From a report row to the ticket in the list.
    func openTicket(root: String, id: String) {
        showReport = false
        allProjects = true
        selectedKey = root + "#" + id
    }
    @Published var selectedKey: String?
    @Published var error: String?
    @Published var focusToken = 0
    var scopeFolders: [String] = []
    var workspaceName = ""

    static let order = ["doing", "review", "todo", "done"]
    static let names = ["doing": "Doing", "review": "Review", "todo": "To do", "done": "Done"]

    static func folder(_ folder: String, isIn project: String) -> Bool {
        folder == project || folder.hasPrefix(project + "/") || project.hasPrefix(folder + "/")
    }

    func scopedProjects(all: Bool) -> [TicketProject] {
        all ? projects : projects.filter { p in scopeFolders.contains { Self.folder($0, isIn: p.path) } }
    }

    /// Visible tickets, grouped by status in display order.
    var groups: [(status: String, tickets: [TicketItem])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = scopedProjects(all: allProjects).flatMap(\.tickets).filter { t in
            q.isEmpty || t.title.lowercased().contains(q) || t.id.lowercased().contains(q)
                || t.projectName.lowercased().contains(q) || t.labels.contains { $0.lowercased().contains(q) }
        }
        return Self.order.compactMap { s in
            let ts = all.filter { $0.status == s }
            return ts.isEmpty ? nil : (s, ts)
        }
    }

    var flat: [TicketItem] { groups.flatMap(\.tickets) }

    var selected: TicketItem? { flat.first { $0.key == selectedKey } }

    func move(_ d: Int) {
        let list = flat
        guard !list.isEmpty else { return }
        let i = list.firstIndex { $0.key == selectedKey } ?? (d > 0 ? -1 : list.count)
        selectedKey = list[min(max(i + d, 0), list.count - 1)].key
    }

    func clampSelection() {
        let list = flat
        if !list.contains(where: { $0.key == selectedKey }) { selectedKey = list.first?.key }
    }
}

// MARK: View

private struct TicketPanelView: View {
    static let size = CGSize(width: 820, height: 500)

    @ObservedObject var model: TicketPanelModel
    let onJump: () -> Void
    let onStatus: (String) -> Void
    let onCheck: (TicketItem, Int, Bool) -> Void
    let onFocus: (DailyReport.Focus) -> Void
    @State private var openFolds: Set<String> = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.error {
                Text(error).foregroundColor(.secondary).padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.showReport {
                report
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 340)
                    Divider()
                    detail.frame(maxWidth: .infinity)
                }
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { _ in focused = true }
        .onChange(of: model.query) { _ in model.clampSelection() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.showReport {
                Image(systemName: "sun.max").foregroundColor(.orange)
                Text("今日计划").font(.system(size: 18, weight: .medium))
                Spacer()
            } else {
                Image(systemName: "checklist").foregroundColor(.secondary)
                TextField("Search tickets", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
            }
            Button {
                model.showReport.toggle()
                if model.showReport { model.loadReports() }
            } label: {
                Label("今日计划", systemImage: "sun.max")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(model.showReport ? Color.orange.opacity(0.2) : Color.primary.opacity(0.06)))
                    .foregroundColor(model.showReport ? .orange : .primary)
            }
            .buttonStyle(.plain)
            Picker("", selection: Binding(
                get: { model.allProjects ? 1 : 0 },
                set: { v in
                    model.showReport = false
                    model.allProjects = v == 1
                    model.clampSelection()
                })) {
                Text(model.workspaceName.isEmpty ? "This workspace" : model.workspaceName).tag(0)
                Text("All projects").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .opacity(model.showReport ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: []) {
                    ForEach(model.groups, id: \.status) { group in
                        HStack(spacing: 5) {
                            Circle().fill(statusColor(group.status)).frame(width: 7, height: 7)
                            Text(TicketPanelModel.names[group.status] ?? group.status)
                                .foregroundColor(statusColor(group.status))
                            Text("\(group.tickets.count)").foregroundColor(.secondary)
                        }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 8)
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                        ForEach(group.tickets, id: \.key) { t in row(t).id(t.key) }
                    }
                    if model.groups.isEmpty {
                        Text(model.projects.isEmpty ? "No tickets yet" : model.allProjects ? "No matching tickets" : "No tickets for this workspace's projects (Tab for all)")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selectedKey) { k in if let k { proxy.scrollTo(k) } }
        }
    }

    private func row(_ t: TicketItem) -> some View {
        let selected = t.key == model.selectedKey
        return Button { model.selectedKey = t.key } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(statusColor(t.status)).frame(width: 3, height: 16)
                Text(t.id).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                Text(t.title).font(.system(size: 12.5)).lineLimit(1)
                    .foregroundColor(t.status == "done" ? .secondary : .primary)
                    .strikethrough(t.status == "dropped")
                if t.priority == "P0" || t.priority == "P1" {
                    Text(t.priority).font(.system(size: 9, weight: .bold)).foregroundColor(priorityColor(t.priority))
                }
                Spacer(minLength: 4)
                if model.allProjects {
                    Text(t.projectName).font(.system(size: 9)).foregroundColor(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if t.session != nil && t.status == "doing" {
                    Image(systemName: "bubble.left.fill").font(.system(size: 9)).foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.25) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { model.selectedKey = t.key; onJump() })
    }

    @ViewBuilder private var detail: some View {
        if let t = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text("\(t.projectName) · \(t.id)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                        Spacer()
                        statusChip(t.status)
                        chip(t.priority)
                        chip(t.type)
                    }
                    Text(t.title).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if !t.labels.isEmpty || !t.depends_on.isEmpty {
                        Text((t.labels.map { "#\($0)" } + t.depends_on.map { "needs \($0)" }).joined(separator: "  "))
                            .font(.system(size: 11)).foregroundColor(.secondary)
                    }
                    actions(t)
                    Divider()
                    description(t)
                    let log = t.parts.log
                    if !log.isEmpty {
                        Text("Log").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary).padding(.top, 4)
                        ForEach(Array(log.suffix(8).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a ticket").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func actions(_ t: TicketItem) -> some View {
        HStack(spacing: 8) {
            Button(t.session?.hasPrefix("local_") == true ? "Open session ↩" : "Go to workspace ↩", action: onJump)
            if t.status == "review" || t.status == "doing" || t.status == "todo" {
                Button("Done ⌘D") { onStatus("done") }
            }
            if t.status != "todo" {
                Button("Back to to do ⌘R") { onStatus("todo") }
            }
            Button("Drop ⌘⌫") { onStatus("dropped") }
            Spacer()
            if let s = t.session {
                Text(s.hasPrefix("local_") ? String(s.prefix(14)) : s).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
            }
        }
        .controlSize(.small)
    }

    /// The description, with checklist items as checkboxes that tick the item in the file.
    private func description(_ t: TicketItem) -> some View {
        var checkIndex = -1
        let lines = t.parts.description.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let items: [(Int, String, Int?)] = lines.enumerated().map { i, line in
            let s = line.trimmingCharacters(in: .whitespaces)
            let isCheck = ["- [ ]", "- [x]", "- [X]", "* [ ]", "* [x]", "+ [ ]", "+ [x]"].contains { s.hasPrefix($0) }
            if isCheck { checkIndex += 1 }
            return (i, line, isCheck ? checkIndex : nil)
        }
        let checklist = t.checklist
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.0) { _, line, check in
                if let check, checklist.indices.contains(check) {
                    Toggle(isOn: Binding(get: { checklist[check].done }, set: { onCheck(t, check, $0) })) {
                        Text(inline(checklist[check].text)).font(.system(size: 12.5))
                    }
                    .toggleStyle(.checkbox)
                } else if line.hasPrefix("#") {
                    Text(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 12.5, weight: .semibold)).padding(.top, 4)
                } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(inline(line)).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    private func statusChip(_ status: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(statusColor(status)).frame(width: 6, height: 6)
            Text(TicketPanelModel.names[status] ?? status)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundColor(statusColor(status))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(statusColor(status).opacity(0.16)))
    }

    /// One colour per status, shared with the web board.
    private func statusColor(_ s: String) -> Color {
        switch s {
        case "doing": return .blue
        case "review": return .orange
        case "done": return .green
        case "dropped": return .red
        default: return .gray
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text).font(.system(size: 10))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func priorityColor(_ p: String) -> Color {
        switch p {
        case "P0": return .red
        case "P1": return .orange
        case "P2": return .blue
        default: return .gray
        }
    }

    /// 今日计划: the day's summary and up to three focus items, everything else folded away.
    @ViewBuilder private var report: some View {
        if let r = model.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(r.dayTitle).font(.system(size: 17, weight: .semibold))
                        Text(r.statusLine).font(.system(size: 11.5)).foregroundColor(.secondary)
                        Spacer()
                        if model.reportDates.count > 1 {
                            Text("\(model.reportIndex + 1) / \(model.reportDates.count)").font(.system(size: 10)).foregroundColor(.secondary)
                        }
                    }
                    if let summary = r.summary, !summary.isEmpty {
                        Text(summary).font(.system(size: 13)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 10)
                    }
                    Text("今日重点").font(.system(size: 11)).foregroundColor(.secondary).padding(.top, 16).padding(.bottom, 6)
                    if r.focus.isEmpty {
                        Text("今天没有需要你优先处理的任务。").font(.system(size: 12.5)).foregroundColor(.secondary)
                    }
                    VStack(spacing: 6) {
                        ForEach(Array(r.focus.enumerated()), id: \.offset) { n, f in focusRow(f, n) }
                    }
                    VStack(spacing: 0) {
                        Divider().padding(.top, 14)
                        fold("昨日进展", r.activity.count, .green) {
                            ForEach(r.activity, id: \.root) { a in
                                HStack(spacing: 6) {
                                    Text(a.project).font(.system(size: 12)).frame(width: 160, alignment: .leading)
                                    if a.done > 0 { pill("完成 \(a.done)", .green) }
                                    if a.updated > 0 { pill("更新 \(a.updated)", .blue) }
                                    if a.created > 0 { pill("新增 \(a.created)", .gray) }
                                    Spacer()
                                }
                            }
                        }
                        fold("进行中", r.doing.count, .blue) { foldList(r.doing) }
                        fold("待验收", r.review.count, .orange) { foldList(r.review) }
                        fold("待决策与待执行", r.totals.decisions, .purple) {
                            foldList(r.decisions)
                            if r.totals.decisions > r.decisions.count {
                                Text("另有 \(r.totals.decisions - r.decisions.count) 项，在 All projects 里搜 decision 或 needs-user")
                                    .font(.system(size: 10.5)).foregroundColor(.secondary)
                            }
                        }
                        fold("待纳入计划", r.leftovers?.count ?? 0, .yellow) {
                            ForEach(Array((r.leftovers ?? []).enumerated()), id: \.offset) { _, l in
                                HStack(spacing: 6) {
                                    Text(l.project).font(.system(size: 12)).foregroundColor(.secondary)
                                    Text(l.task).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("还没有今日计划。每天早上 8 点自动生成\n（也可以运行 ticketdeck report --save）。")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static let kinds: [String: (String, Color)] = [
        "review": ("待验收", .orange), "decision": ("待决策", .purple),
        "action": ("需你执行", .purple), "push": ("优先推进", .blue),
    ]

    private func focusRow(_ f: DailyReport.Focus, _ n: Int) -> some View {
        let (label, color) = Self.kinds[f.kind] ?? ("优先推进", .blue)
        let status = model.liveStatus(root: f.root, id: f.id)
        let finished = status == "done" || status == "dropped"
        let selected = n == model.focusIndex
        return HStack(spacing: 12) {
            Text("\(n + 1)").font(.system(size: 17, weight: .semibold)).foregroundColor(finished ? .secondary : color).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                (Text(f.project + " · ").foregroundColor(.secondary) + Text(f.title))
                    .font(.system(size: 13)).lineLimit(2).strikethrough(finished)
                HStack(spacing: 8) {
                    Text(finished ? "已完成" : label).font(.system(size: 10.5, weight: .medium)).foregroundColor(finished ? .green : color)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((finished ? Color.green : color).opacity(0.15)))
                    if f.idleDays >= 2 && !finished {
                        Text("\(f.idleDays) 天未推进").font(.system(size: 10.5)).foregroundColor(.secondary)
                    }
                    if let reason = f.reason {
                        Text(reason).font(.system(size: 11)).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 6)
            if !finished {
                Button(f.kind == "review" ? "验收通过" : f.session?.hasPrefix("local_") == true ? "继续会话" : "查看") { onFocus(f) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.08)))
        .opacity(finished ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { model.focusIndex = n }
    }

    /// A folded section: one line with a count; click to open.
    @ViewBuilder private func fold<Content: View>(_ title: String, _ count: Int, _ c: Color, @ViewBuilder _ content: () -> Content) -> some View {
        if count > 0 {
            let open = openFolds.contains(title)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    if open { openFolds.remove(title) } else { openFolds.insert(title) }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(c).frame(width: 6, height: 6)
                        Text(title).font(.system(size: 12.5))
                        Spacer()
                        Text("\(count)").font(.system(size: 11)).foregroundColor(.secondary)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundColor(.secondary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open { VStack(alignment: .leading, spacing: 3) { content() }.padding(.leading, 13).padding(.bottom, 8) }
                Divider()
            }
        }
    }

    private func foldList(_ items: [DailyReport.Item]) -> some View {
        ForEach(items, id: \.key) { i in
            Button { model.openTicket(root: i.root, id: i.id) } label: {
                HStack(spacing: 6) {
                    Text(i.project).font(.system(size: 12)).foregroundColor(.secondary)
                    Text(i.title).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    if i.stale == true { Text("停滞").font(.system(size: 10.5)).foregroundColor(.red) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func tile(_ n: Int, _ label: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.system(size: 20, weight: .bold)).foregroundColor(n > 0 ? c : .secondary)
            Text(label).font(.system(size: 10.5)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(n > 0 ? c.opacity(0.14) : Color.primary.opacity(0.05)))
    }

    private func sectionTitle(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(c)
        }
    }

    @ViewBuilder private func reportSection(_ title: String, _ c: Color, _ items: [DailyReport.Item], more: String? = nil) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle(title, c)
                ForEach(items, id: \.key) { i in
                    Button { model.openTicket(root: i.root, id: i.id) } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 1.5).fill(i.stale == true ? Color.red : c).frame(width: 3, height: 14)
                            Text(i.priority).font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(i.priority == "P0" ? .red : i.priority == "P1" ? .orange : .secondary)
                            projectChip(i.project)
                            Text(i.title).font(.system(size: 12.5)).lineLimit(1)
                            Spacer(minLength: 4)
                            if i.stale == true { Text("停滞").font(.system(size: 10, weight: .semibold)).foregroundColor(.red) }
                        }
                        .padding(.vertical, 3).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if let more { Text(more).font(.system(size: 10.5)).foregroundColor(.secondary).padding(.leading, 13) }
            }
        }
    }

    private func projectChip(_ name: String) -> some View {
        Text(name).font(.system(size: 9.5)).foregroundColor(.accentColor)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
    }

    private func pill(_ t: String, _ c: Color) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundColor(c)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(c.opacity(0.15)))
    }

    private var footer: some View {
        HStack {
            Text(model.showReport ? "↑↓ 选择   ↩ 执行   ←→ 前一天 / 后一天   Tab 回到任务列表   esc 关闭"
                                  : "↑↓ select   ↩ open session   ⌘D done   ⌘R to do   ⌘⌫ drop   Tab scope   esc close")
            Spacer()
            let open = model.scopedProjects(all: model.allProjects).flatMap(\.tickets).filter { $0.status != "done" }.count
            Text("\(open) open")
        }
        .font(.system(size: 10))
        .foregroundColor(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 26)
    }
}

/// TicketDeck's daily report (~/.ticketdeck/reports/<date>.json).
struct DailyReport: Decodable {
    struct Totals: Decodable { let open, review, doing, todo, decisions, done, stale, projects: Int }
    struct Item: Decodable {
        let project, root, id, title, priority, updated: String
        let session: String?
        let stale: Bool?
        var key: String { root + "#" + id }
    }
    struct Activity: Decodable { let project, root: String; let created, done, updated: Int }
    struct Leftover: Decodable { let project, task: String; let session: String? }
    struct Focus: Decodable {
        let project, root, id, title, priority, kind: String
        let session: String?
        let idleDays: Int
        let reason: String?
    }

    let date, generatedAt: String
    let totals: Totals
    let summary: String?
    let review, decisions, doing, priorities: [Item]
    let activity: [Activity]
    let leftovers: [Leftover]?
    let focusList: [Focus]?
    var focus: [Focus] { focusList ?? [] }

    enum CodingKeys: String, CodingKey {
        case date, generatedAt, totals, summary, review, decisions, doing, priorities, activity, leftovers
        case focusList = "focus"
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var statusLine: String {
        let parts = [totals.done > 0 ? "昨日完成 \(totals.done) 项" : nil,
                     totals.review > 0 ? "\(totals.review) 项待验收" : nil,
                     totals.stale > 0 ? "\(totals.stale) 项停滞" : nil].compactMap { $0 }
        return parts.isEmpty ? "\(totals.open) 项任务进行中" : parts.joined(separator: " · ")
    }

    var dayTitle: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        let c = Calendar.current.dateComponents([.month, .day, .weekday], from: d)
        let week = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"][(c.weekday ?? 1) - 1]
        return "\(c.month ?? 0) 月 \(c.day ?? 0) 日 · \(week)"
    }

    var generatedTime: String {
        guard let d = ISO8601DateFormatter.withFraction.date(from: generatedAt) ?? ISO8601DateFormatter().date(from: generatedAt)
        else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

private extension ISO8601DateFormatter {
    static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
