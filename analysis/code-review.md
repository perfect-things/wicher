# wicher — code review: architecture, quality, performance, UX

Review of `wicher/Sources/wicher` at the point where the `tasks.md` issue list was
addressed. Line references are to the tree *after* those fixes landed.

Scope note: this is a review of wicher's own source. It carries no findings from
`RE-findings.md` beyond what is already recorded there.

---

## 1. What the reported issues actually were

All six entries under `# Issues` in `tasks.md` reduced to three root causes. Worth
recording, because the shape of the bug explains most of the recommendations below.

### 1.1 "Apps without windows" was a dumping ground

`WindowEnumerator.enumerate()` classified an app as having no windows whenever the
Accessibility API returned no window list *and* `CGWindowListCopyWindowInfo` with
`.optionOnScreenOnly` found nothing for it. Three very different situations all land
there:

| Situation | AX windows | On-screen CG windows | Old verdict |
|---|---|---|---|
| App genuinely has no windows (Finder, no window open) | 0 | 0 | no windows ✓ |
| Full-screen app on another Space | 0 | 0 | no windows ✗ |
| Hidden app that did not answer AX in time | 0 | 0 | no windows ✗ |
| App asleep (App Nap) — AX timed out | 0 | 0 | no windows ✗ |

With "Apps without windows: Do not show", the last three silently disappeared from
the panel. That is issues 1, 2 and 3 in one line of logic.

**Fix.** The CGWindowList pass now uses `.optionAll` rather than `.optionOnScreenOnly`,
which also returns windows that are minimized, belong to hidden apps, or live on
another Space. `isOnscreen` then distinguishes the current Space from the rest, and
"no windows" means *neither* source found one.

`.optionAll` needs care — it is not a clean list. Measured on a live desktop, every
app owns several layer-0 windows that are not user-facing: one 1728×33 strip per
display, 64×64 icon caches, and assorted off-screen scratch windows (500×500,
800×600) that Chromium/Electron apps keep around. Emitting a row per `.optionAll`
entry would invent entries. `CGWindowFact.isPlausibleWindow` applies a size floor,
and `representativeWindow(among:screenSizes:)` then emits **one** stand-in row for an
app we have no AX answer and no cached title for, preferring a display-sized window
(the signature of a full-screen Space).

### 1.2 Titles decayed to the app name

Issue 4 — hidden Zen showing "Zen" instead of the page title — was the same AX
failure seen from the other end: the fallback row had no title because
`kCGWindowName` is deliberately not read (it would pull in the Screen Recording
permission; see `CLAUDE.md`).

**Fix.** `titleCache`, `axCache` and `minimizedCache`, all keyed by `CGWindowID`
and pruned to live windows each scan. A window keeps the last title AX gave for it,
plus the last `AXUIElement` (so it can still be raised individually) and the last
minimized flag (so it is still filed under "Minimized"). Because the background
refresh runs while the app is awake and visible, the cached title is current at the
moment the app is hidden.

### 1.3 Enumeration was synchronous, serial, and cold

Issue 6 — "over a second if wicher has not been opened for a couple of minutes" —
came from `enumerate()` running at summon time, on the main thread, one app after
another, each a blocking AX IPC round trip with a 0.5 s timeout. After a few idle
minutes every app has been App Napped, so each round trip costs real time. Twenty
napped apps at 50–100 ms is exactly the second the issue describes. It is also *why*
AX returned nothing for Things and Zen: a timeout and "no windows" are
indistinguishable at the call site.

**Fix,** in three parts:

1. **Scanning moved off the summon path.** `start()` installs per-app `AXObserver`s
   for window created/destroyed/minimized/deminimized/title-changed/focus-changed and
   app hidden/shown, plus `NSWorkspace` notifications for launch/terminate/hide/unhide
   and Space changes. Each schedules a coalesced background refresh. A 2 s safety
   timer covers apps whose observers never attached. `enumerate()` serves the cached
   snapshot when it is under 2.5 s old, which is the normal case.
2. **Parallel AX.** The cold path still scans, but queries every app concurrently
   (16 at a time) rather than serially, so the cost is roughly one slow app rather
   than the sum of all of them. Its AX timeout is 0.2 s — short enough not to stall
   the HUD, and the caches cover what a timeout loses. The background path uses 1 s.
3. **Fewer round trips per window.** Subrole, title and minimized state come from a
   single `AXUIElementCopyMultipleAttributeValues` call instead of three
   `AXUIElementCopyAttributeValue` calls.

MRU ordering was moved out of the scan and into `order(_:)` at read time, so a cached
snapshot still reflects the newest recency stamps.

A cache introduces its own failure mode, and it showed up immediately: close,
minimize or hide a window and summon the panel within the cache window, and you saw
the state you had just left. `reconcile(_:)` closes that gap on every summon, for a
few milliseconds, by refreshing everything that can be known *without* cross-process
IPC — CGWindowList says which windows still exist and which are on this Space,
`NSRunningApplication` says which apps are hidden — and then re-reading, via AX, only
the frontmost app, which is the one you just acted on and is awake by definition.
Two supporting fixes: `runRefresh` used to *drop* a refresh request that arrived
while a scan was in flight (exactly when a notification matters most), and it now
re-runs instead; and `AppScan` distinguishes "AX replied" from "AX replied with
windows", so an app that has genuinely closed its last window is told apart from one
that timed out.

Worth noting for later: `kAXUIElementDestroyedNotification` is registered on the
*application* element, where it signals the app's own destruction rather than its
windows'. Per-window registration is the usual remedy; the CGWindowList pruning in
`reconcile` makes it a background-freshness concern rather than a visible one.

**Trade-off, stated plainly:** the 2 s refresh keeps every app's AX connection warm,
which is what makes the panel instant, but it does prevent those apps from napping as
deeply. Refreshes are suspended while the display sleeps. If battery impact shows up,
`refreshInterval` is the single knob; raising it trades cold-open latency back.

### 1.4 Rounded corners (issue 5)

`visualEffect.layer?.cornerRadius` only clips what AppKit draws. The blurred backdrop
behind an `NSVisualEffectView` is composited by the window server and ignores the
layer, so each corner showed a square patch of blurred desktop outside the rounded
outline. Fixed with `NSVisualEffectView.maskImage` (a resizable rounded-rect with
`capInsets`), which is the supported way to shape the backdrop, plus
`panel.invalidateShadow()` after each resize so the shadow follows the new shape
instead of the cached one.

### 1.5 Space membership for minimized and hidden windows

A minimized window, or one belonging to a hidden app, is on no Space at all. It was
therefore treated as "not on the current Space" and vanished under the
"Visible Spaces" filter. `spaceMembership(wid:minimized:hidden:currentSpace:)` now
counts it as current, which is what a user expects.

### 1.6 wicher's own windows were asked about through AX

Preferences only appeared in the panel while you were on the Space it was open on.
The cause was asking the Accessibility API about our *own* process: AX reports an
app's windows on the active Space, so from anywhere else wicher had no windows to
report, and the CGWindowList fallback did not apply because it was gated on
`.regular` apps — wicher is `LSUIElement`, so `.accessory`.

There is no reason to use AX here at all. `NSApp.windows` is every window the process
owns, wherever it lives, with `title`, `isMiniaturized` and a `windowNumber` that is
the same identifier CGWindowList uses, so Space membership still resolves.
`cacheSelfWindows()` reads it on the main thread; `WindowActivator` orders our own
windows front directly rather than going out through AX or a Dock-click reopen. One
wrinkle worth remembering: `PreferencesWindow` sets `isReleasedWhenClosed = false`,
so a *closed* Preferences window stays in `NSApp.windows` and has to be filtered out
by `isVisible || isMiniaturized`.

A second, sharper one: `NSWindow.windowNumber` is an `Int` and is **not** always a
valid `CGWindowID`. A window with no backing device reports zero or negative, and the
status-bar item's window reports 2^32 — positive, but outside `UInt32`, so
`CGWindowID(window.windowNumber)` traps at runtime and takes the process with it. It
crashed on launch, before anything was on screen. `NSWindow.cgWindowID` now returns an
optional via `CGWindowID(exactly:)`; neither kind of window appears in CGWindowList,
so nil is the correct answer for both. Worth a general note: unconditional
`FixedWidthInteger` conversions on values that come from AppKit are a trap in both
senses, and `init(exactly:)` costs nothing.

Procedural lesson, since this shipped: "it compiles" is not a smoke test for an app
with no test target. Launching the built bundle and confirming the process is still
alive some seconds later would have caught this in one command, and is the cheapest
possible gate before handing a build over.

The same gating hid other agent apps' windows, so the CGWindowList fallback now
applies to non-`.regular` apps too — but only for windows it is confident about (on
screen now, or previously titled through AX). Guessing a stand-in row from an
off-screen window stays limited to Dock apps, since an agent app's off-screen
layer-0 window is far more likely to be chrome than a real window.

### 1.7 Verifying this on a real machine

The interesting cases cannot be reproduced from a shell: a process without
Accessibility trust gets `kAXErrorAPIDisabled` for everything, and full-screen Spaces
and hidden apps only exist on a live desktop. **Menu bar → Copy Diagnostics** now
dumps, per app, what AX reported versus what CGWindowList reports (ids, layer,
on-screen, size, title, per-app AX latency). If any of issues 1–4 persist, that dump
is the thing to look at — in particular `answered=false` on an app whose windows you
can see.

---

## 2. Architecture

### 2.1 What is working

The layering is sound and worth keeping: `WindowEnumerator` (discovery) →
`WindowGrouping` (policy) → `SwitcherController` (session) → `WindowActivator`
(effects). `WindowGrouping.sections(for:enumeration:activeAppPID:)` being a pure
function is the single best structural decision in the codebase — all the filtering
policy is in one 60-line file that can be reasoned about and, once there is a test
target, tested exhaustively. `HUDMetrics.make` as the only source of pixel dimensions
is the same idea applied to layout.

### 2.2 `SwitcherController` is doing four jobs

At ~520 lines it owns the session state machine, the view hierarchy, the event
monitors, and panel sizing. That is the file the `CLAUDE.md` calls "the largest and
most delicate", and the delicacy is mostly a consequence of the mixing. A worthwhile
split:

- `SwitcherSession` — `sessionActive`/`panelShown`/`selectionPos`/`query`/hold-repeat,
  with no AppKit types beyond `NSEvent`. Directly testable.
- `SwitcherListView` — `displayRows` → views, selection highlight, sizing.
- `SwitcherController` — wiring, monitors, commit.

This is a refactor, not a bug fix; it is worth doing before the next feature lands in
that file, not as an end in itself.

### 2.3 Windows are modelled as a class with no identity

`WindowInfo` is a `final class` but has no `==`, `hashValue` or stable id, so
selection cannot survive a model rebuild — which is why the background refresh
deliberately does *not* update a panel that is already open. Giving `WindowInfo` an
identity (`cgWindowID` where known, `pid` + title otherwise) would allow a live panel
to pick up fresh titles and newly opened windows without losing the user's place. It
would also make `rowViews: [Int: SwitcherRowView]`, currently keyed by array index,
less fragile.

### 2.4 Settings are read ad hoc from `UserDefaults`

`Settings.shared.selectOnHover` is read on every `mouseEntered`, and
`Settings.shared.profiles` JSON-decodes on every access. Neither is hot enough to
matter today, but `Settings` is a plain façade with no change notification, so every
consumer has to re-read to notice an edit — `PreferencesWindow.onProfilesChanged` is a
hand-rolled callback that exists only because of this. An `@Observable`/Combine
`Settings` with cached values would delete that callback and the re-read pattern.

---

## 3. Code quality

### 3.1 No tests at all

`CLAUDE.md` states there is no test target, and verification is "build the app, grant
Accessibility, press ⌥Tab". That is the single largest quality gap. Three things are
pure and would be covered cheaply by a `.testTarget`:

- `WindowGrouping.sections` — every combination of scope × spaces × three placements.
- `FuzzyMatcher.match` — ordering, highlight ranges, non-matches.
- `HUDMetrics.make` — clamping at the ends of each range.

`WindowEnumerator` cannot be tested without AX, but the *assembly* half (facts +
scans → rows) could be if `performScan` were split into a pure
`assemble(facts:scans:metas:caches:)` and an impure collector. Given that this is
where every reported bug lived, that split is worth the effort.

### 3.2 Specific defects

- **`AppController.swift:80`** — the reverse hot key is the forward combo plus
  `shiftKey`. If a user's combo *already* contains Shift, forward and reverse are the
  same combo; the second `RegisterEventHotKey` fails with `eventHotKeyExistsErr`, the
  `register` call returns `nil`, and reverse cycling silently does nothing. Either
  reject Shift in the recorder or report the failure.
- **`FuzzyMatcher.swift:27`** — `Character(ch.lowercased())` constructs a `Character`
  from a `String`, which traps if the lowercase form is not exactly one grapheme
  cluster. Use `ch.lowercased().first` and compare optionals; the cost is the same and
  it cannot crash the whole app on an unusual window title.
- **`FuzzyMatcher.swift:65`** — `nsRange(fromCharIndex:through:in:)` calls
  `candidate.index(_:offsetBy:)` from `startIndex` for each run, making range building
  O(n²) in title length. Walk the indices once alongside the match loop.
- **`WindowActivator.swift:18,54`** — `activate(options: .activateIgnoringOtherApps)`
  is deprecated as of macOS 14; `activate()` is the replacement. The 0.05 s
  re-check after un-minimizing is a race dressed as a retry — it works, but an
  `AXObserver` for `kAXWindowDeminiaturized` would be deterministic.
- **`SwitcherRowView.swift:68`** — `layout()` is overridden to set colors. Colors are
  not layout; this runs on every geometry change and is skipped on none. Move to a
  dedicated `applySelectionAppearance()` called from the `isSelected` `didSet`.
- **`SwitcherRowView.swift:81`** — the tracking area is built from `bounds` without
  `.inVisibleRect`, so hover regions go stale once the list scrolls. Add
  `.inVisibleRect` and drop the manual rect.
- **`SwitcherRowView.swift:89`** — committing on `mouseUp` without a matching
  `mouseDown` means a drag that happens to end over a row activates it.
- **`HotKey.swift:60`** — the Carbon event handler reaches back through
  `HotKeyCenter.shared` instead of the `userData` pointer the API provides, and
  `handlerRef` is never removed. Harmless in a singleton that lives for the process,
  but it is the kind of thing that stops being harmless later.

### 3.3 Style

Comment density and naming are genuinely good — the "why" comments in
`WindowEnumerator` and `SwitcherPanel` are the kind that survive. Two gaps: no strings
are localized (`NSLocalizedString` is absent entirely), and `fatalError("not used")`
in two `init?(coder:)` overrides would be better as `preconditionFailure`, which
communicates the same thing without implying a recoverable error.

---

## 4. Performance

Beyond the enumeration work in §1.3:

- **Row views are rebuilt from scratch on every keystroke.**
  `SwitcherController.rebuildRows()` (`:428`) removes every arranged subview and
  creates new `SwitcherRowView`s with fresh Auto Layout constraints. With 60+ windows
  and a user typing, that is 60 view allocations and ~240 constraint activations per
  character. An `NSTableView` with a reuse queue, or simply reconfiguring the existing
  row views when the row count is unchanged, would remove this entirely. This is the
  next performance item after enumeration.
- **Auto Layout for fixed-size rows.** Every row sets four constraints to produce a
  layout that `HUDMetrics` already computes exactly. Manual `frame` placement inside
  a flipped container would be both faster and shorter.
- **`sizeAndCenterPanel` caps the list at 70 % of screen height** (`:487`) but the
  stack still builds every row, including the ones off-screen. Combined with view
  reuse this becomes a non-issue.
- **`NSImage` icons are re-fetched per scan.** `app.icon` is cheap but not free at a
  2 s cadence across ~30 apps; caching by bundle id would avoid it.

---

## 5. User experience

- **Selected-row contrast.** `SwitcherRowView.swift:74` hardcodes `NSColor.white` on
  `controlAccentColor`. With the yellow or graphite accent colors that is poor
  contrast. `.alternateSelectedControlTextColor` is the semantic color that tracks the
  accent.
- **VoiceOver.** The HUD exposes no accessibility roles or labels — an irony for an
  app built on the Accessibility API. A `NSAccessibilityRole.list` on the stack and
  per-row labels would be a small change.
- **Empty state.** When nothing matches a query the panel shows an empty box of one
  row's height. A "No matching windows" row would be clearer.
- **No window-close or app-quit from the panel.** The usual next feature for a
  switcher (⌘W / ⌘Q on the selection); the AX element needed for it is already in
  `WindowInfo`.
- **Search never reaches app-only entries.** `rebuildModel()` searches
  `enumeration.windows` only, so typing can never find an app from the "Apps" section
  even when that is exactly what the user wants.
- **Diagnostics are write-only.** "Copy Diagnostics" puts the dump on the clipboard
  with no confirmation; a brief menu-title change or a notification would tell the
  user it worked.
- **Accessibility re-prompting.** Because `build.sh` ad-hoc signs, the cdhash changes
  every build and macOS re-prompts, which `CLAUDE.md` documents as a known annoyance.
  Signing with a stable self-signed identity (created once in Keychain Access) rather
  than `-` keeps the cdhash stable across rebuilds and removes the toggle-off/toggle-on
  dance. This is the highest-value developer-experience fix available.

---

## 6. Suggested order of work

1. Test target covering `WindowGrouping`, `FuzzyMatcher`, `HUDMetrics` — everything
   below is safer with it in place.
2. Split `performScan` into a pure assembly function and test the §1.1 classification
   table directly.
3. Row-view reuse in `rebuildRows`.
4. The defect list in §3.2 — each is small and independent.
5. Stable signing identity in `build.sh`.
6. `SwitcherController` split (§2.2), once something new needs to go in that file.
