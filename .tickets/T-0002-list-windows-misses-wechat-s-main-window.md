---
id: T-0002
title: list_windows misses WeChat's main window while WeChat is hidden
status: done
priority: P3
type: bug
labels: [mcp, ax]
created: 2026-11-09T12:22+11:00
updated: 2026-11-09T15:26+11:00
created_by: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
session: local_0e206e36-02a1-480b-b5e7-98b8d377fd45
depends_on: []
files: [Sources/TabStack/AX.swift, Sources/TabStack/ControlServer.swift]
---

Left over from the hidden-window fix (session local_740d9c1b…, not yet committed), which added `AX.windowsIncludingHidden` for list_windows / add_window / remove_tab.

While WeChat is hidden, its main window (e.g. windowID 190762) is not in AXWindows and is not found by the remote-token lookup either, even scanning 20,000 element ids; only an untitled secondary window shows up. So list_windows can't show it, add_window can't adopt it, and remove_tab with closeWindow can't close it (now reported as `windowClosed: false`).

Related cost: because that window is in WindowServer's list but never found, every call spends the full 100 ms budget on WeChat. With several such hidden apps list_windows can approach a second.

Ideas: unhide briefly with the window off-screen or alpha 0 (avoid a visible flash); or fall back to the CGWindowList entry (id + title) for listing/adopting, and only need AX when acting on the window; or cache "known unfindable" window ids per pid so the 100 ms isn't paid on every call.

## Acceptance
- [x] With WeChat hidden, list_windows shows its main window with id and title
- [x] add_window can adopt it; remove_tab closeWindow either closes it or reports why not
- [x] list_windows doesn't spend the full search budget on the same unfindable window every call

## Log
- 2026-11-09 12:22 · local_b791c3a6 · created
- 2026-11-09 12:50 · local_5eafdf20 · Third acceptance item done (uncommitted, AX.swift): windowsIncludingHidden now keeps a per-pid scan cache (found elements, resumable scan, ids a full scan couldn't find). list_windows went from ~1s to 120–270ms with the same result. The WeChat main window is still not listed.
- 2026-11-09 13:07 · local_0e206e36 · status → doing, session → local_0e206e36-02a1-480b-b5e7-98b8d377fd45 — claimed
- 2026-11-09 13:11 · local_0e206e36 · status → review — Fixed (uncommitted): while hidden, WeChat drops the main window's AX element entirely (remote-token scan of 200k ids finds only the ordered-out 190764). New AX.listedWindows(of:) adds, for hidden apps, WindowServer windows AX misses that are still on a Space (CGSCopySpacesForWindows; ordered-out ones are on none). Title: kCGWindowName → stored tab title → app name (TabStack lacks Screen Recording). Verified with WeChat hidden: list_windows shows 190762 "Weixin"; add_window into TicketDeck worked (test tab removed); WeChat stayed hidden. remove_tab closeWindow still can't close an AX-less window and reports windowClosed:false.
- 2026-11-09 15:26 · user · checked: With WeChat hidden, list_windows shows its main window with id and title
- 2026-11-09 15:26 · user · checked: add_window can adopt it; remove_tab closeWindow either closes it or reports why not
- 2026-11-09 15:26 · user · checked: list_windows doesn't spend the full search budget on the same unfindable window every call
- 2026-11-09 15:26 · user · Verified at close: with WeChat hidden, list_windows lists 190762 "Weixin" (3f87820). add_window adopted it in the fix session; remove_tab closeWindow reports windowClosed:false for it (no AX element). The untitled 190764 still listed is T-0003.
- 2026-11-09 15:26 · user · status → done
