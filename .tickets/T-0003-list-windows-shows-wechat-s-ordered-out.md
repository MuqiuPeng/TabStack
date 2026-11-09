---
id: T-0003
title: list_windows shows WeChat's ordered-out untitled window while hidden
status: done
priority: P3
type: bug
labels: [mcp, ax]
created: 2026-11-09T13:11+11:00
updated: 2026-11-09T15:28+11:00
created_by: local_0e206e36-02a1-480b-b5e7-98b8d377fd45
session: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
depends_on: []
files: [Sources/TabStack/AX.swift]
---

Found while fixing T-0002. With WeChat hidden, the remote-token lookup in `AX.windowsIncludingHidden` finds an untitled AXStandardWindow (e.g. 190764, 700×640) that belongs to no Space (`CGSCopySpacesForWindows` returns []); it's an ordered-out window, not something the user can see when WeChat is shown. It shows up in list_windows as an untitled entry, and adding it to a workspace would be useless.

Possible fix: drop remote-token results that are on no Space (check first that this doesn't hide real windows of apps on other Spaces or minimized windows).

- [x] With WeChat hidden, list_windows lists only the main window
- [x] Minimized windows and windows on other Spaces are still listed

## Log
- 2026-11-09 13:11 · local_0e206e36 · created
- 2026-11-09 15:26 · user · status → doing, session → local_b791c3a6-453c-446f-ac97-5ad082ad2dcc — claimed
- 2026-11-09 15:28 · user · checked: With WeChat hidden, list_windows lists only the main window
- 2026-11-09 15:28 · user · checked: Minimized windows and windows on other Spaces are still listed
- 2026-11-09 15:28 · user · Fixed: listedWindows drops windows that only the remote-token scan found and that are on no Space, unless minimized. Verified with WeChat hidden: list_windows shows only 190762 "Weixin". With Terminal hidden, a new minimized window was listed alongside all 10 existing ones. Windows on another Space keep a Space, so the filter doesn't touch them; not tested directly (no second Space set up).
- 2026-11-09 15:28 · user · status → done
