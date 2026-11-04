# TabStack

> 中文说明见 [README.zh-CN.md](README.zh-CN.md)

A sidebar docked to the left edge of your screen that groups windows into
**workspaces** and switches between them with one click — like vertical browser
tabs, but for every app. Each tab is one window, so a single Chrome can occupy
several tabs, each with its own title.

## How it works

macOS does not let one app host another app's windows, so TabStack drives them
from the outside instead of reparenting them:

- The sidebar is a floating panel pinned to the left of the main display. It
  shows on every Space and clicking it does not steal focus.
- Switching tabs uses the Accessibility API (`AXUIElement`) to resize that
  tab's window to fill what is left of the screen — menu bar, Dock and sidebar
  subtracted — and raise it, while hiding the other apps in the workspace.
- Switching workspaces hides the previous workspace's apps, then restores
  whichever tab that workspace had selected last.

## Requirements

macOS 13 or later. Apple silicon and Intel.

## Install

### Build from source (recommended for now)

```bash
./build.sh
open build/TabStack.app
```

Grant TabStack access under **System Settings → Privacy & Security →
Accessibility** on first launch — without it, it cannot move or hide windows.

The build is ad-hoc signed by default, and because the Accessibility grant is
tied to the code signature, you may have to re-grant it after every rebuild.
Point `SIGN_IDENTITY` at a stable certificate to avoid that:

```bash
SIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
```

### From a release

Releases carry `TabStack-<version>.zip`. **The app is not notarised by Apple**,
so Gatekeeper will refuse to open it on the first try. Unzip it, drag
`TabStack.app` into `/Applications`, then either right-click it and choose
**Open** (and confirm), or clear the quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/TabStack.app
```

Then grant Accessibility access as above. Notarisation requires a paid Apple
Developer account and is not set up yet.

TabStack shows no Dock icon and no menu bar; quit from the workspace menu at
the top of the sidebar.

## Usage

| Action | How |
|---|---|
| Switch tab | Click an icon in the sidebar, or `⌥⌘1`…`⌥⌘9` |
| Switch workspace | Click the workspace icon at the top to expand all of them, or use the gear menu at the bottom, or `⌃⌥1`…`⌃⌥9` (those shown in the sidebar) |
| Search workspaces | `⌃⌥F` — type a name or window title, `↑↓` to select, `↩` to open. With no query it lists by recommendation, collapsed workspaces included |
| Close window | `⌃⌥D` — closes the current window, removes it from the list and moves to the neighbouring one |
| Previous / next tab | `⌃⌥↑` / `⌃⌥↓` (cycles within the workspace) |
| Previous / next workspace | `⌃⌥←` / `⌃⌥→` (cycles) |
| Show / hide sidebar | `⌥⌘0` (the current app fills the screen once hidden) |
| Add a window | Click `＋`. **New window** opens one for Finder (with Go to Folder), Terminal, iTerm, Safari, Chrome / Edge / Brave (pick a profile); **Open windows** lists what is already running, grouped by app; or pick an app from /Applications |
| Reorder | Drag an icon up or down in the sidebar |
| Manage workspaces | The Workspace Settings window (workspace menu, or menu bar icon → Workspace Settings…, `⌘,`): drag to reorder workspaces and windows, rename, pick a colour, move windows between workspaces, add or remove them |
| Manage tabs | Right-click an icon: rename, bind to the current window, move up or down, quit the app, remove from the workspace |

Other behaviour:

- Switching to an app with ⌘Tab or the Dock syncs the sidebar highlight and
  fills the content area with that window.
- Switching by keyboard briefly shows the app or workspace you landed on in the
  middle of the screen.
- The sidebar hides itself while an app is full-screen and comes back on the
  desktop.
- Dock unread badges are mirrored in the sidebar.
- Workspaces and tabs are saved automatically, and quitting TabStack unhides
  every app it had hidden.
- When one app holds several tabs, each icon carries its window title (or the
  name you gave it).
- **Restore after a reboot**: TabStack remembers how to reopen each window —
  VS Code and Cursor by project folder, Chrome / Edge / Brave by every tab URL
  in the window (needs permission to control the browser once), document
  windows by file. After a restart it first re-adopts the windows the apps
  restored themselves and reopens only what is genuinely missing: click a tab
  for one window, or switch workspace to restore the whole group (switchable
  off in settings), or use **Restore this workspace's windows**.
- One window can belong to several workspaces at once.
- **Only frequently used workspaces are shown**: five by default (configurable),
  made up of the current one, pinned ones, and the highest-scoring rest.
  Recommendation is frecency-based — one point per switch and one per ten
  minutes of use, halved every three days. The others are collapsed, never
  deleted; reach them with `⌃⌥F` or **Other workspaces** in the workspace menu.
- **Two windows in one tab** on wide displays: right-click a tab → **Show side
  by side with…** pairs it with another tab of the workspace. On a display at
  least 2400 points wide (configurable in settings) the pair fills the content
  area half and half; on narrower ones only the half you last used is shown.
  Pairing is optional — other tabs keep the whole area.
- **Claude sessions follow the workspace**: the Claude desktop window can be a
  tab in several workspaces. Whenever it is shown, Claude switches to that
  workspace's Claude Code session — by default the latest one working in the
  project's folder, or one you pick (right-click the tab → **Claude 会话**).
  Uses Claude's `claude://code/continue` link; turn it off in settings.
- **Several displays**: each display gets its own sidebar and shows its own
  workspace; two displays never show the same one. Hotkeys and menus act on the
  display you last clicked or worked in. Switching to a workspace another
  display is showing swaps the two: each display's windows move to the other.
  Unplugging a display hides its workspace; plugging it back brings it back.
  Desktops (Spaces) still share one workspace — macOS does not let apps move
  other apps' windows between Spaces.

## Let an AI set up your workspaces (MCP)

`build/TabStack.app/Contents/MacOS/tabstack-mcp` is an MCP server (stdio) that
lets Claude Code and other assistants build a workspace for a project directly.
It drives the running TabStack over a local control socket
(`~/Library/Application Support/TabStack/control.sock`, readable and writable by
your user only) and launches TabStack if it is not running.

Register it in Claude Code, for every project:

```bash
claude mcp add --scope user tabstack -- ~/projects/TabStack/build/TabStack.app/Contents/MacOS/tabstack-mcp
```

| Tool | What it does |
|---|---|
| `list_workspaces` | Every workspace and its windows: open or not, how to restore each (folder / URLs / file), shown in the sidebar, pinned |
| `list_windows` | Currently open windows, grouped by app, with window IDs and which workspaces hold them |
| `list_browser_profiles` | Chrome / Edge / Brave profiles |
| `create_workspace` / `update_workspace` / `delete_workspace` | Create, rename, recolour, pin, reorder, delete |
| `switch_workspace` | Switch workspace, optionally to a given window |
| `open_window` | Open a new window and add it: VS Code / Cursor on a folder, a terminal in a directory, Finder on a folder, a browser opening a set of URLs with a chosen profile |
| `add_window` | Add an already-open window to a workspace |
| `update_tab` / `remove_tab` | Rename, move to another workspace, reorder; remove (optionally closing the window) |
| `restore_workspace` | Reopen the windows a workspace is missing |

So you can just say: "Make a workspace for ~/projects/foo — VS Code on the
project, a terminal in that directory, and Chrome on localhost:3000 and the
GitHub repo using my Work profile."

## Known limitations

- All desktops (Spaces) of a display share its workspace.
- Other windows of the same app cannot be hidden individually, so they stack
  behind the current one when you switch.
- Window identification relies on the private API `_AXUIElementGetWindow`.
- Fixed-size windows are centred in the content area instead of filled.
- The sidebar floats above normal windows, so a maximised window that is not
  part of the workspace will not cover it.
- Controlling other apps rules out sandboxing, so TabStack cannot ship on the
  Mac App Store.

## License

MIT — see [LICENSE](LICENSE).
