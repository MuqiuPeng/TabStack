import Carbon

/// System-wide hotkeys (Carbon is still the only public API for them):
///   ⌥⌘1 … ⌥⌘9   switch to app 1–9 of the current workspace
///   ⌃⌥1 … ⌃⌥9   switch to workspace 1–9
///   ⌥⌘0         show / hide the sidebar
///   ⌃⌥↑ / ⌃⌥↓   previous / next app in the current workspace
///   ⌃⌥← / ⌃⌥→   previous / next workspace
/// ⌘1–9 alone is avoided because browsers and editors use it for their own tabs, and
/// ⌘-arrows because they are the system-wide text navigation keys.
enum HotKeys {
    enum Action {
        case tab(Int)
        case workspace(Int)
        case toggleSidebar
        case cycleTab(Int)
        case cycleWorkspace(Int)
    }

    static var handler: ((Action) -> Void)?
    private static var refs: [EventHotKeyRef?] = []

    private static let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                                 kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    // Hotkey ids: 1–9 tabs, 101–109 workspaces, 200 toggle, 301–304 arrows.
    private static func action(for id: UInt32) -> Action? {
        switch id {
        case 1...9: return .tab(Int(id) - 1)
        case 101...109: return .workspace(Int(id) - 101)
        case 200: return .toggleSidebar
        case 301: return .cycleTab(-1)
        case 302: return .cycleTab(1)
        case 303: return .cycleWorkspace(-1)
        case 304: return .cycleWorkspace(1)
        default: return nil
        }
    }

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if let action = HotKeys.action(for: id.id) { HotKeys.handler?(action) }
            return noErr
        }, 1, &spec, nil, nil)

        for (i, key) in digits.enumerated() {
            add(key: key, modifiers: cmdKey | optionKey, id: UInt32(i + 1))
            add(key: key, modifiers: controlKey | optionKey, id: UInt32(i + 101))
        }
        add(key: kVK_ANSI_0, modifiers: cmdKey | optionKey, id: 200)

        let arrows = controlKey | optionKey
        add(key: kVK_UpArrow, modifiers: arrows, id: 301)
        add(key: kVK_DownArrow, modifiers: arrows, id: 302)
        add(key: kVK_LeftArrow, modifiers: arrows, id: 303)
        add(key: kVK_RightArrow, modifiers: arrows, id: 304)
    }

    private static func add(key: Int, modifiers: Int, id: UInt32) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5442_5354), id: id) // 'TBST'
        RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
