---
id: T-0001
title: "TicketDeck integration: workspace badge and tabstack:// deep link"
status: dropped
priority: P3
type: feature
labels: [ticketdeck]
created: 2026-11-09T11:49+11:00
updated: 2026-11-09T16:04+11:00
created_by: local_b791c3a6-453c-446f-ac97-5ad082ad2dcc
session:
depends_on: []
files: [Sources/TabStack/Views.swift, Sources/TabStack/ClaudeSessions.swift, Sources/TabStack/AppDelegate.swift]
---

Milestone M4 of TicketDeck (~/projects/TicketDeck/docs/DESIGN.md §9). Do it after TicketDeck's board (M2) exists.

## Acceptance
- [ ] Each workspace icon shows the count of doing + review tickets in its project folders (`ClaudeSessions.folders(of:)` → `<folder>/.tickets/*.md`), read-only, refreshed on file change
- [ ] `tabstack://open?folder=<path>&session=<local_…>` switches to the workspace holding that folder and points its Claude tab at the session
- [ ] Count and deep link both no-ops when a project has no .tickets/

## Log
- 2026-11-09 11:49 · local_b791c3a6 · created
- 2026-11-09 13:34 · user · Partly done (uncommitted): ⌃⌥T panel in TabStack lists the current workspace's tickets, jumps to the ticket's Claude session, marks done/todo and ticks checklist items, via `ticketdeck state`/`set`/`check`. Still open: sidebar badge and the tabstack:// deep link.
- 2026-11-09 16:04 · user · status → dropped — Not needed: the ⌃⌥T panel covers it; user decided against the badge and deep link.
