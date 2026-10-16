# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository shape

Two things live here, and only one is code:

- `wicher/` — the Swift package and app. **All source work happens here.**
- `analysis/RE-findings.md` — reverse-engineering notes on Contexts.app, written with
  REA (`.mcp.json` wires up the `rea` MCP server). It documents *which macOS mechanism*
  a window switcher uses, tagging every claim **[OBS]** (observed) / **[INF]** (inferred)
  / **[UNK]**. wicher is a clean reimplementation: no Contexts code, class names, icon,
  or settings layout. Keep it that way, and keep the OBS/INF/UNK discipline if you edit
  the findings.
- `analysis/code-review.md` — review of wicher itself: root causes of the original
  `tasks.md` issues (§1), and an open backlog of architecture / defect / perf / UX items
  (§2–§6). Check it before refactoring; strike or update items as they land.
- `tasks.md` — the user's running bug/issue list. Check it before starting work.

The root `package.json` is vestigial (npm placeholder); there is no JS in this project.
The built `wicher/Wicher.app` is committed, so every rebuild shows up in `git status`.

## Build & run

```sh
cd wicher && ./build.sh      # swift build -c release + assemble + ad-hoc sign Wicher.app
open wicher/Wicher.app       # first launch prompts for Accessibility
cd wicher && swift test      # unit tests (WicherCoreTests)
```

App icon: `wicher/Resources/Wicher.icon` (Icon Composer; light/dark/tinted/clear). Run
`wicher/scripts/make-icon.sh` after editing it — it needs full Xcode and regenerates the
committed `Resources/Assets.car` (macOS 26+), `Resources/Wicher.icns` (older macOS) and
previews; `build.sh` only copies them, so CLT-only builds still work.

`build.sh` also rewrites the binary's `LC_BUILD_VERSION` SDK field with `vtool`:
SwiftPM stamps it with the deployment target (13.0), and AppKit then draws legacy
controls (mini switches, flat sidebar, automatic menu icons) as if wicher were an old app.
`swift test` binaries keep the old stamp, so offscreen snapshots show the legacy look.

`swift build` alone compiles but produces a bare binary, not the `LSUIElement` bundle —
hot keys and the HUD need the assembled `.app`.

The package is split so the code is testable: `Sources/WicherCore` (library, all the
code) and `Sources/wicher` (executable: just `main.swift` → `WicherApp.run()`). Tests
in `Tests/WicherCoreTests` use `@testable import WicherCore` and cover the pure pieces —
`WindowAssembly` (the scan → rows classification), `WindowGrouping`, `FuzzyMatcher`,
`HUDMetrics`, `SwitcherSession` (incl. live updates), `HotKeyCombo`, `Settings` (via
`Settings(defaults:)` on a test suite) — plus `SwitcherListView` layout rendered
offscreen, and the Settings window's panes. Fixtures are hand-built (`axWindow: nil`; `AXUIElementCreateApplication` is
fine where an element is required — it does no IPC). The AX/CGWindowList *collection*,
hot keys, activation and the live HUD have no tests; verify those by building the app,
granting Accessibility, and exercising ⌥Tab. Set `WICHER_SNAPSHOT_DIR` when running
`swift test` to get a PNG of the list layout.

Signing: `build.sh` signs with the "Wicher Development" identity (override with
`WICHER_SIGN_IDENTITY`) when it exists, else ad-hoc. Create it once with
`wicher/scripts/make-signing-identity.sh` (self-signed, login keychain). With it, the
designated requirement is `certificate leaf = H"…"`, stable across rebuilds, so the
Accessibility grant survives. Ad-hoc signing changes the cdhash every build and macOS
re-prompts; toggling Wicher off/on in System Settings → Privacy & Security →
Accessibility is the fix when the HUD suddenly lists nothing (it also shows a notice).

## Architecture

AppKit + Carbon + Accessibility + CoreGraphics, no third-party dependencies, no
database. Flow of one switch:

1. **`AppController`** (app delegate) — menu-bar item (hideable: `Settings.showMenuBarIcon`;
   reopening the app — `applicationShouldHandleReopen` — and ⌘, in the panel open
   Settings instead), Accessibility prompt, and one
   Carbon hot key *pair* per profile (the combo, plus combo+Shift for reverse — none if
   the combo already has Shift). It also
   subscribes to `NSWorkspace.didActivateApplicationNotification` to feed MRU.
2. **`HotKeyCenter`** — `RegisterEventHotKey` wrapper that reports **press and release**.
   Release is what drives commit-on-modifier-release. There is deliberately **no event
   tap**. `suspend()`/`resume()` take every hot key off while a shortcut is recorded.
   - **System chords (⌘Tab, ⌘`, Spotlight…)**: `SystemHotKeys` finds enabled system
     ("symbolic") hot keys with the same chord via private `CGSGetSymbolicHotKeyValue` /
     `CGSIsSymbolicHotKeyEnabled` / `CGSSetSymbolicHotKeyEnabled` (dlsym; absent → no
     override, the shortcut just doesn't fire). `SystemHotKeyOverride` switches exactly
     those off while wicher runs, **persists their ids first**, re-enables them on quit,
     SIGTERM/SIGINT/SIGHUP, or when no shortcut claims them, and on launch re-enables
     whatever a crashed run left off. Never disable a system hot key without going
     through it.
   - **`ShortcutRecorder`** (Settings → Switchers) captures any chord: it suspends wicher's hot
     keys and, for the duration of a recording, pauses global hot keys twice over:
     public `PushSymbolicHotKeyMode(kHIHotKeyModeAllDisabled)` (no-op without
     Accessibility trust) and private `CGSSetGlobalHotKeyOperatingMode` (connection-scoped,
     so it dies with the process). Without trust the ⌘Tab override likely won't work
     either; the card says so. Validation is `HotKeyCombo.problem(amongOthers:)`: only bare
     typing keys and chords another switcher uses (incl. its reverse) are refused.
3. **`SwitcherController`** — session lifecycle and wiring: show-delay, hold-to-repeat,
   event monitors, panel placement, commit. It drives two pieces:
   - **`SwitcherSession`** — value-type model of one session: rows for the current query
     (grouped, or fuzzy-scored when searching) and the selection. No views or timers.
   - **`SwitcherListView`** — the panel's content view: backdrop, search bar, rows,
     selection highlight, preferred height. Row/header views are **pooled and placed by
     frame** (heights come from `HUDMetrics`); don't reintroduce per-render view
     creation or Auto Layout in rows.
   While the panel is shown it observes `WindowEnumerator.didRefresh` and calls
   `SwitcherSession.update(enumeration:)`, which keeps the selection by `WindowInfo.key`.
   Never before the panel is shown — a quick tap must commit the preselected window.
4. **`WindowEnumerator`** (singleton) — *collects* AX + CGWindowList input, keeps a
   background snapshot fresh via AX observers, owns the caches and MRU, and produces the
   **Copy Diagnostics** dump (`diagnosticsReport()`, Settings → General). The decision of which rows
   exist is **`WindowAssembly.assemble`** — pure, tested; put classification changes
   there, with a test.
5. **`WindowGrouping`** — pure function: `(profile, Enumeration, activePID) → [WindowSection]`.
   Put filtering/ordering policy here, not in the controller; it is the one piece that is
   trivially reasonable about in isolation.
6. **`WindowActivator`** — activate, then raise; a minimized window is un-minimized by
   `DeminiaturizeWaiter`, which raises on `kAXWindowDeminiaturizedNotification` (0.6 s
   timeout). App-only entries get a Dock-click-equivalent reopen.

Settings window: `SettingsWindow` (AppKit window + `NSSplitViewController`, sidebar
item) hosting SwiftUI panes (`SettingsViews`: grouped `Form`s) over `SettingsModel`,
which binds straight to `Settings.shared` and re-renders on `Settings.didChange` — no
copies to drift. `ShortcutRecorder` stays AppKit, wrapped in an `NSViewRepresentable`.

Config: `Settings` (UserDefaults; globals) + `SwitcherProfile` (Codable, JSON-encoded
into UserDefaults, decoded once and cached; per-switcher scope/Spaces/placement +
shortcut). Every setter posts `Settings.didChange` with a `Settings.Change`;
`AppController` re-registers hot keys (and re-applies the system override) on
`.profiles` and applies `.appearance`. `HotKeyCombo.reverse` is nil for a combo with
Shift. In the panel, `handleKeyDown` subtracts the trigger's modifiers, so ⌘-held typing
searches when the shortcut is ⌘Tab.
`HUDMetrics.make(iconSize:textSize:rowPadding:)` derives every pixel dimension — don't
hardcode row heights or panel widths elsewhere. That includes the corners, which are
concentric: `rowCornerRadius = panelCornerRadius − listInset` (capped at a capsule), with
`listInset` equal on all four sides.

The HUD backdrop is `NSGlassEffectView` (Liquid Glass) on macOS 26+, with the search bar
and list in its `contentView`; older systems get the masked `NSVisualEffectView`
(`maskImage`, since `layer.cornerRadius` doesn't clip a behind-window blur). Neither
renders in an offscreen snapshot. Glass is composited by the window server and spills a
soft edge past its bounds, so on macOS 26+ the panel window is `HUDMetrics.windowMargin`
larger than the glass on every side and has no window shadow — a window cut flush to
the glass showed a square outline (shadow) and clipped glow patches at the corners.
Rows are re-placed on the scroll view's clip-view frame changes, not in `layout()`:
inside the glass the scroll view settles after the list view's own layout pass.

## Invariants worth knowing before changing enumeration

Enumeration is where most of the subtlety lives. Read `analysis/code-review.md` §1
before touching it. Classification lives in `WindowAssembly` (tested); collection,
caching, `reconcile` and observers in `WindowEnumerator` (not tested).

**Summon path.** `enumerate()` serves the cached snapshot if it is < `maxSnapshotAge`
(2.5 s) old, after `reconcile()` patches it cheaply: CGWindowList (which windows still
exist / are on this Space), `NSRunningApplication.isHidden`, and one AX round trip to
the frontmost app only. Only a missing/stale snapshot triggers a synchronous
`performScan`. Background scans are driven by per-app `AXObserver`s, `NSWorkspace`
notifications, and a 2 s safety timer (`refreshInterval`, suspended while displays
sleep); a refresh requested during a scan re-runs afterwards rather than being dropped.

- **Titles come from AX (`kAXTitleAttribute`), never `kCGWindowName`.** That is the whole
  reason the app needs only Accessibility and not Screen Recording. Reaching for
  `kCGWindowName` to fix a missing title would silently add a second permission
  requirement — don't, without flagging it. Missing titles are covered by
  `WindowCaches` (titles, AX elements, minimized flags), keyed by `CGWindowID` and pruned
  to live windows on every scan.
- `CGWindowList` is taken with **`.optionAll`** and used for window *ids, pids, layer,
  bounds and on-screen state only*. `.optionAll` is noisy (menu-bar strips, icon caches,
  off-screen Chromium scratch windows), hence `CGWindowFact.isPlausibleWindow`.
- **Fullscreen shims**: an AX "standard" window whose `CGWindowID` is on-screen but *not*
  at layer 0 is a macOS fullscreen helper window and is skipped. A window on another
  Space is not on-screen at all, so it survives this test.
- **The CGWindowList fallback** runs only for apps with no AX windows (gated on
  `appsWithAXWindows`, or fullscreen apps sprout phantom rows). It emits a row per
  *confident* window (on-screen, or previously titled via AX); otherwise, for `.regular`
  apps only, one `representativeWindow` (prefers display-sized = fullscreen Space).
- `AppScan.answered` separates "AX replied with zero windows" from "AX timed out" — keep
  them distinct; conflating them is what caused the original disappearing-app bugs.
- **"Apps without windows"** lists only `.regular` apps that produced no row from either
  path — background agents and off-Space apps must never land there.
- **wicher's own windows** come from `NSApp.windows` (`cacheSelfWindows`), never AX —
  AX only reports the active Space. Closed Settings stays in `NSApp.windows`
  (`isReleasedWhenClosed = false`), so filter on `isVisible || isMiniaturized`.
- **`NSWindow.windowNumber` → `CGWindowID` must use `NSWindow.cgWindowID`**
  (`CGWindowID(exactly:)`). The status-bar window reports 2^32 and a plain conversion
  traps at launch.
- Space membership: `_AXUIElementGetWindow` (private, via `AXPrivate`/dlsym) maps AX
  windows to `CGWindowID`. If the symbol disappears, `wid` is nil and the window is
  treated as on the current Space; preserve that graceful degradation. Minimized windows
  and hidden apps' windows also count as current (`spaceMembership`).
- AX timeouts: `foregroundTimeout` 0.2 s (sync summon scan, also `reconcile`) and
  `backgroundTimeout` 1.0 s. Apps are scanned concurrently (16 at a time) with one
  `AXUIElementCopyMultipleAttributeValues` per window. Don't move scanning back onto the
  summon path — App Nap makes cold serial AX cost ~1 s.
- Ordering is applied at read time in `order(_:)`: per-window recency stamp → app MRU →
  stable enumeration order, so a cached snapshot still reflects fresh MRU.
- AX observers: app-level notifications per app; `kAXUIElementDestroyedNotification` is
  registered **per window** (on an app element it means the app died) — existing windows
  at install, new ones from the `kAXWindowCreated` callback.
- Smoke test after any change here: launch the built bundle and confirm the process is
  still alive several seconds later (past the first background refresh).

## HUD behavior details

- `SwitcherPanel` is a `.nonactivatingPanel` so wicher never becomes the active app; it
  swallows `keyDown`/`performKeyEquivalent` to avoid the system beep, and
  `SwitcherController.handleLocal` returns `nil` for key events for the same reason.
- A **global** `NSEvent` monitor catches the trigger modifier being released while the
  panel is not yet key (during the show-delay) and dismisses on outside clicks; the
  **local** monitor handles everything once the panel is key. Both are needed.
- A tap+release inside `showDelayMs` switches to the previous window without ever drawing
  the panel — `SwitcherSession` preselects index 1 (forward) for that reason.
- Discrete presses wrap around the list; auto-repeat while held clamps at the ends.
- Typing switches to a flat, `FuzzyMatcher`-scored list with no section headers; matched
  ranges are bolded. An app-name-only match is scored 5 lower than a title match.
