import Foundation

// tabstack-mcp: a Model Context Protocol server (stdio) that lets an AI assistant set up
// TabStack workspaces. It is a thin proxy: every tool call is forwarded to the running
// TabStack app over its control socket (~/Library/Application Support/TabStack/control.sock),
// launching TabStack first if needed.

setvbuf(stdout, nil, _IOLBF, 0)

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/TabStack/control.sock").path

let instructions = """
TabStack is a macOS sidebar that groups specific windows into workspaces (like browser tabs). \
Each tab is one window; switching a workspace shows its windows next to the sidebar and hides the rest. \
Typical setup for a project: create_workspace, then open_window for each window the project needs \
(e.g. VS Code with the project folder, Terminal at the folder, Chrome with the dev server and docs URLs, \
Finder at the folder). Use list_workspaces / list_windows first to reuse what already exists instead of \
opening duplicates; add_window adopts an already-open window. Workspaces and tabs can be referred to by \
name or by id. The sidebar shows only a few workspaces (current, pinned, then most used); pin a \
workspace to keep it visible.
"""

// MARK: Tools

func schema(_ props: [String: [String: Any]], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": props, "required": required, "additionalProperties": false]
}
let wsRef: [String: Any] = ["type": "string", "description": "Workspace name (case-insensitive, unique prefix ok) or id."]
let tabRef: [String: Any] = ["type": "string", "description": "Tab id, or the tab's name within `workspace`."]

let tools: [[String: Any]] = [
    ["name": "list_workspaces",
     "description": "List every workspace with its tabs (windows): names, ids, app, whether the window is open, and how TabStack would reopen it (folder / URLs / file). Also which workspace is current, shown in the sidebar, or pinned.",
     "annotations": ["readOnlyHint": true],
     "inputSchema": schema([:])],
    ["name": "list_windows",
     "description": "List windows currently open on this Mac, grouped by app, with their windowID and title and which workspaces already contain them. Use the windowID with add_window.",
     "annotations": ["readOnlyHint": true],
     "inputSchema": schema(["app": ["type": "string", "description": "Only apps whose name or bundle id contains this text."]])],
    ["name": "list_browser_profiles",
     "description": "List the profiles (accounts) of installed Chrome / Edge / Brave, for open_window's `profile`.",
     "annotations": ["readOnlyHint": true],
     "inputSchema": schema([:])],
    ["name": "create_workspace",
     "description": "Create a workspace.",
     "inputSchema": schema([
        "name": ["type": "string"],
        "color": ["type": "integer", "description": "Palette index 0-7: blue, purple, pink, orange, green, teal, indigo, red."],
        "pinned": ["type": "boolean", "description": "Always show it in the sidebar."],
        "switch": ["type": "boolean", "description": "Switch to it now (default false)."],
     ], required: ["name"])],
    ["name": "update_workspace",
     "description": "Rename, recolor, pin/unpin or reorder a workspace, or pick the Claude Code session its Claude tab switches to.",
     "inputSchema": schema([
        "workspace": wsRef,
        "name": ["type": "string"],
        "color": ["type": "integer", "description": "Palette index 0-7."],
        "pinned": ["type": "boolean"],
        "position": ["type": "integer", "description": "1-based position in the workspace list."],
        "claudeSession": ["type": "string", "description": "Claude desktop Code session id (local_…) the workspace's Claude tab shows; empty string picks the latest session in the project's folder."],
     ], required: ["workspace"])],
    ["name": "delete_workspace",
     "description": "Delete a workspace (only its tab list; windows and apps stay open). Cannot be undone.",
     "annotations": ["destructiveHint": true],
     "inputSchema": schema(["workspace": wsRef], required: ["workspace"])],
    ["name": "switch_workspace",
     "description": "Switch to a workspace (optionally to one of its tabs), showing its windows. With several displays each shows its own workspace; switching to one another display shows makes the two displays swap.",
     "inputSchema": schema(["workspace": wsRef, "tab": tabRef], required: ["workspace"])],
    ["name": "open_window",
     "description": "Open a NEW window and add it as a tab of a workspace, then switch there. Examples: {app:\"vscode\", path:\"~/projects/foo\"}; {app:\"terminal\", path:\"~/projects/foo\"} (new Terminal window in that folder); {app:\"finder\", path:\"~/projects/foo\"}; {app:\"chrome\", urls:[\"http://localhost:3000\", \"https://github.com/me/foo\"], profile:\"Work\"}. Without path/urls it opens a blank window (⌘N). If VS Code already has that folder open, that window is added instead.",
     "inputSchema": schema([
        "workspace": wsRef,
        "app": ["type": "string", "description": "vscode, cursor, chrome, edge, brave, safari, finder, terminal, iterm, an app name from /Applications, or a bundle id."],
        "path": ["type": "string", "description": "Folder or file to open (~ allowed)."],
        "urls": ["type": "array", "items": ["type": "string"], "description": "URLs for a browser window (one tab each)."],
        "profile": ["type": "string", "description": "Chrome/Edge/Brave profile name, email or directory (see list_browser_profiles)."],
        "name": ["type": "string", "description": "Tab label shown in the sidebar."],
        "switch": ["type": "boolean", "description": "Switch to the workspace and show the window (default true)."],
     ], required: ["workspace", "app"])],
    ["name": "add_window",
     "description": "Add an already-open window (windowID from list_windows) to a workspace.",
     "inputSchema": schema([
        "workspace": wsRef,
        "windowID": ["type": "integer"],
        "name": ["type": "string", "description": "Tab label."],
     ], required: ["workspace", "windowID"])],
    ["name": "update_tab",
     "description": "Rename a tab, move it to another workspace, change its position, or pair it with another tab of the same workspace so their two windows show side by side (this one left) on wide displays.",
     "inputSchema": schema([
        "tab": tabRef, "workspace": wsRef,
        "name": ["type": "string", "description": "New label; empty string shows the window title again."],
        "moveTo": ["type": "string", "description": "Destination workspace name or id."],
        "position": ["type": "integer", "description": "1-based position within its workspace."],
        "pairWith": ["type": "string", "description": "Tab (id or name, same workspace) to show to the right of this one on wide displays; empty string unpairs."],
     ], required: ["tab"])],
    ["name": "remove_tab",
     "description": "Remove a tab from its workspace; optionally also close the window.",
     "annotations": ["destructiveHint": true],
     "inputSchema": schema([
        "tab": tabRef, "workspace": wsRef,
        "closeWindow": ["type": "boolean", "description": "Also close the window (default false)."],
     ], required: ["tab"])],
    ["name": "restore_workspace",
     "description": "Reopen the workspace's windows that are missing (e.g. after a restart) from their saved folders / URLs / files.",
     "inputSchema": schema(["workspace": wsRef], required: ["workspace"])],
]

// MARK: Control socket

enum ClientError: Error { case message(String) }

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    if !ok { close(fd); return nil }
    return fd
}

/// Connects, launching TabStack if it is not running.
func connectOrLaunch() throws -> Int32 {
    if let fd = connectSocket() { return fd }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "com.guanshunpeng.TabStack"]
    try? p.run()
    p.waitUntilExit()
    for _ in 0..<50 {
        usleep(200_000)
        if let fd = connectSocket() { return fd }
    }
    throw ClientError.message("TabStack is not running and could not be started.")
}

var requestID = 0

func callTabStack(_ method: String, _ params: [String: Any]) throws -> Any {
    let fd = try connectOrLaunch()
    defer { close(fd) }
    requestID += 1
    var data = try JSONSerialization.data(withJSONObject: ["id": requestID, "method": method, "params": params])
    data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    while !buffer.contains(0x0A) {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { throw ClientError.message("TabStack closed the connection.") }
        buffer.append(contentsOf: chunk[0..<n])
    }
    let line = buffer.prefix { $0 != 0x0A }
    guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        throw ClientError.message("Unreadable reply from TabStack.")
    }
    if let error = reply["error"] as? String { throw ClientError.message(error) }
    return reply["result"] ?? NSNull()
}

// MARK: JSON-RPC over stdio

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

func pretty(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value) || value is [Any] || value is [String: Any],
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return "\(value)" }
    return text
}

func handle(_ msg: [String: Any]) {
    let id = msg["id"]
    guard let method = msg["method"] as? String else { return }
    let params = msg["params"] as? [String: Any] ?? [:]
    func reply(_ result: Any) { if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) } }
    func fail(_ code: Int, _ message: String) {
        if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
    }

    switch method {
    case "initialize":
        reply([
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "tabstack", "version": "0.1.0"],
            "instructions": instructions,
        ])
    case "ping":
        reply([:] as [String: Any])
    case "tools/list":
        reply(["tools": tools])
    case "tools/call":
        guard let name = params["name"] as? String, tools.contains(where: { $0["name"] as? String == name }) else {
            fail(-32602, "unknown tool"); return
        }
        let args = params["arguments"] as? [String: Any] ?? [:]
        do {
            let result = try callTabStack(name, args)
            reply(["content": [["type": "text", "text": pretty(result)]], "isError": false])
        } catch ClientError.message(let text) {
            reply(["content": [["type": "text", "text": text]], "isError": true])
        } catch {
            reply(["content": [["type": "text", "text": "\(error)"]], "isError": true])
        }
    default:
        if method.hasPrefix("notifications/") { return }
        fail(-32601, "method not found: \(method)")
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
    if let batch = obj as? [[String: Any]] { batch.forEach(handle) } else if let msg = obj as? [String: Any] { handle(msg) }
}
