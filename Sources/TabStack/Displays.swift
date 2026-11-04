import Cocoa
import SwiftUI

/// Stable identity of a display (survives reboots and reconnecting), used to remember
/// which workspace each display shows.
typealias DisplayKey = String

/// The workspace a display shows and the tab selected there.
struct DisplayState: Codable, Equatable {
    var workspace: UUID
    var tab: UUID?
}

enum Displays {
    static func key(_ screen: NSScreen) -> DisplayKey {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return "main" }
        let id = CGDirectDisplayID(n.uint32Value)
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) {
            return text as String
        }
        return "display-\(id)"
    }

    /// Connected displays, primary (menu bar) first.
    static var keys: [DisplayKey] { NSScreen.screens.map(key) }

    static var primaryKey: DisplayKey { NSScreen.screens.first.map(key) ?? "main" }

    static func screen(_ key: DisplayKey) -> NSScreen? {
        NSScreen.screens.first { self.key($0) == key }
    }

    /// The display holding most of a window frame given in AX coordinates.
    static func key(containingAX rect: CGRect) -> DisplayKey? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        func overlap(_ s: NSScreen) -> CGFloat {
            let r = s.frame.intersection(cocoa)
            return r.isNull ? 0 : r.width * r.height
        }
        guard let best = NSScreen.screens.max(by: { overlap($0) < overlap($1) }), overlap(best) > 0
        else { return nil }
        return key(best)
    }
}

/// Which display a sidebar panel (and so its SwiftUI tree) belongs to.
private struct SidebarDisplayKey: EnvironmentKey {
    static let defaultValue: DisplayKey = ""
}

extension EnvironmentValues {
    var sidebarDisplay: DisplayKey {
        get { self[SidebarDisplayKey.self] }
        set { self[SidebarDisplayKey.self] = newValue }
    }
}
