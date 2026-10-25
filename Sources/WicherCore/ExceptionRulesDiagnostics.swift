import Foundation

extension ExceptionRules {
    /// For Copy Diagnostics: the rules, any the last launch dropped, and
    /// which current windows each one hides or demotes.
    @MainActor static func diagnosticsReport() -> String {
        let settings = Settings.shared
        let rules = ExceptionRules(settings.exceptionRules)
        var out = "\n── Exceptions: \(rules.rules.count) rule(s)"
        if settings.droppedExceptionRules > 0 {
            out += ", \(settings.droppedExceptionRules) unreadable rule(s) dropped at launch"
        }
        out += "\n"
        guard !rules.rules.isEmpty else { return out }
        let enumeration = WindowEnumerator.shared.enumerate()
        for rule in rules.rules {
            let target: String
            switch rule.target {
            case .app(let app): target = "app \(app.name) (\(app.bundleID ?? "no bundle id"))"
            case .titleContains(let text): target = "title contains \"\(text)\""
            case .titleIs(let text): target = "title is \"\(text)\""
            }
            out += "    \(target) → \(rule.action.rawValue)\n"
            for w in enumeration.windows + enumeration.appsWithoutWindows where rules.decidingRule(for: w) == rule {
                out += "        \(w.isAppOnly ? "app-only" : "window") \(w.appName): \"\(w.title)\"\n"
            }
        }
        return out
    }
}
