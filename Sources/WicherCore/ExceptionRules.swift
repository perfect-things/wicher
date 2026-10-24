import Foundation

/// An app as a rule names it: by bundle ID when it has one, else by name.
/// The name is kept either way, to show apps that aren't installed.
struct AppRef: Codable, Hashable, Sendable {
    var bundleID: String?
    var name: String

    /// Identity in lists and sets: the bundle ID, else the name.
    var key: String { bundleID ?? name }

    /// Bundle IDs are what LaunchServices goes by; the name only stands in
    /// for apps without one, and is compared ignoring case.
    func matches(_ window: WindowInfo) -> Bool {
        if let bundleID { return window.bundleID == bundleID }
        return window.appName.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// One exception (Settings → Exceptions): one target, one action. Rules are
/// global and only ever hide or demote — see `ExceptionRules`.
struct ExceptionRule: Identifiable, Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case app(AppRef)
        case titleContains(String)
        case titleIs(String)

        var isApp: Bool {
            if case .app = self { return true }
            return false
        }
    }

    enum Action: String, Codable, CaseIterable, Sendable {
        case hide
        /// Hides only the app's "No Windows" entry.
        case hideIfNoWindows
        case bottom

        var title: String {
            switch self {
            case .hide: return "Hide"
            case .hideIfNoWindows: return "Hide if no windows"
            case .bottom: return "Show at bottom"
            }
        }

        /// A title rule can't match an app without windows.
        static func allowed(for target: Target) -> [Action] {
            target.isApp ? allCases : [.hide, .bottom]
        }
    }

    var id: UUID
    var target: Target
    var action: Action

    init(id: UUID = UUID(), target: Target, action: Action) {
        self.id = id
        self.target = target
        self.action = action
    }

    /// The action fits the target and a title rule has text — an empty one
    /// would match every window.
    var isValid: Bool {
        guard Action.allowed(for: target).contains(action) else { return false }
        switch target {
        case .app(let app): return !(app.bundleID ?? app.name).isEmpty
        case .titleContains(let text), .titleIs(let text): return !text.trimmed.isEmpty
        }
    }

    func matches(_ window: WindowInfo) -> Bool {
        switch target {
        case .app(let app):
            guard app.matches(window) else { return false }
            return action != .hideIfNoWindows || window.isAppOnly
        case .titleContains(let text):
            return !window.isAppOnly && window.title.range(of: text.trimmed, options: .caseInsensitive) != nil
        case .titleIs(let text):
            return !window.isAppOnly && window.title.trimmed.caseInsensitiveCompare(text.trimmed) == .orderedSame
        }
    }
}

/// The JSON form, also the future export/dotfile format:
/// `{ "id": …, "app": { "bundleID": …, "name": … } | "titleContains": … | "titleIs": …, "action": … }`.
extension ExceptionRule: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, app, titleContains, titleIs, action
    }

    struct Invalid: Error {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        action = try c.decode(Action.self, forKey: .action)
        if let app = try c.decodeIfPresent(AppRef.self, forKey: .app) {
            target = .app(app)
        } else if let text = try c.decodeIfPresent(String.self, forKey: .titleContains) {
            target = .titleContains(text)
        } else if let text = try c.decodeIfPresent(String.self, forKey: .titleIs) {
            target = .titleIs(text)
        } else {
            throw Invalid()
        }
        guard isValid else { throw Invalid() }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch target {
        case .app(let app): try c.encode(app, forKey: .app)
        case .titleContains(let text): try c.encode(text, forKey: .titleContains)
        case .titleIs(let text): try c.encode(text, forKey: .titleIs)
        }
        try c.encode(action, forKey: .action)
    }
}

/// The stored list: `{ "version": 1, "rules": [...] }`. A rule that doesn't
/// decode (unknown target or action, an action that doesn't fit its target,
/// empty title) is dropped and counted, rather than failing the whole list.
struct ExceptionRuleFile: Codable {
    static let currentVersion = 1

    var version = currentVersion
    var rules: [ExceptionRule]
    /// Not stored: how many rules the last decode dropped.
    var dropped = 0

    private enum CodingKeys: String, CodingKey { case version, rules }

    init(rules: [ExceptionRule]) { self.rules = rules }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        var list = try c.nestedUnkeyedContainer(forKey: .rules)
        rules = []
        while !list.isAtEnd {
            if let rule = try? list.decode(ExceptionRule.self) {
                rules.append(rule)
            } else {
                _ = try? list.decode(Skip.self)
                dropped += 1
            }
        }
    }

    /// Consumes one element of any shape, so decoding moves past a bad rule.
    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// What the rules do to the switcher's entries. Pure, applied by
/// `WindowGrouping` after the switcher's own scope and placements, so a
/// switcher that hides a window always wins: rules only hide or demote.
struct ExceptionRules: Sendable {
    enum Outcome: Sendable {
        case hide, bottom
    }

    static let none = ExceptionRules([])

    let rules: [ExceptionRule]

    init(_ rules: [ExceptionRule]) {
        self.rules = rules.filter(\.isValid)
    }

    /// The rule that decides `window`: a hiding one over one that demotes.
    func decidingRule(for window: WindowInfo) -> ExceptionRule? {
        var demoting: ExceptionRule?
        for rule in rules where rule.matches(window) {
            if rule.action != .bottom { return rule }
            if demoting == nil { demoting = rule }
        }
        return demoting
    }

    func outcome(for window: WindowInfo) -> Outcome? {
        decidingRule(for: window).map { $0.action == .bottom ? .bottom : .hide }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
