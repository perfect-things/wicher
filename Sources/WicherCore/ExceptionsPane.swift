import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Settings → Exceptions: one box of app rules, one of title rules, each with
// an action pop-up and a remove button. Apps are added from `AppPickerSheet`,
// titles from a form row that "Add Title…" opens at the bottom of their box.

struct ExceptionsPane: View {
    @Bindable private var settings = Settings.shared
    @State private var pickingApp = false
    @State private var addingTitle = false

    private var appRules: [ExceptionRule] { settings.exceptionRules.filter(\.target.isApp) }
    private var titleRules: [ExceptionRule] { settings.exceptionRules.filter { !$0.target.isApp } }

    var body: some View {
        Form {
            Section {
                ForEach(appRules) { ExceptionRow(rule: $settings[exceptionID: $0.id]) }
                if appRules.isEmpty { placeholder("No app exceptions") }
            } header: {
                Text("Apps")
            } footer: {
                Button { pickingApp = true } label: { Label("Add App…", systemImage: "plus") }
                    .padding(.top, 8)
            }

            Section {
                ForEach(titleRules) { ExceptionRow(rule: $settings[exceptionID: $0.id]) }
                if titleRules.isEmpty && !addingTitle { placeholder("No window title exceptions") }
                if addingTitle { TitleRuleForm(isPresented: $addingTitle) }
            } header: {
                Text("Window titles")
            } footer: {
                if !addingTitle {
                    Button { addingTitle = true } label: { Label("Add Title…", systemImage: "plus") }
                        .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.top, -5, for: .scrollContent)
        .sheet(isPresented: $pickingApp) {
            AppPickerSheet(existing: Set(appRules.compactMap { rule in
                if case .app(let app) = rule.target { return app.key }
                return nil
            })) { app in
                // Return can reach both the search field and the Add button.
                guard !settings.exceptionRules.contains(where: { $0.target == .app(app) }) else { return }
                settings.exceptionRules.append(ExceptionRule(target: .app(app), action: .hide))
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }
}

/// One saved rule: what it matches, its action, and a remove button. The
/// target is read-only; to change it, remove the rule and add it again.
private struct ExceptionRow: View {
    @Binding var rule: ExceptionRule

    var body: some View {
        HStack(spacing: 10) {
            ExceptionTargetIcon(target: rule.target)
            label
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            ActionPicker(target: rule.target, selection: $rule.action, name: name)
            Button { Settings.shared.exceptionRules.removeAll { $0.id == rule.id } } label: {
                Label("Remove Exception for \(name)", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Remove Exception")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var label: some View {
        switch rule.target {
        case .app(let app):
            Text(app.name)
        case .titleContains(let text):
            Text("\(Text("contains").foregroundStyle(.secondary)) “\(text)”")
        case .titleIs(let text):
            Text("\(Text("is").foregroundStyle(.secondary)) “\(text)”")
        }
    }

    /// For VoiceOver: "Action for Finder", "Action for title contains Noname".
    private var name: String {
        switch rule.target {
        case .app(let app): return app.name
        case .titleContains(let text): return "title contains \(text)"
        case .titleIs(let text): return "title is \(text)"
        }
    }
}

private struct ActionPicker: View {
    let target: ExceptionRule.Target
    @Binding var selection: ExceptionRule.Action
    let name: String

    var body: some View {
        Picker("Action for \(name)", selection: $selection) {
            ForEach(ExceptionRule.Action.allowed(for: target), id: \.self) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        .frame(width: ActionPicker.width, alignment: .trailing)
    }

    /// Wide enough for the longest action, so the pop-ups line up.
    static let width: CGFloat = 160
}

/// The app's icon, or a "T" tile for a title rule.
private struct ExceptionTargetIcon: View {
    let target: ExceptionRule.Target

    var body: some View {
        Group {
            if case .app(let app) = target {
                Image(nsImage: AppIcons.icon(for: app))
                    .resizable()
            } else {
                Text("T")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

/// The row "Add Title…" opens: laid out like a saved title rule, with the
/// text field focused, ending in a trash (cancel) and a tick (add) button.
/// Return adds (not while the text is empty); Esc, or focus leaving the row
/// while the text is empty, closes it. Focus moving
/// to the row's own pop-ups (Shift-Tab to "Is") keeps it open.
private struct TitleRuleForm: View {
    @Binding var isPresented: Bool
    @State private var exact = false
    @State private var text = ""
    @State private var action = ExceptionRule.Action.hide
    @FocusState private var focus: Control?

    private enum Control { case match, text, action, cancel, add }

    private var target: ExceptionRule.Target {
        exact ? .titleIs(text.trimmed) : .titleContains(text.trimmed)
    }

    var body: some View {
        HStack(spacing: 10) {
            ExceptionTargetIcon(target: target)
            Picker("Match", selection: $exact) {
                Text("Contains").tag(false)
                Text("Is").tag(true)
            }
            .labelsHidden()
            .fixedSize()
            .focused($focus, equals: .match)
            TextField("Window title", text: $text, prompt: Text("Text to match…"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: .infinity)
                .layoutPriority(1)
                .focused($focus, equals: .text)
                .onSubmit(add)
            ActionPicker(target: target, selection: $action, name: "new title rule")
                .focused($focus, equals: .action)
            Button { isPresented = false } label: {
                Label("Cancel", systemImage: "trash").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focused($focus, equals: .cancel)
            .help("Cancel")
            Button(action: add) {
                Label("Add Exception", systemImage: "checkmark").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .focused($focus, equals: .add)
            .disabled(text.trimmed.isEmpty)
            .help("Add Exception")
        }
        .padding(.vertical, 2)
        .onExitCommand { isPresented = false }
        // After a beat: the "Add Title…" button that had focus goes away as
        // this row appears, and AppKit hands focus to the pane's first control
        // after an `onAppear` request. The first control here is the pop-up,
        // which only takes focus with Keyboard Navigation on — else the field
        // (asking for a control that can't take focus would read as focus
        // leaving the row, which closes it).
        .task {
            try? await Task.sleep(for: .milliseconds(50))
            focus = NSApp.isFullKeyboardAccessEnabled ? .match : .text
        }
        .onChange(of: focus) { _, now in
            if now == nil && text.trimmed.isEmpty { isPresented = false }
        }
    }

    private func add() {
        guard !text.trimmed.isEmpty else { return }
        Settings.shared.exceptionRules.append(ExceptionRule(target: target, action: action))
        isPresented = false
    }
}

// MARK: - App picker

/// One app the picker offers.
struct AppChoice: Identifiable, Hashable, Sendable {
    let app: AppRef
    var id: String { app.key }
}

/// "Add App": a search field over the apps running now, the ones wicher has
/// listed before, and the installed ones — each app once, in the first
/// section that has it. Arrows move the selection from the search field,
/// Return adds, Esc cancels. Apps that already have a rule can't be picked.
private struct AppPickerSheet: View {
    let existing: Set<String>
    let onAdd: (AppRef) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @State private var running: [AppChoice] = []
    @State private var installed: [AppChoice] = []
    @State private var choosingFile = false
    @FocusState private var searchFocused: Bool

    private var sections: [(title: String, apps: [AppChoice])] {
        var seenKeys = Set<String>()
        func unique(_ apps: [AppChoice]) -> [AppChoice] {
            apps.filter { seenKeys.insert($0.id).inserted && matches($0) }
        }
        let seen = Settings.shared.seenApps.map { AppChoice(app: $0) }
        return [("Running Now", unique(running)), ("Seen by Wicher", unique(seen)), ("Installed", unique(installed))]
            .filter { !$0.apps.isEmpty }
    }

    private var selectable: [String] {
        sections.flatMap(\.apps).map(\.id).filter { !existing.contains($0) }
    }

    private func matches(_ choice: AppChoice) -> Bool {
        let q = query.trimmed
        guard !q.isEmpty else { return true }
        return choice.app.name.localizedCaseInsensitiveContains(q)
            || choice.app.bundleID?.localizedCaseInsensitiveContains(q) == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add App").font(.headline)
            searchField
            appList
            HStack {
                Button("Choose Other App…") { choosingFile = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedApp == nil)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            searchFocused = true
            running = AppCatalog.running()
            selection = selectable.first
        }
        .task { installed = await AppCatalog.installed() }
        .onChange(of: query) { selection = selectable.first }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.application]) { result in
            guard case .success(let url) = result, let app = AppCatalog.app(at: url),
                  !existing.contains(app.key) else { return }
            onAdd(app)
            dismiss()
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications"))
    }

    /// A capsule of glass, like the system's search fields. Arrows move the
    /// list's selection without leaving it; Return adds.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $query, prompt: Text("Search"))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onSubmit(add)
            if !query.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassEffect(.regular, in: .capsule)
    }

    /// A ScrollView rather than a `List`: a List in a sheet drew no box of
    /// its own and its scroller ignored the system setting. Corners are
    /// concentric: row radius = box radius − inset.
    private var appList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(sections, id: \.title) { section in
                        Section {
                            ForEach(section.apps) { choice in
                                AppChoiceRow(choice: choice, isAdded: existing.contains(choice.id),
                                             isSelected: selection == choice.id,
                                             cornerRadius: Self.listRadius - Self.listInset)
                                    .onTapGesture(count: 2) { selection = choice.id; add() }
                                    .onTapGesture { if !existing.contains(choice.id) { selection = choice.id } }
                            }
                        } header: {
                            Text(section.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Self.listBackground)
                        }
                    }
                }
                .padding(Self.listInset)
            }
            .onChange(of: selection) { _, id in
                if let id { withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo(id) } }
            }
        }
        .frame(height: 300)
        .background(Self.listBackground, in: RoundedRectangle(cornerRadius: Self.listRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Self.listRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.listRadius, style: .continuous)
            .strokeBorder(.separator))
    }

    /// What native lists and tables sit on; the pinned headers match it.
    private static let listBackground = Color(nsColor: .controlBackgroundColor)
    private static let listRadius: CGFloat = 12
    private static let listInset: CGFloat = 5

    private var selectedApp: AppRef? {
        guard let selection, !existing.contains(selection) else { return nil }
        return sections.lazy.flatMap(\.apps).first { $0.id == selection }?.app
    }

    private func move(_ step: Int) {
        let ids = selectable
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) }.map { $0 + step } ?? (step > 0 ? 0 : ids.count - 1)
        selection = ids[i.clamped(to: 0...(ids.count - 1))]
    }

    private func add() {
        guard let app = selectedApp else { return }
        onAdd(app)
        dismiss()
    }
}

private struct AppChoiceRow: View {
    let choice: AppChoice
    let isAdded: Bool
    let isSelected: Bool
    let cornerRadius: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: AppIcons.icon(for: choice.app))
                .resizable()
                .frame(width: 20, height: 20)
            Text(choice.app.name)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(isAdded ? "Already added" : choice.app.bundleID ?? "")
                .font(isAdded ? .callout : .callout.monospaced())
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(isSelected ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .opacity(isAdded ? 0.5 : 1)
        .id(choice.id)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Where the picker's apps come from.
enum AppCatalog {
    /// Running apps with a Dock icon, A–Z. Menu-bar apps and the ~150
    /// background agents are left out — the ones that ever had a row
    /// (loginwindow…) are under "Seen by Wicher". A few LaunchServices
    /// reads per process: done once, when the picker opens.
    @MainActor static func running() -> [AppChoice] {
        var byKey: [String: AppChoice] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, !name.isEmpty else { continue }
            let ref = AppRef(bundleID: app.bundleIdentifier, name: name)
            byKey[ref.key] = AppChoice(app: ref)
        }
        return byKey.values.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }

    static let searchedFolders: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// The `.app`s directly in `searchedFolders`, A–Z, read off the main thread.
    static func installed() async -> [AppChoice] {
        await Task.detached(priority: .userInitiated) {
            var byKey: [String: AppChoice] = [:]
            for folder in searchedFolders {
                let urls = (try? FileManager.default.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                for url in urls where url.pathExtension == "app" {
                    if let app = app(at: url) { byKey[app.key] = AppChoice(app: app) }
                }
            }
            return byKey.values.sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
        }.value
    }

    static func app(at url: URL) -> AppRef? {
        guard let bundle = Bundle(url: url) else { return nil }
        // Some apps ship an empty display name.
        let name = ["CFBundleDisplayName", "CFBundleName"]
            .lazy.compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .first { !$0.trimmed.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
        return AppRef(bundleID: bundle.bundleIdentifier, name: name)
    }
}

/// App icons by bundle ID (else by running app name), cached. Apps that
/// aren't installed or running get the generic app icon.
@MainActor
enum AppIcons {
    private static var cache: [String: NSImage] = [:]

    static func icon(for app: AppRef) -> NSImage {
        if let icon = cache[app.key] { return icon }
        let icon = lookUp(app) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        cache[app.key] = icon
        return icon
    }

    private static func lookUp(_ app: AppRef) -> NSImage? {
        if let id = app.bundleID {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.icon
        }
        return NSWorkspace.shared.runningApplications.first { $0.localizedName == app.name }?.icon
    }
}

// MARK: - Diagnostics

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
