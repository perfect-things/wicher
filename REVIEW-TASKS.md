# Review tasks

Results from a review on 2026-10-18 covering performance, stability, quality and best practices.
The package targets macOS 26 (since f552226), so the fixes below can use current SwiftUI and
AppKit APIs, including `@Observable` and `Button(_:systemImage:action:)`. It still compiles in
Swift 5 language mode; see the `@MainActor` task.

## High

- [x] **Run Copy Diagnostics off the main thread.**
  `WindowEnumerator.diagnosticsReport()` (WindowEnumerator.swift:716) asks every regular app
  for its windows one at a time, waiting up to 1 s each, on the main thread. One stuck or
  napping app freezes Settings with a beachball.
  - Build the report on `scanQueue` and hop back to main to write the pasteboard. This is
    safe: the report reads `snapshot`/`caches` under `lock`, and `performScan` already runs
    on that queue.
  - In `GeneralPane.copyDiagnostics` (SettingsViews.swift:97), disable the button while the
    report runs. Replace `DispatchQueue.main.asyncAfter` with
    `.task(id: copied) { try? await Task.sleep(for: .seconds(1.5)); copied = false }`.

- [ ] **Skip the hot-key reload when shortcuts haven't changed.**
  Every `.profiles` change, including a filter picker change, runs
  `AppController.registerHotKeys` (AppController.swift:147), which calls
  `SystemHotKeyOverride.apply`. That checks the 512-entry system shortcut table once per
  combo and once per reverse. The check took ≈13 ms in a standalone test, so this is about
  50 ms of main-thread work with the two default profiles.
  - Remember the combos last registered and return early when they are unchanged.
  - The handlers capture `profile` by value. Look the profile up by id when the hot key
    fires, so filter changes still apply without re-registering.
  - Optional: read the system table once per change, not once per combo
    (`SystemHotKeys.enabledConflicts`, SystemHotKeys.swift:70).

- [ ] **Stop working out `shortcutNote` inside `body`.**
  `ProfileRows.body` calls `SettingsModel.shortcutNote(for:)` (SettingsModel.swift:105),
  which calls `overriddenShortcut`. That is another ≈13 ms system-table check per profile
  on every render of the Switchers pane.
  - Work out the notes in the model when `Settings.didChange` fires or recording starts or
    stops, and keep them in a dictionary keyed by profile id that the view reads.

## Medium

- [ ] **Don't store AX observers for apps that have already quit.**
  `installObservers` (WindowEnumerator.swift:835) creates observers on `scanQueue` and
  stores them on main later. If the app quits in between, `removeObserver` has already run
  and the dead observer is stored. Because pids are reused, `observers[pid] == nil` then
  stops a later app with the same pid from ever being watched.
  - Before storing, check
    `NSRunningApplication(processIdentifier: pid)?.isTerminated == false`.

- [ ] **Explain login-item failures instead of beeping.**
  In `SettingsModel.launchAtLogin` (SettingsModel.swift:54), `register()` can succeed while
  the status becomes `.requiresApproval`. The getter then reads `false` and the switch
  flips back off with no explanation. A real error only gets a beep.
  - Show the error or status as a hint under the toggle. On `.requiresApproval`, offer
    `SMAppService.openSystemSettingsLoginItems()`.
  - Measure `SMAppService.mainApp.status`, which the getter calls on every render of
    General. If it is slow, cache it and refresh it when the window opens or the setting
    changes.

- [ ] **Accessibility fixes in the Settings views** (SettingsViews.swift).
  - Add button (line 176): `.help` is a tooltip, not a VoiceOver label. Use
    `Button("Add Switcher", systemImage: "plus", action: model.addProfile)` with
    `.labelStyle(.iconOnly)`, keeping the circle styling.
  - Sidebar (line 17): add `.accessibilityAddTraits(pane == model.pane ? .isSelected : [])`.
  - Remove Switcher (line 215): use `Button("Remove Switcher", role: .destructive)`, keeping
    the red style.
  - About icon (line 277): add `.accessibilityHidden(true)`, since the name is printed
    right below it.

## Low

- [ ] **Remove side effects from `body`** (SettingsViews.swift).
  - `ShortcutField` (line 250): `let _ = wire()` changes the recorder's closures on every
    render. The closures only look things up by profile id, so set them once when the
    recorder is created in `init`.
  - `ProfileRows` (line 198): `let _ = recording` exists only to force a redraw. Drop it
    once the shortcut notes live in the model (see High).

- [ ] **Make `Settings` observable and move the Settings UI to Observation.**
  `SettingsModel` and `ShortcutRecorder` use `ObservableObject`. Every `Settings.didChange`
  sends `objectWillChange`, which redraws every view holding the model, including
  `AboutPane` and `SettingsSidebar` on each slider tick. Bindings are hand-made closures
  (`SettingsModel.binding(_:)`, `profile(_:)`) because `Settings` can't be observed.
  - `Settings` (Settings.swift): mark it `@Observable` and turn each UserDefaults-backed
    computed property into a stored one. Load it from `defaults` in `init` (after
    `register(defaults:)`, keeping the current clamping), and persist it plus `post(_:)` the
    change in `didSet`. Observation only tracks stored properties, so this is what makes
    per-property updates work. Clamp on set: a `didSet` that reassigns the clamped value
    when it differs.
  - Fold the `profiles` cache into the stored `profiles` property. Keep the
    defaults-on-empty behaviour, and persist the generated defaults so their UUIDs are
    stable across launches.
  - Keep `Settings.didChange` for now, since `AppController` still listens to it.
    Replacing it is the next task.
  - Keep `Settings(defaults:)` working for the tests, and add tests that a set clamps,
    persists and posts.
  - `SettingsModel`: drop `binding(_:)` and `objectWillChange`. Panes bind directly with
    `@Bindable var settings = Settings.shared` and `$settings.iconSize`. Profile rows bind to
    `$settings.profiles[i]` or a by-id lookup on the observable model, not
    `Binding(get:set:)`. What is left in the model (pane selection, login item, shortcut
    notes, version) becomes `@Observable @MainActor`.
  - `ValueSlider` (line 310): keep the Int↔Double snapping in a small writable computed
    property or extension rather than an inline `Binding(get:set:)`.
  - `ShortcutRecorder`: make it `@Observable @MainActor` and hold it in
    `@State private var recorder`. Do this together with the `wire()` fix above.
  - Pass models to child panes as `let` or `@Bindable` instead of `@ObservedObject`.
  - `SwitchersPane` (line 158): `ForEach(model.profiles.enumerated(), id: \.element.id)`
    no longer needs the `Array(...)` wrapper.
  - Afterwards: the same-value slider task below mostly goes away. Observation skips
    redraws for equal `Equatable` values, but `didSet` still runs, so guard there to avoid
    redundant UserDefaults writes and `didChange` posts.

- [ ] **Replace `Settings.didChange` with Observation.** Do this after `Settings` is observable.
  Observation is part of Swift, not SwiftUI, so the AppKit code can watch `Settings`
  directly. After the task above, the only listener left is
  `AppController.observeSettings` (AppController.swift:133).
  - Replace it with one `Observations` loop per concern, each in a `Task { @MainActor in … }`
    started from `applicationDidFinishLaunching`:
    - hot keys: `Observations { Settings.shared.profiles.map(\.combo) }` →
      `registerHotKeys()`. This fires only when shortcuts change, so it also covers the
      "skip the hot-key reload" task (handlers must then look profiles up by id; see High).
    - appearance: `Observations { Settings.shared.appearanceMode }` →
      `AppearanceManager.apply`
    - menu-bar icon: `Observations { Settings.shared.showMenuBarIcon }` →
      `statusItem?.isVisible`
  - `Observations` delivers on a later main-loop turn, not inside the setter like the
    notification does. That is fine for these three; check nothing else relies on the
    synchronous delivery.
  - Then delete `Settings.didChange`, `changeKey`, `Settings.Change` and `post(_:)`.
  - Update `LiveUpdateTests.swift:86`, which asserts the posted `Change` values, to assert
    the observed values instead.
  - Update the "Config" paragraph in CLAUDE.md, which describes setters posting
    `Settings.didChange`.

- [ ] **Add `@MainActor` to the UI types.**
  The package compiles in Swift 5 mode (`swiftLanguageModes: [.v5]` in Package.swift). With
  `-strict-concurrency=complete` it gave 121 warnings, mostly UI classes not marked
  `@MainActor`.
  - Mark `AppController`, `SwitcherController`, `SettingsWindow`, `SettingsModel`,
    `ShortcutRecorder`, `AppearanceManager`, `WindowActivator` and `DeminiaturizeWaiter`.
  - Handle `WindowEnumerator` separately and deliberately, since it runs on both the main
    thread and `scanQueue`.
  - Then remove `swiftLanguageModes: [.v5]` to move to Swift 6 language mode.

- [ ] **Drop the `.icns` app icon.**
  macOS 26 reads the icon from `Resources/Assets.car` (via `CFBundleIconName`), so the
  `.icns` built for older systems is no longer used. Remove `Resources/Wicher.icns`, its
  generation in `scripts/make-icon.sh` (which still passes `--minimum-deployment-target
  13.0`), the copy in `build.sh`, `CFBundleIconFile` in Info.plist if present, and the
  mention in CLAUDE.md. Check the Finder and Dock icons afterwards.

- [ ] **Skip same-value slider writes.**
  `ValueSlider` (SettingsViews.swift:310) writes UserDefaults, posts `didChange` and redraws
  the pane on every drag tick, even when the snapped value hasn't changed. Add
  `guard snapped != value` in the setter.

- [ ] **Merge cached titles instead of overwriting them.**
  `reconcile` (WindowEnumerator.swift:269–363) copies `caches.titles`, releases the lock,
  and writes the copy back later. Titles from a background scan that finished in between
  are lost until the next scan. Merge into the current value under the lock instead.

- [ ] **Test: does hover move the selection when the mouse hasn't moved?**
  `SwitcherRowView.mouseEntered` (SwitcherRowView.swift:130) may fire when a background
  refresh re-lays out rows under a still cursor, so the selection jumps to the row under
  the pointer. Test it by opening the switcher with the cursor over the panel, then opening
  or closing a window in the background. If it happens, only accept hover after real mouse
  movement (compare `NSEvent.mouseLocation` with the position when the panel opened).
