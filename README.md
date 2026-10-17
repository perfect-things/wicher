# wicher

A tiny macOS **window switcher** — an ⌘-Tab-style HUD that lists *windows*
(not just apps) across every running application, with type-to-search and
full **Light / Dark / System** appearance support.


## What it does

- Press **⌥Tab** (configurable) to open a floating HUD listing all standard
  windows, ordered most-recently-used.
- **Hold ⌥, tap Tab** to cycle; **release ⌥** to switch. A quick tap+release
  within the show-delay switches to the previous window *without* drawing the
  panel. Or use ↑/↓, scroll, or the mouse. **⇧⌥Tab** cycles
  backward. **Esc** cancels.
- **Type** to fuzzy-search window titles / app names, with matched characters
  emphasized. Release ⌥ to jump to the top match.
- **Grouped sections** — minimized, hidden-app, and app-only entries can each be
  shown inline, in a section at the bottom, or hidden.
- **Multiple switchers** — each is a *profile* with its own shortcut and filters.
  Ships with **⌥Tab** (all windows) and **⌥\`** (current app's windows).
  Per profile: *all apps / active app*, *all Spaces / visible Spaces*, and the
  three placement choices above.
- **Liquid Glass** HUD on macOS 26+ (a blurred material on older systems).
- Menu-bar item → **Settings…** (also ⌘, while the switcher is open). The menu-bar
  icon can be hidden; open Wicher again from Finder or Spotlight to reach Settings.
  - **General**: launch at login, menu-bar icon, hover/scroll selection,
    show-delay, and **Copy Diagnostics** (what macOS reports about every app's
    windows, for bug reports).
  - **Appearance**: Light / Dark / System (applied live to the HUD *and* the
    settings window), selection highlight, **Icon size**, **Text size** and **Row padding**, and **Panel width** (30–150 % of the icon-derived width) sliders, and **Show app names** (off: rows are just icon + title).
  - **Switchers**: add/remove profiles and edit each one's shortcut + filters.
  - **About**: version.

## Design goals

- **Small & fast.** AppKit (+ SwiftUI for Settings) + Carbon + Accessibility +
  CoreGraphics. No
  bundled database, no WebKit — recency is kept in memory, settings in
  `UserDefaults`.
- **Minimal permissions.** Needs only **Accessibility** — window titles are read
  via the Accessibility API, so it does *not* require Screen Recording.
- **Menubar app.** — no Dock icon; lives in the menu bar.

## Build & run

```sh
scripts/build.sh    # compiles and produces Wicher.app (installs nothing)
swift test          # unit tests
open Wicher.app     # first launch prompts for Accessibility access
```

The same tasks are wrapped in a `justfile`: `just build|test|run|install|snapshot|icon|clean`;
plain `just` lists them.

Grant **System Settings → Privacy & Security → Accessibility → Wicher**, then
relaunch. Press **⌥Tab**.

Requires macOS 13+ and an installed Swift toolchain (Xcode or Command Line
Tools). Development only: without a signing identity the app is **ad-hoc
signed**, so macOS re-asks for Accessibility access after each rebuild. Run
`scripts/make-signing-identity.sh` once to create a local self-signed identity;
`build.sh` then signs with it and the grant survives rebuilds.

The app icon is an Icon Composer document (`Resources/Wicher.icon`). After
editing it, run `scripts/make-icon.sh` (needs full Xcode) to regenerate the
committed `Assets.car`, `Wicher.icns` and previews; `build.sh` just copies them.

## Scope & known limitations
- **Space filtering** ("visible Spaces") correlates each AX window with its
  `CGWindowID` via the private `_AXUIElementGetWindow`. If that symbol is ever
  unavailable the filter degrades safely (every window is treated as current).
- MRU ordering is per window for windows wicher has seen come to the front,
  falling back to application order for the rest.
- The default shortcut is ⌥Tab, but any chord can be recorded — including ⌘Tab.
  A shortcut that macOS itself uses (⌘Tab, ⌘`, Spotlight…) replaces the system
  one while wicher runs (via a private CoreGraphics call); the system shortcut
  comes back when wicher quits or the shortcut changes.
- Reverse cycling for a profile is its shortcut **plus Shift** (not separately
  editable). A shortcut that already contains Shift has no reverse; use ↑.
- A bare key with no modifier is accepted only for function keys (F1–F20);
  without a modifier to release, press ↩ or click to switch.

## Layout

```
Package.swift            SwiftPM: WicherCore library, wicher executable, tests; macOS 13+
Info.plist               LSUIElement agent-app bundle metadata
scripts/
  build.sh               compile + assemble Wicher.app + sign (stable identity or ad-hoc)
  make-signing-identity.sh  one-time local self-signed signing identity
  make-icon.sh           Resources/Wicher.icon → Assets.car, Wicher.icns, previews (Xcode)
Resources/               app icon source + prebuilt icon assets
Sources/wicher/main.swift          entry point → WicherApp.run()
Sources/WicherCore/                everything else (a library, so it is testable)
  WicherApp.swift         NSApplication setup (.accessory)
  AppController.swift     menu bar, main menu, hot keys (per profile), MRU, AX trust
  Settings.swift          UserDefaults-backed settings + profiles; posts didChange
  SwitcherProfile.swift   per-switcher config: shortcut + scope/space/placement
  AppearanceManager.swift AppearanceMode + Light/Dark/System → NSApp.appearance
  HUDMetrics.swift        icon/text/padding sliders → every pixel dimension
  HotKey.swift            Carbon RegisterEventHotKey wrapper + key-code names
  SystemHotKeys.swift     find/disable/restore system shortcuts a switcher claims
  ShortcutRecorder.swift  records a chord for the Settings shortcut button
  AXPrivate.swift         _AXUIElementGetWindow (Space correlation, with fallback)
  WindowInfo.swift        window / app-only model + stable WindowKey
  WindowEnumerator.swift  AX + CGWindowList collection, snapshot, observers, MRU
  WindowAssembly.swift    scan inputs → rows (pure)
  WindowGrouping.swift    scope/space/placement → ordered sections (pure)
  WindowActivator.swift   activate + raise; un-minimize via DeminiaturizeWaiter
  FuzzyMatcher.swift      subsequence match + scoring + highlight ranges
  SwitcherSession.swift   one session: rows for the query + selection (pure)
  SwitcherController.swift session lifecycle, delay, monitors, hold-repeat, commit
  SwitcherListView.swift  backdrop (Liquid Glass / blur), search bar, pooled rows
  SwitcherRowView.swift   row + section header views
  SwitcherPanel.swift     non-activating HUD panel
  SettingsWindow.swift    settings window: sidebar split view hosting SwiftUI panes
  SettingsViews.swift     General / Appearance / Switchers / About panes
  SettingsModel.swift     observable bridge from the panes to Settings
Tests/WicherCoreTests/    unit tests (swift test)
```
