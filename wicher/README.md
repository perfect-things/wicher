# wicher

A tiny macOS **window switcher** — an ⌘-Tab-style HUD that lists *windows*
(not just apps) across every running application, with type-to-search and
full **Light / Dark / System** appearance support.

wicher is an independent, from-scratch reimplementation of the window-switcher
idea popularized by Contexts. It was built after reverse-engineering Contexts
with [REA](https://github.com/morluto/rea) to understand *what macOS mechanism*
a window switcher uses — not its code or design. The findings (strictly
separating what was observed from what was inferred) are in
[`../analysis/RE-findings.md`](../analysis/RE-findings.md). No Contexts code,
class names, icon, or settings layout were copied.

## What it does

- Press **⌥Tab** (configurable) to open a floating HUD listing all standard
  windows, ordered most-recently-used.
- **Hold ⌥, tap Tab** to cycle; **release ⌥** to switch. A quick tap+release
  within the show-delay switches to the previous window *without* drawing the
  panel (like macOS ⌘-Tab). Or use ↑/↓, scroll, or the mouse. **⇧⌥Tab** cycles
  backward. **Esc** cancels.
- **Type** to fuzzy-search window titles / app names, with matched characters
  emphasized. Release ⌥ to jump to the top match.
- **Grouped sections** — minimized, hidden-app, and app-only entries can each be
  shown inline, in a section at the bottom, or hidden.
- **Multiple switchers** — each is a *profile* with its own shortcut and filters.
  Ships with **⌥Tab** (all windows) and **⌥\`** (current app's windows).
  Per profile: *all apps / active app*, *all Spaces / visible Spaces*, and the
  three placement choices above.
- Menu-bar item → **Preferences**:
  - **Appearance**: Light / Dark / System (applied live to the HUD *and* the
    settings window) + **Icon size**, **Text size**, and **Row padding** sliders.
  - **General**: show-delay, hover/scroll selection, launch at login.
  - **Switchers**: add/remove profiles and edit each one's shortcut + filters.

## Design goals

- **Small & fast.** Pure AppKit + Carbon + Accessibility + CoreGraphics. No
  bundled database, no WebKit — recency is kept in memory, settings in
  `UserDefaults`. (Contexts, by contrast, links Realm *and* sqlite *and* WebKit.)
- **Minimal permissions.** Needs only **Accessibility** — window titles are read
  via the Accessibility API, so it does *not* require Screen Recording the way
  `kCGWindowName` would.
- **Agent app.** `LSUIElement` — no Dock icon; lives in the menu bar.

## Build & run

```sh
./build.sh          # compiles and produces Wicher.app (installs nothing)
open Wicher.app     # first launch prompts for Accessibility access
```

Grant **System Settings → Privacy & Security → Accessibility → Wicher**, then
relaunch. Press **⌥Tab**.

Requires macOS 13+ and an installed Swift toolchain (Xcode or Command Line
Tools). Development only: without a signing identity the app is **ad-hoc
signed**, so macOS re-asks for Accessibility access after each rebuild. Run
`scripts/make-signing-identity.sh` once to create a local self-signed identity;
`build.sh` then signs with it and the grant survives rebuilds.

## Scope & known limitations

- **Window switcher only** — the Contexts sidebar and trackpad gestures are out
  of scope by design.
- **Space filtering** ("visible Spaces") correlates each AX window with its
  `CGWindowID` via the private `_AXUIElementGetWindow`. If that symbol is ever
  unavailable the filter degrades safely (every window is treated as current).
- MRU ordering is tracked at **application** granularity (per-window MRU across
  enumerations is not attempted in this version).
- Hot keys use a non-conflicting default (⌥Tab); wicher does **not** intercept
  the system ⌘-Tab (that would need an always-on event tap).
- Reverse cycling for a profile is its shortcut **plus Shift** (not separately
  editable).

## Layout

```
Package.swift            SwiftPM executable, macOS 13+
Info.plist               LSUIElement agent-app bundle metadata
build.sh                 compile + assemble Wicher.app + ad-hoc sign
Sources/wicher/
  main.swift             NSApplication entry (.accessory)
  AppController.swift     menu bar, hot keys (per profile), MRU, permission
  Settings.swift          UserDefaults-backed global settings + profiles (JSON)
  SwitcherProfile.swift   per-switcher config: shortcut + scope/space/placement
  AppearanceManager.swift AppearanceMode + Light/Dark/System → NSApp.appearance
  HUDMetrics.swift        HUDSize (Small/Medium/Large) → pixel metrics
  HotKey.swift            Carbon RegisterEventHotKey wrapper + key-code names
  AXPrivate.swift         _AXUIElementGetWindow (Space correlation, with fallback)
  WindowInfo.swift        window / app-only model
  WindowEnumerator.swift  AX discovery, flags, Space membership, MRU
  WindowGrouping.swift    scope/space/placement → ordered sections (pure)
  WindowActivator.swift   un-minimize + raise + activate
  FuzzyMatcher.swift      subsequence match + scoring + highlight ranges
  SwitcherPanel.swift     non-activating HUD panel
  SwitcherRowView.swift   two-column row + section header view
  SwitcherController.swift session/delay/grouping/search/commit orchestration
  PreferencesWindow.swift General + Appearance + Switchers settings
```
