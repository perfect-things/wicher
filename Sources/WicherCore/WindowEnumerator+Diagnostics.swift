import AppKit
import ApplicationServices

extension WindowEnumerator {
    // MARK: - Diagnostics

    /// A human-readable dump of what AX and CGWindowList each report, per app.
    ///
    /// Window enumeration on macOS is mostly undocumented behavior, and the
    /// interesting cases (a hidden app, a full-screen app on another Space) are
    /// exactly the ones that cannot be reproduced from a shell. This is how to
    /// see the ground truth on a real machine: Settings → General → Copy Diagnostics.
    ///
    /// Asks every regular app in turn, up to `backgroundTimeout` each, so it is
    /// built on the scan queue — one stuck app would otherwise beachball Settings.
    /// `completion` runs on the main thread.
    func diagnosticsReport(completion: @escaping @MainActor @Sendable (String) -> Void) {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let report = self.buildDiagnosticsReport()
            DispatchQueue.main.async { completion(report) }
        }
    }

    private func buildDiagnosticsReport() -> String {
        var out = ""
        out += "wicher diagnostics — \(Date())\n"
        out += "AXIsProcessTrusted: \(AXIsProcessTrusted())\n"
        out += "_AXUIElementGetWindow available: \(AXPrivate.isAvailable)\n"
        out += "CGSCopySpacesForWindows available: \(SpacesPrivate.isAvailable)\n"

        let facts = windowFacts()
        var byPID: [pid_t: [CGWindowFact]] = [:]
        for fact in facts { byPID[fact.pid, default: []].append(fact) }
        out += "CGWindowList(.optionAll) entries: \(facts.count), onscreen: \(facts.filter(\.isOnscreen).count)\n"

        lock.lock()
        let age = snapshot.map { Date().timeIntervalSince($0.takenAt) }
        let cachedTitles = caches.titles.count
        lock.unlock()
        out += "snapshot age: \(age.map { String(format: "%.2fs", $0) } ?? "none"), cached titles: \(cachedTitles)\n\n"

        // Regular apps, plus menu-bar apps that own something window-like —
        // their Settings windows are switch targets too.
        let apps = NSWorkspace.shared.runningApplications
            .filter { app in
                !app.isTerminated && (app.activationPolicy == .regular
                    || (app.activationPolicy == .accessory
                        && byPID[app.processIdentifier]?.contains(where: \.isPlausibleWindow) == true))
            }
        for app in apps {
            let pid = app.processIdentifier
            let started = Date()
            let scan = Self.scanApp(pid: pid, timeout: backgroundTimeout)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            out += "── \(app.localizedName ?? "?") pid=\(pid) hidden=\(app.isHidden) "
            out += "axWindows=\(scan.windows.count) answered=\(scan.answered) responded=\(scan.responded) [\(ms)ms]\n"
            for window in scan.windows {
                let fact = window.wid.flatMap { wid in facts.first { $0.id == wid } }
                out += "    AX wid=\(window.wid.map(String.init) ?? "-") min=\(window.minimized) "
                out += "layer=\(fact.map { String($0.layer) } ?? "-") on=\(fact.map { String($0.isOnscreen) } ?? "-") "
                out += "size=\(fact.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "-") "
                out += "title=\"\(window.title)\"\n"
            }
            let axIDs = Set(scan.windows.compactMap(\.wid))
            for fact in (byPID[pid] ?? []) where fact.layer == 0 && !axIDs.contains(fact.id) {
                out += "    CG-only wid=\(fact.id) on=\(fact.isOnscreen) "
                out += "origin=\(Int(fact.origin.x)),\(Int(fact.origin.y)) size=\(Int(fact.size.width))x\(Int(fact.size.height)) alpha=\(fact.alpha) "
                out += "plausible=\(fact.isPlausibleWindow) orderedOut=\(fact.isOrderedOut) inCurrentSpace=\(fact.isInCurrentSpace)\n"
            }
        }
        return out
    }
}
