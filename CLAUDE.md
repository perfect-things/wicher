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
- `tasks.md` — the user's running bug/issue list. Check it before starting work.

The root `package.json` is vestigial (npm placeholder); there is no JS in this project
and no git repository.

## Build & run

```sh
cd wicher && ./build.sh      # swift build -c release + assemble + ad-hoc sign Wicher.app
open wicher/Wicher.app       # first launch prompts for Accessibility
```

`swift build` alone compiles but produces a bare binary, not the `LSUIElement` bundle —
hot keys and the HUD need the assembled `.app`. There is **no test target**; verify
changes by building the app, granting Accessibility, and exercising ⌥Tab.

Because the app is ad-hoc signed, its cdhash changes on every rebuild, so macOS
re-prompts for Accessibility access after each `./build.sh`. Toggling Wicher off/on in
System Settings → Privacy & Security → Accessibility is the usual fix when the HUD
suddenly lists nothing.

## Architecture

AppKit + Carbon + Accessibility + CoreGraphics, no third-party dependencies, no
database. Flow of one switch:

1. **`AppController`** (app delegate) — menu-bar item, Accessibility prompt, and one
   Carbon hot key *pair* per profile (the combo, plus combo+Shift for reverse). It also
   subscribes to `NSWorkspace.didActivateApplicationNotification` to feed MRU.
2. **`HotKeyCenter`** — `RegisterEventHotKey` wrapper that reports **press and release**.
   Release is what drives commit-on-modifier-release; there is deliberately no event tap,
   which is why wicher cannot (and must not try to) intercept system ⌘Tab.
3. **`SwitcherController`** — the whole session state machine: show-delay, hold-to-repeat,
   grouping, search, selection, commit. The largest and most delicate file.
4. **`WindowEnumerator`** (singleton) — AX discovery + MRU bookkeeping.
5. **`WindowGrouping`** — pure function: `(profile, Enumeration, activePID) → [WindowSection]`.
   Put filtering/ordering policy here, not in the controller; it is the one piece that is
   trivially reasonable about in isolation.
6. **`WindowActivator`** — un-minimize, raise, activate; or a Dock-click-equivalent
   reopen for app-only entries.

Config: `Settings` (UserDefaults; globals) + `SwitcherProfile` (Codable, JSON-encoded
into UserDefaults; per-switcher scope/Spaces/placement + shortcut). Changing profiles
must call `PreferencesWindow.onProfilesChanged` so hot keys re-register.
`HUDMetrics.make(iconSize:textSize:rowPadding:)` derives every pixel dimension — don't
hardcode row heights or panel widths elsewhere.

## Invariants worth knowing before changing enumeration

`WindowEnumerator.enumerate()` is where most of the subtlety lives, and most of the open
issues in `tasks.md` are about it:

- **Titles come from AX (`kAXTitleAttribute`), never `kCGWindowName`.** That is the whole
  reason the app needs only Accessibility and not Screen Recording. Reaching for
  `kCGWindowName` to fix a missing title would silently add a second permission
  requirement — don't, without flagging it.
- `CGWindowList` is used for window *numbers, pids, layer and order only*.
- **Fullscreen shims**: an AX "standard" window whose `CGWindowID` is on-screen at some
  layer but *not* at layer 0 is a macOS fullscreen helper window and is skipped. A window
  on another Space is not on-screen at all, so it survives this test.
- **The CGWindowList fallback** adds one representative row only for apps where AX
  returned *no* windows (typically fullscreen apps on another Space). It must stay gated
  on `appsWithAXWindows`, or fullscreen apps sprout phantom rows.
- **"Apps without windows"** lists only `.regular` apps that produced no row at all from
  either path — background agents and off-Space apps must never land there.
- Spaces membership uses the private `_AXUIElementGetWindow` via `AXPrivate` (dlsym). If
  the symbol disappears, every window is treated as on the current Space; preserve that
  graceful degradation.
- Each app gets `AXUIElementSetMessagingTimeout(axApp, 0.5)`. Lowering it makes
  enumeration snappier but starts dropping minimized/off-Space windows; raising it lets
  one hung app stall the whole HUD. Enumeration runs synchronously on the main thread at
  summon time, so this timeout is the dominant term in open latency.
- Ordering is: per-window recency stamp → app MRU → stable enumeration order.

## HUD behavior details

- `SwitcherPanel` is a `.nonactivatingPanel` so wicher never becomes the active app; it
  swallows `keyDown`/`performKeyEquivalent` to avoid the system beep, and
  `SwitcherController.handleLocal` returns `nil` for key events for the same reason.
- A **global** `NSEvent` monitor catches the trigger modifier being released while the
  panel is not yet key (during the show-delay) and dismisses on outside clicks; the
  **local** monitor handles everything once the panel is key. Both are needed.
- A tap+release inside `showDelayMs` switches to the previous window without ever drawing
  the panel — `beginSession` preselects index 1 for that reason.
- Discrete presses wrap around the list; auto-repeat while held clamps at the ends.
- Typing switches to a flat, `FuzzyMatcher`-scored list with no section headers; matched
  ranges are bolded. An app-name-only match is scored 5 lower than a title match.
