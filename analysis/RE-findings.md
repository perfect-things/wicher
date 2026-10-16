# Reverse-engineering findings: Contexts.app

Tooling: REA (rea-agents 6.5.0) native-macOS provider + read-only `nm`/`strings`.
Target: `/Applications/Contexts.app` — **not launched, not modified**.
Analyzed the shipped Mach-O byte image only.

Legend: **[OBS]** = directly observed from the artifact · **[INF]** = inferred
(reasoning given) · **[UNK]** = not seen / could not determine.

---

## 1. Identity

| Field | Value | Source |
|---|---|---|
| Version | 3.9.0 (build 390) | **[OBS]** Info.plist |
| Bundle id | `com.contextsformac.Contexts` | **[OBS]** Info.plist / codesign |
| Signing | Developer ID — Usman Khalid (RZ7E748ZSC), hardened runtime | **[OBS]** codesign |
| Min macOS | 10.15 (plist `LSMinimumSystemVersion`); Mach-O `minos` 11.0 | **[OBS]** |
| Arch | Universal x86_64 + arm64 | **[OBS]** lipo |
| App type | `LSUIElement = true` → agent app, no Dock icon | **[OBS]** Info.plist |
| Category | Utilities | **[OBS]** Info.plist |
| Updates | Sparkle 1.27.1, feed `https://contexts.co/appcasts/stable.xml` | **[OBS]** |
| Licensing | Paid; `.contexts-license` XML file type | **[OBS]** Info.plist |
| Main binary size | ~17 MB (fat); arm64 slice ~8 MB | **[OBS]** |

Entitlements **[OBS]**: `com.apple.security.automation.apple-events`,
`com.apple.security.cs.disable-library-validation`. Not sandboxed.

## 2. Window-switcher mechanism (observed imported symbols)

All symbols below are **[OBS]** — present in the arm64 import table.

**Window discovery / control — Accessibility API**
- `AXIsProcessTrusted` — gate on Accessibility permission.
- `AXUIElementCreateApplication`, `AXUIElementCreateSystemWide`.
- `AXUIElementCopyAttributeValue(s)`, `AXUIElementCopyMultipleAttributeValues` — read window title, role, minimized, position.
- `AXUIElementPerformAction` — raise/activate a window (`AXRaise`).
- `AXUIElementSetAttributeValue` — set focused/main window.
- `AXObserverCreate` / `AXObserverAddNotification` — watch window created/destroyed/title-changed/focus events.
- `_AXUIElementGetWindow` (private) — map an AX element to a `CGWindowID`.
- `NSAccessibilityMinimizedAttribute` string present.

**Window list — CoreGraphics**
- `CGWindowListCopyWindowInfo`, `CGWindowListCreate`, `CGWindowListCreateDescriptionFromArray`.
- `kCGWindowBounds`, `kCGWindowIsOnscreen`; `CGSessionCopyCurrentDictionary`.

**Trigger + key interception**
- `RegisterEventHotKey` / `UnregisterEventHotKey` / `InstallEventHandler` (Carbon) — global shortcut.
- `CopySymbolicHotKeys` — read the system's registered hotkeys (e.g. to coexist with/replace ⌘-Tab).
- `CGEventTapCreate` / `CGEventTapEnable` / `CGEventTapIsEnabled` — intercept key events (needed for hold-modifier switching and to swallow ⌘-Tab).
- `CGEventCreateKeyboardEvent`, `CGEventPost`, `CGEventGet/SetFlags` — synthesize/relay key events.

**Trackpad gestures (out of scope for wicher)**
- `MTDeviceCreateList`, `MTDeviceStart`, `MTRegisterContactFrameCallback` from the **private** `MultitouchSupport.framework`. Matches the `PreferencesDoubleTouchSwitchWindowGesture*.png` resources and `palmRejectionThreshold` string.

**Persistence / other linked frameworks [OBS]**
- `libsqlite3` **and** Realm (`realm::util::Logger` symbols) are both linked — two embedded databases. WebKit (release notes / welcome / license views), Security + SystemConfiguration (Sparkle), QuartzCore (animations).

## 3. Feature surface (observed strings + Preferences icons)

Preferences tabs implied by `PreferencesIcon*@2x.png` **[OBS]**: Welcome, General,
Appearance, Panel, Sidebar, Gestures, Search, Rules, NumberSwitcher,
RecentSwitcher, License, About.

Switcher-related symbol/UI strings **[OBS]** (interpretation **[INF]**):
- `switcher`, `switchers`, `currentSwitcher`, `switchersListTableView` — multiple configurable switcher modes.
- `recentItemsSwitcherSearchEnabled` — a **Recent** (MRU) switcher with optional search.
- `numberSwitcherSpacesOption`, `sidebarShowKeyTypeNumberCheckbox` — a **Number** switcher (type a digit to jump).
- `searchActivationModifierFlags`, `highlightedCharacterRanges`, `highlightedCharactersColor`, `highlightedTextColor` — **type-to-search with matched-character highlighting**.
- `activateSelectedItemOnModifierKeysRelease` — **hold modifier, release to activate** (⌘-Tab-style).
- `modifierFlags`, `escapeKeyDownEventModifierFlags` — modifier-driven activation; Escape cancels.
- `panelUpdatesSelectionOnMouseMoveCheckbox`, `panelChangeSelectionOnScrollEnabledCheckbox` — mouse hover + scroll selection.
- `minimizedWindowsDisplay`, `isMinimized` — includes/handles minimized windows.
- `panelWidth`, `panelWidthSlider`, `panelDisplayModeOptions`, `CTPanelContentView` — switcher is a floating NSPanel with configurable width/mode (ObjC class prefix is `CT`).
- `*SpacesOption` — filter by current Space vs all Spaces.
- `allowAnyShortcutWithOptionModifier`, `shortcutPlaceholder` — customizable shortcut.

## 4. Inferred behavior [INF]

- The switcher is an `NSPanel` (non-activating, floating) HUD that enumerates windows via a **blend of CGWindowList (fast, all windows incl. other Spaces) and the Accessibility API (titles, minimized state, raising)**. Reasoning: both API families are imported, and CGWindowList alone cannot raise a window while AX alone cannot cheaply list across Spaces.
- Trigger uses a **CGEventTap** (not just RegisterEventHotKey) because hold-modifier/release-to-activate and swallowing the real ⌘-Tab require intercepting the key stream. `CopySymbolicHotKeys` is read to coexist with the system switcher.
- Realm/sqlite store **recency ordering + per-app rules + preferences**; strong inference, exact schema not examined.

## 5. Not examined / could not see [UNK]

- Internal class design, method bodies, and exact algorithms — **deliberately not decompiled** (rules forbid copying design; Ghidra also rejected the fat binary and a thinned slice was not pursued because it is unnecessary for an independent build).
- Exact ranking/MRU algorithm, fuzzy-match scoring, and DB schemas.
- Private `_AXUIElementGetWindow` call details; exact event-tap placement/filtering.
- Anything about the sidebar beyond its existence (explicitly out of scope).
- Default appearance of the switcher panel (dark HUD assumed, not confirmed visually — app not launched).

## 6. Assumptions carried into the build

1. A window switcher needs Accessibility permission (`AXIsProcessTrusted`) to raise windows in other apps — **confirmed by import**, standard macOS requirement.
2. CGWindowList is sufficient to enumerate on-screen windows + titles + owner PID for a v1; AX is used for raising and minimized state. (wicher starts CGWindowList-first for speed.)
3. ⌘-Tab replacement requires a CGEventTap; a plain RegisterEventHotKey cannot swallow the system ⌘-Tab. wicher v1 will default to a **non-conflicting** shortcut (configurable) to avoid needing to fight the system switcher, with event-tap interception as an opt-in path.
4. "Lightweight" is achievable without Realm/sqlite/WebKit — wicher will keep MRU in memory + a tiny `UserDefaults`/JSON store, and build all UI programmatically (Contexts itself ships only 2 nibs, so it is already mostly code-built).
5. Dark mode: AppKit's native appearance system (`NSApp.appearance`) gives light/dark/system for free in both the switcher HUD and the settings window — this is the specific gap the user called out in Contexts' settings window.
6. **Space detection** uses the private `_AXUIElementGetWindow` to map an AX window to a `CGWindowID`, then intersects with `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` (which exposes window *numbers*/pids without Screen Recording). This is the standard public-ish technique; **inferred** that Contexts does something equivalent (it imports both AX and CGWindowList, incl. the same private symbol — observed). wicher degrades to "all windows are current Space" if the symbol is ever missing.
7. **Grouping/placement + multiple shortcuts** are modelled from the Contexts Preferences screenshots the user supplied (observed from *those images*, not the binary): "Show windows from / of", "Minimized / Hidden / Apps without windows: Show / Show at bottom / Do not show", and per-shortcut scope. wicher reimplements the *behavior*; the layout is the generic switcher layout (per the user's explicit go-ahead), not a copy of Contexts' assets, class names, or exact control arrangement.
8. **Show-delay**: Contexts' "Show Panel after a slight delay" is observed in the screenshot. Exact default (ms) is **unknown**; wicher uses 180 ms as a guessed, configurable default.

