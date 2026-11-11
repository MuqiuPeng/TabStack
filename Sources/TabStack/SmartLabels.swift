import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Short sidebar labels for long window titles ("refactor(security): extract auth … · Pull
/// Request #55 · … - Google Chrome – Robin" → "安全中间件重构"), made by the on-device model
/// (macOS 26+, Apple Intelligence on). Labels are made in the background, one at a time, and
/// kept per title; until one is ready, or without the model, the title minus its noise shows.
/// Used from the main thread only; the model runs in a task whose result comes back there.
final class SmartLabels: @unchecked Sendable {
    static let enabledKey = "smartLabels"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Whether this Mac can make labels at all.
    static var available: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return SystemLanguageModel.default.isAvailable }
        #endif
        return false
    }

    /// Called on the main thread when a new label is ready.
    var onChange: (() -> Void)?

    private static let cacheKey = "smartLabelCache"
    private static let cacheLimit = 400
    /// Cleaned title → label, oldest first (for trimming).
    private var cache: [String: String]
    private var order: [String]
    private var queue: [String] = []
    private var working = false

    init() {
        let saved = UserDefaults.standard.array(forKey: Self.cacheKey) as? [[String]] ?? []
        cache = Dictionary(saved.filter { $0.count == 2 }.map { ($0[0], $0[1]) }) { a, _ in a }
        order = saved.compactMap(\.first)
    }

    /// The label to show for a window title.
    func label(for title: String) -> String {
        let clean = Self.clean(title)
        guard Self.width(clean) > Self.shortEnough, Self.enabled else { return clean }
        if let label = cache[clean] { return label }
        if Self.available, !queue.contains(clean) {
            queue.append(clean)
            next()
        }
        return clean
    }

    /// About what fits under a sidebar icon (50 pt at 8.5 pt type), in `width` units.
    private static let shortEnough = 9

    /// Display width: a CJK character counts as two letters.
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + (isCJK($1) ? 2 : 1) }
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x2E80...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
            || (0xF900...0xFAFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value)
    }

    /// Whether the model's answer can stand for the title: there, and shorter.
    private static func usable(_ label: String, for title: String) -> Bool {
        !label.isEmpty && width(label) < width(title)
    }

    /// A title without what says nothing about the window: the browser and profile name,
    /// an unread count, a terminal's size.
    static func clean(_ title: String) -> String {
        var t = title
        for pattern in [
            #" [-–—] (Google Chrome|Microsoft Edge|Brave|Safari|Arc)( [-–—] .*)?$"#,
            // What Chrome appends about the tab, not the page.
            #" - (High memory usage - [\d.]+ [KMG]B|Audio playing|Muted|Camera recording|Microphone recording|Camera and microphone recording|Bluetooth device connected|Pinned)"#,
            #" — \d+×\d+$"#,
            #"^\(\d+\) "#,
        ] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private func next() {
        guard !working, let title = queue.first else { return }
        working = true
        Task { [weak self] in
            let label = await SmartLabels.make(title)
            DispatchQueue.main.async {
                guard let self else { return }
                self.queue.removeFirst()
                self.working = false
                // A failed or useless answer is kept too (as the title), so it is not retried.
                self.store(title, label.flatMap { Self.usable($0, for: title) ? $0 : nil } ?? title)
                self.onChange?()
                self.next()
            }
        }
    }

    private func store(_ title: String, _ label: String) {
        if cache[title] == nil { order.append(title) }
        cache[title] = label
        if order.count > Self.cacheLimit {
            for old in order.prefix(order.count - Self.cacheLimit) { cache[old] = nil }
            order.removeFirst(order.count - Self.cacheLimit)
        }
        UserDefaults.standard.set(order.compactMap { t in cache[t].map { [t, $0] } }, forKey: Self.cacheKey)
    }

    private static func make(_ title: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let session = LanguageModelSession(instructions: """
                给侧边栏里的窗口起一个很短的名字，让人一眼看出这个窗口是干什么的。
                规则：用简体中文，最多 4 个汉字；网站名、项目名、产品名太长时可以直接用它\
                （最多 8 个英文字母）；不要加引号和标点。
                例子：
                Pull Request #55 · dosshpay/dosshpay-platform-api → PR 55
                添加客服账号 - 文档 - 企业微信开发者中心 → 企微客服
                Inbox - someone@gmail.com - Gmail → Gmail
                2026-07-03-作品展示门户-工作汇报.md — Career → 工作汇报
                Sunbridge Energy: People | LinkedIn → LinkedIn
                """)
            do {
                let response = try await session.respond(to: "窗口标题：\(title)", generating: ShortLabel.self)
                return response.content.label.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            } catch {
                debugLog("smart label failed for \(title): \(error)")
                return nil
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
private struct ShortLabel {
    @Guide(description: "窗口的短名字：最多 4 个汉字，或不超过 8 个字母的名字")
    var label: String
}
#endif
