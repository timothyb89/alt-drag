# Alt-Drag

Linux-style **alt-drag** window management for macOS: hold a modifier and drag
anywhere in a window to **move** it (left button) or **resize** it (right
button) — without releasing the perfect, native feel of a title-bar drag.

It also adds **instant workspace switching**: hold the same modifier and either
3-finger-swipe or press Tab to flip between spaces with no slide animation, and
optional **click-through / drag-through** to stop macOS eating the first click on
an inactive window.

Most existing tools reimplement window dragging by setting the window's position
frame-by-frame, which loses snapping, alignment guides, tiling drop-zones, and
gets janky across monitors. Alt-Drag avoids that by **remapping input onto the
window management macOS already ships**, falling back to the Accessibility API
only where it must (resize, which has no native gesture).

> [!WARNING]
> This project was entirely implemented by Claude Opus 4.8. It was tested
> manually, but use at your own risk.

## How it works

### Move (left drag) — native gesture remap
macOS has a built-in "drag window from anywhere" gesture (**Control+Command+
drag**), enabled by the `NSWindowShouldDragOnGesture` default. It's the *real*
title-bar drag, so it inherits everything: window/edge snapping, alignment
guides, tiling, and correct multi-monitor behavior.

Alt-Drag installs a session-level `CGEventTap` and, while you hold the trigger
modifier and drag with the left button, **rewrites the event's modifier flags**
(strip the trigger, add Ctrl+Cmd) so the window server performs its own native
move. We never identify or reposition a window ourselves — the OS does the real
thing.

### Resize (right drag) — Accessibility fallback
There is no native "resize from the window interior" gesture to remap onto, so
resize is reimplemented via the Accessibility API:

- On right-mouse-down, find the window under the cursor and pick the corner from
  the cursor's quadrant (KDE/Linux convention).
- A **worker thread** applies `kAXPosition`/`kAXSize` toward the *newest* cursor
  position only, dropping intermediate points. This coalescing is essential: an
  AX set is a synchronous IPC round-trip (tens of ms under layout), so applying
  one per drag event at 120Hz backlogs badly.
- **Latched snapping** matches the native feel: an edge tracks the cursor 1:1,
  sticks when it crosses a neighbor window's edge or a screen edge, and releases
  only after overshooting by a threshold — no magnetic pull on approach.
- The **menu bar is a hard wall** for the top edge (AX otherwise refuses the
  above-menu-bar origin but still grows the height downward).

### Instant workspace switching — native gesture remap
macOS's own space-switch animation is slow and scales with refresh rate. Alt-Drag
adds an instant switch, **gated behind the trigger modifier**: hold the modifier
and either 3-finger-swipe or press Tab to open an overlay of the current
display's spaces, scrub between them, and land the moment you release.

Same philosophy as the move: it doesn't reimplement spaces, it **remaps onto the
native gesture**. The switch is a synthesized Dock-swipe posted at an extreme
velocity, which drives the WindowServer's *own* space change while skipping the
slide animation — **no SIP disabling, no Dock injection**. Space state (count +
current index, per display) is read through the read-only private CGS API, and
the real trackpad swipe is intercepted via CGS gesture events (told apart from
our synthetic posts by source pid) so the OS doesn't *also* switch.

- **Any desktop in one motion** — the swipe maps absolutely across the display's
  spaces (sensitivity configurable), so a single gesture can reach any space.
- **Per-monitor** — targets the display under the cursor.
- **Haptics** — a detent per space via the private `MTActuator` API, which
  (unlike `NSHapticFeedbackManager`) drives external Magic Trackpads too; falls
  back to `NSHapticFeedbackManager` when unavailable.
- **Keyboard path** — modifier+Tab (Shift+Tab / arrows to move, Esc to cancel).
  Auto-disabled when the trigger is Command, so it doesn't shadow ⌘-Tab.
- The overlay shows numbered placeholders; live previews of other spaces aren't
  available from macOS (see limitations).

### Click-through & drag-through — swallow, activate, re-post
By default macOS discards the first click on an inactive window: it's used only
to activate, and the `mouseDown` is dropped unless the hit view overrides
`acceptsFirstMouse:`. That decision happens **in the target app's AppKit,
per-view**, so a session-level event tap can't observe whether a click was
eaten — only that it landed on a window that isn't focused.

So Alt-Drag doesn't try to detect an eaten click. On a modifier-free left press
on a **background** window it **swallows** the press, activates the window
itself, and **re-posts** the gesture. Because the original is swallowed, the
re-post is immune to double-actuation regardless of the view's
`acceptsFirstMouse:` (eaten view: 0→1; accepting view: 1→1 — never 2). Since the
click/drag distinction isn't known at mouse-down, it always intercepts, then
routes on **resolution**, gated by two independent toggles:

- **Drag-through** — a press that becomes a drag **hands off to a live native
  drag** the moment the window is focused, so e.g. text selection in an inactive
  window tracks live. The activation latency hides under the pointer motion.
- **Click-through** — a press that resolves as a click is re-posted after
  activation so it **actuates on the single click** instead of being wasted.

When a toggle is **off**, that path reproduces native behavior instead (the
first click just focuses + is eaten), so *drag-only* leaves clicks completely
native — no added latency — which is why it's the lower-downside default choice.

The residual cost is honest and unavoidable: a click can only actuate once its
window is **key**, which requires the app to be **frontmost**, a ~50 ms
WindowServer activation floor. Spikes confirmed `NSWorkspace.frontmostApplication`
and the system-wide AX focused app flip together (no ordering slack), and that
injecting synthetic motion to mask a click's wait fights the OS — so click-through
removes the wasted *second* click but can't make the first one instant on a slow
app (Chrome/Slack/Electron). Drags don't have this tell because pointer tracking
is decoupled from key-window state.

Per-app **Disabled** rules (see App Rules) suppress click-through too, and our own
re-posted events are tagged so the tap ignores them.

## Prerequisites

Alt-Drag detects but (by design) never changes these itself. The menu-bar
**Setup** section shows their status and offers copy-to-clipboard fix commands.

1. **Accessibility access** — required for the event tap and AX resize.
   System Settings → Privacy & Security → Accessibility → enable Alt-Drag.
2. **Native drag gesture** — enables the Ctrl+Cmd move the app remaps onto:
   ```
   defaults write -g NSWindowShouldDragOnGesture -bool true
   ```
   (Apps must be relaunched to pick it up.)
3. **Forced-tiling accelerator off** — otherwise holding the modifier while
   dragging triggers macOS's eager half-screen tiling:
   ```
   defaults write com.apple.WindowManager EnableTilingOptionAccelerator -bool false && killall WindowManager
   ```

## Build & run

```sh
cd app
./scripts/setup-signing.sh   # once: creates a stable local signing identity
./build.sh                   # builds and signs build/Alt-Drag.app
open build/Alt-Drag.app
```

Requires the full Xcode toolchain (the standalone Command Line Tools ship a
broken `SwiftBridging` modulemap; `build.sh` sets `DEVELOPER_DIR` to Xcode).

### Signing

Accessibility grants are tied to the app's code signature. Ad-hoc signatures
change every build and drop the grant, so `setup-signing.sh` creates a stable
self-signed identity (`AltDrag Local Signing`) in a dedicated keychain, and
`build.sh` signs with it. The designated requirement is certificate-based, so
the grant survives rebuilds. Override with `ALTDRAG_SIGN_IDENTITY`.

## Move fallback & per-app rules

Some apps ignore the native drag gesture (e.g. System Settings, Chrome's
vertical tab bar). Because the move remap injects Ctrl+Cmd, an app that doesn't
consume the gesture receives a **Ctrl+click** — which macOS treats as a
secondary click, popping a context menu instead of dragging.

For those, Alt-Drag falls back to an **AX-based move** (same technique as
resize; no snapping). Routing is decided per app:

- A small seeded list of known offenders (System Settings) uses the fallback
  from the start.
- Otherwise Alt-Drag tries the native gesture and **probes** whether the window
  actually moved. An app that *never* moves (failures with zero successes) is
  auto-learned into a fallback rule. Apps that work even sometimes (Chrome from
  its title bar) stay native.

Rules are managed under **App Rules** in the menu. Each app can be:

- *unset* — default (native, with auto-learn probing),
- **Fallback** — force the AX move, or
- **Disabled** — Alt-Drag ignores the app entirely (its own Option-drag returns).

Auto-learned rules are tagged `(auto)` and can be individually edited or removed.

## Menu-bar options

- **Enabled** — pause/resume the move/resize gestures without quitting.
- **Trigger** — choose the modifier (Option, Command, Control, Option+Shift).
  This modifier gates the workspace switch too.
- **Launch at Login** — register via `SMAppService`.
- **Click-Through** (both off by default)
  - **Click-Through** — re-post an eaten background click so it actuates on the
    first click (adds ~one activation of latency on slow apps).
  - **Drag-Through** — hand a background drag off to a live native drag; leaves
    clicks fully native. Lower-downside; enable this alone for drags only.
- **Workspace Switch**
  - **Instant Switch Gesture** — enable/disable the workspace switch.
  - **Swipe Sensitivity** — how much of a swipe spans all desktops (High/Medium/Low).
  - **Haptic Feedback** — a detent per space crossed.
- **App Rules** — per-app move fallback / disable overrides (see above).
- **Setup** — live status + fixes for the three prerequisites above.

## Layout

```
app/            the menu-bar app
  Sources/      Swift sources (see AppDelegate, EventTapController, ResizeEngine,
                ClickThroughEngine, WorkspaceSwitcher) plus the C core
                (spacecore.c) + bridging header
  scripts/      setup-signing.sh
  build.sh      compile + bundle + sign
  Info.plist
spike/          throwaway validation spikes (move, resize, spaces, overlay,
                haptics, clickthrough) — reference only
```

## Known limitations

- Routing is per-app, so an app that honors the gesture on most surfaces but not
  one (Chrome's vertical tab bar) keeps native everywhere and that one surface
  still leaks a context menu. Per-surface fallback isn't implemented.
- Resize on very heavy apps (e.g. Slack) lags — this mirrors the native resize,
  which is also slow there.
- The AX move fallback has no window/edge snapping (the native path does).
- Click-through can't make the *first* click on a slow-to-activate app (Chrome,
  Slack, Electron) instant — the ~50 ms app-activation floor is a WindowServer
  cost with no ordering slack. It removes the wasted second click, not the wait.
- Click-through only fixes clicks that cross *apps*; a click on a non-key window
  of the already-active app takes the cheap pass-through path and stays native.
- On activation timeout (a window that never reports focused) a click-through
  press is delivered anyway but may be lost, degrading to native (one wasted
  click). Rare; set a per-app Disabled rule for a persistent offender.
- The workspace overlay shows numbered placeholders, not live space previews:
  macOS doesn't render off-screen spaces, so their windows can't be captured.
- Workspace haptics on external trackpads use the private `MTActuator` API and
  are relatively weak; the available actuation patterns feel similar on some
  devices (e.g. Magic Trackpad 2).
- The workspace switch relies on undocumented CGEvent fields and private CGS /
  MultitouchSupport symbols, which may drift across macOS releases (they
  degrade gracefully rather than crash).
