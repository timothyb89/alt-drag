# Click-through latency experiments

Goal: eliminate the two perceived-latency problems in the click-through feature
(`app/Sources/ClickThroughEngine.swift`):

1. **Cursor freeze** — while activation is pending, `leftMouseDragged` events are
   swallowed by the tap (`EventTapController.swift:144`, `ClickThroughEngine.onDragged`),
   which pins the pointer for the 30–200ms activation wait, then warps it.
2. **Click-after-raise lag** — the replayed click posts to `.cgSessionEventTap`, which
   routes through window-server z-order hit-testing, so the window must be raised and
   key *before* the click can be delivered. The user perceives the click landing late.

Both are addressable with SIP fully enabled. Three independent experiments, in order of
expected payoff / risk. Each should be a toggleable mode in a spike binary (extend
`spike/clickthrough.swift` or create `spike/clickthrough2.swift`), keeping the existing
log format and timing instrumentation so results are comparable to the baseline log.

---

## Experiment 1 — SLPS fast focus (replace `activateAndWaitForKey`)

Replace the `NSRunningApplication.activate` + AX raise + polling race with the private
SkyLight calls that AltTab and yabai use to make a specific window key near-synchronously.
This alone should collapse the 40–200ms `ns-led` tail to single-digit ms.

### Declarations (Swift)

```swift
@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber,
                                     _ wid: UInt32, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber,
                           _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

// Carbon; deprecated but functional — pid -> PSN
@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

let kCPSUserGenerated: UInt32 = 0x200
```

Link against SkyLight: `-F /System/Library/PrivateFrameworks -framework SkyLight`
(or rely on it being loaded transitively via AppKit — verify at runtime; if the symbols
resolve without the explicit framework flag, prefer that).

### Sequence (per yabai `src/window_manager.c` `window_manager_focus_window_with_raise` /
`window_manager_make_key_window`, and AltTab's `HelperExtras`)

```swift
func makeKeyWindow(psn: inout ProcessSerialNumber, wid: UInt32) {
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: UInt32(wid).littleEndian) { src in
        for i in 0..<4 { bytes[0x3c + i] = src[i] }
    }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes)
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes)
}

func fastFocus(pid: pid_t, wid: UInt32) {
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return }
    _ = _SLPSSetFrontProcessWithOptions(&psn, wid, kCPSUserGenerated)
    makeKeyWindow(psn: &psn, wid: wid)
}
```

> The exact byte offsets are load-bearing and version-sensitive. Before relying on them,
> cross-check against current yabai master (`window_manager.c`) and AltTab source; if they
> differ from the above, trust the upstream projects. Also perform the AXRaise afterward
> (async, cosmetic) — SLPS makes the window *key* but raise ordering should still be
> confirmed visually.

### Measurement

Keep the existing `activated in X ms` log line. Add a mode flag (e.g. `--focus=slps` vs
`--focus=nsax`) and record which signal confirmed frontmost. Success: p95 activation
< 10ms across the same target apps as the baseline log (native app, Chrome, a third app).

### Risks

- Private API: symbol lookup can fail on a future macOS — guard with `dlsym` checks and
  fall back to the existing NS/AX path.
- Space-switching side effects: `_SLPSSetFrontProcessWithOptions` reparents onto the
  current Space in some modes — verify no unwanted Space jumps with windows on other
  Spaces/displays.

---

## Experiment 2 — deliver the click before the raise (`CGEventPostToPid`)

Invert the architecture: instead of *swallow → wait for activation → replay*, do
*swallow → post the mousedown directly to the target pid immediately → activate in
parallel (cosmetic raise)*. `CGEventPostToPid` (public, macOS 10.11+) bypasses
window-server z-order routing entirely; the app's own `sendEvent` dispatches it.

### Targeting a specific (possibly occluded) window

Set both window fields on every posted event so AppKit routes to the hit-tested window
rather than whatever it thinks is under the pointer:

```swift
ev.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(wid))                    // field 91
ev.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(wid)) // field 92
```

(Both are public in `CGEventTypes.h`. The engine already has the target `CGWindowID`
from its CGWindowList pre-check.)

Keep setting `.mouseEventClickState` and the `kClickThroughTag` user-data tag as the
current `post()` helper does. Note pid-posted events do not re-enter the session tap,
so the tag is belt-and-braces here.

### What to test (the open empirical question)

Does AppKit still apply first-mouse swallowing to pid-posted events while the app is
inactive? Test matrix, clicking a button/tab while the app is unfocused:

| Target | Expectation | Notes |
|---|---|---|
| Native AppKit app (Finder, System Settings, Xcode) | should work | core case |
| Safari (native WebKit) | should work | |
| Chrome / Chromium browser | may reject synthesized input | known renderer-side filtering; if clicks are ignored, try a primer click at (-1,-1) posted to the pid ~5ms before the real one (user-activation gate trick), and/or run Experiment 1's fast-focus *first* then post |
| Electron app (Slack, VS Code) | uncertain | Chromium-derived |
| Occluded window (target behind another window of the same app, and behind another app) | fields 91/92 should route correctly | this is the "impossible" case worth proving |

If inactive-app delivery is swallowed as first-mouse, the fallback composition is still a
big win: **Experiment 1 fast-focus (~3ms) → postToPid immediately** — no polling wait at
all, click perceived as instant.

### Mode flag

`--post=pid` vs `--post=session` (current behavior). Log line should record delivery
latency from hardware mousedown timestamp to post, and whether the target visibly
reacted (manual observation column in results).

---

## Experiment 3 — cursor continuity (drag → mouseMoved mutation)

Independent of 1 and 2; do it regardless. While a gesture is pending activation, the tap
currently returns `nil` for `leftMouseDragged`, which drops the pointer motion.

Instead, **mutate the event in the tap callback and return it**:

```swift
// in the tap callback, pending-activation branch:
event.type = .mouseMoved   // via CGEventSetType
return Unmanaged.passRetained(event)  // (match existing callback memory conventions)
```

A `mouseMoved` carries the pointer motion (cursor keeps gliding) but no app interprets
it as part of a drag gesture. The target app still receives a coherent
`down → drag → up` stream from the replay/handoff path. Delete the
`CGWarpMouseCursorPosition(lLoc)` warp in the replayed paths — the pointer is already
where it should be.

If Experiment 2 is active, additionally post a `leftMouseDragged` copy (fields 91/92 set)
to the target pid for each mutated event, so live drag motion reaches the target with no
handoff discontinuity.

Watch for: hover side effects in the *frontmost* app from the injected `mouseMoved`
stream (tooltips, hover highlights). Expected to be benign but verify.

---

## Deliverables

1. Spike binary with the three mode flags, buildable via the same invocation as the
   existing spike (see how `spike/clickthrough.swift` is compiled — likely
   `swiftc -O spike/clickthrough.swift -o ...`; replicate).
2. A results table template (`spike/RESULTS.md`) for the manual test matrix above.
3. A short integration note: which combination to fold into `ClickThroughEngine`, with
   per-app fallback via the existing override-rules mechanism (commit ad21116) for
   Chromium/canvas apps, and `dlsym`-guarded fallback to the NS/AX path when SLPS
   symbols are missing.

## Non-goals

- No SIP-disabled techniques, no code injection, no scripting additions.
- Don't touch the shipped `ClickThroughEngine` yet — spike first, integrate after the
  results table is filled in.
