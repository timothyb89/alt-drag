# Integration note — folding the experiments into `ClickThroughEngine`

## Integrated on 2026-07-10

The recommended architecture below landed in `app/Sources` (ClickThroughEngine
rewritten; AppPolicy/Settings/EventTapController touched lightly):

- **SLPS fast focus** ported (dlsym-guarded, yabai byte-layout comments kept);
  missing symbols degrade per-gesture to the previous NS/AX `activateAndWaitForKey`
  race, feeding the same delivery funnel.
- **session-fast delivery with raise-confirm DEFAULT ON**: sync make-key in the tap
  callback, then a point-scoped z-order spin on the worker (1ms steps, default cap
  40ms — covers the observed Chromium 9-14ms raises with headroom), then the down is
  re-posted to the session tap and the gesture goes live. No ns/ax polling anywhere
  on the delivery path. The spin runs on the worker (the spike ran it on the tap
  thread) so the tap callback stays ~1-2ms; pending drags cover the gap as mouseMoved.
- **Cap tunable per app** via the existing override-rules storage: `AppOverride`
  gained an optional `raiseCapMs` (old persisted rules decode unchanged;
  `AppOverride.state` became optional so a cap can exist without a routing rule),
  read through `AppPolicy.raiseConfirmCapMs(bundleId:)`, settable via
  `Settings.setRaiseCap`. No seeded Chromium rules: the 40ms default already covers
  them (the spike's Chrome misses came from its 10ms cap).
- **Cursor continuity**: pending drags mutate to `mouseMoved` and pass through; both
  `CGWarpMouseCursorPosition` warps deleted (no path freezes the pointer anymore).
- **Cold-start fixes**: `ClickThroughEngine.prewarm()` (called from
  `EventTapController.start()`) absorbs the lazy first-call costs — AX connection
  spin-up, first CGWindowList, first CGEvent from the source, dlsym resolution,
  NSWorkspace — off the tap thread, so the first gesture's down handler can't stall
  into the tap timeout (the stuck-drag / cursor-snap first-click bugs).
- **Deliberate semantic change**: with click-through ON and drag-through OFF, a
  background drag is now live (the window is key within ~10ms, so the native
  consequence of the remaining hardware drag IS a live drag); the old "eaten drag"
  reproduction only existed because activation used to take 50-200ms.
- **Not ported** (per the findings): pid/sl/ax delivery modes, `--primer`, the
  instrumentation ns/ax polling, and all spike logging.

---

Recommendation, updated after runs 1–3 (see `spike/RESULTS.md`). Key empirical facts:

- **SLPS fast focus works**: activation 1–20ms vs 40–185ms for the NS/AX race, and it
  is window-scoped — expected to avoid nsax's app-scoped side effects (Space yanks,
  extra windows raised; user's run-1 notes).
- **Direct pid delivery is a DEAD END for mouse clicks** — proven at the receiver
  (`spike/eventprobe.swift`): `CGEventPostToPid` and `SLEventPostToPid` mouse events
  DO reach `NSApplication.sendEvent`, but with `windowNumber=0`. Mouse events are
  bound to a window BY THE WINDOW SERVER as they pass through it; pid posting skips
  the server, and AppKit drops window-less mouse events before any view sees them.
  Fields 91/92 are inert metadata (readable on arrival, ignored for dispatch). Raw
  CGEvent field 51 does carry the windowNumber and binds the NSEvent, but the event
  record's separate `windowLocation` member cannot be set through the CGEvent field
  API (fields 51–90 scanned exhaustively, int and double, plus connection-id combos)
  — the hit-test location stays at the window's top-left and nothing actuates.
  Keyboard events get bound by AppKit itself (key window), which is why the folklore
  says postToPid works for keyboard only.
- **Session-posted events bind fully and actuate — even in an inactive app** (the
  eventprobe control click actuated with zero activation). Session delivery is a real
  window-server-routed click; there is no separate "Chromium rejects synthesized
  input" failure mode to design around on this path.

**Recommended architecture** (`--focus=slps --post=session-fast --cursor=move`):

> synchronous SLPS make-key (~1-2ms, in the tap callback) → post the down to the
> SESSION tap immediately (no ns/ax poll wait — the poll lags the real focus flip by
> 50–70ms) → the rest of the hardware gesture flows natively (live handoff) →
> cosmetic AXRaise + confirmation polling trail async, instrumentation only.

Expected end-to-end delivery ~2–6ms, one coherent native `down→drag→up` stream, no
cursor freeze, no warp. If field testing shows early samples landing in the OLD
frontmost window (z-order flip not yet landed server-side when the session post
hit-tests), enable the raise-confirm spin — poll the point-scoped CGWindowList
z-order check up to ~10ms before posting (already implemented behind `--raise-wait`;
the RESULTS table records whether it was needed).

**Optional zero-raise fast path** (`--post=ax`): when the AX element under the cursor
lists `AXPress` in its actions, actuate via `AXUIElementPerformAction` with no
activation, no raise, nothing — the only true "click without raising anything" path.
Pressable controls only (buttons/tabs); falls back to session-fast otherwise. Fold in
only if the RESULTS table shows it reliable per-app, gated by the override-rules
mechanism.

## What to fold in

1. **SLPS fast focus — replace `activateAndWaitForKey`'s NS/AX race.** Add the
   dlsym-guarded `fastFocus(pid:wid:)` (from `clickthrough2.swift`) and call it
   synchronously in `onDown` for click-through gestures. Keep the AXRaise afterward
   (cosmetic, matches yabai's `window_manager_focus_window_with_raise`, async). The
   engine's `topWindowOwnerPid` pre-check already runs a `CGWindowList` pass — extend
   it to also return the `CGWindowID` (or add `_AXUIElementGetWindow`, also
   dlsym-guarded) so `fastFocus` has the target `wid`.

2. **session-fast delivery — invert `tryFinish`'s wait-then-replay.** On the
   swallowed mousedown: `fastFocus` synchronously, then immediately re-post the down
   to `.cgSessionEventTap` (the existing `post()` helper, kClickThroughTag intact)
   and flip the gesture to the existing `liveDragging` state so the real hardware
   drags/up flow through natively. Delete the polling wait from the delivery path
   entirely; keep a trailing async confirm for telemetry. Optionally the ~10ms
   point-scoped raise-confirm spin (see above) if testing demands it.

3. **Cursor continuity — mutate swallowed drags.** With session-fast the down is
   live within ~5ms, so freezes mostly disappear; for the residual pending window
   (and any degraded path), mutate pending `leftMouseDragged` events to `.mouseMoved`
   in `onDragged` and let them through instead of swallowing. Delete the
   `CGWarpMouseCursorPosition(lLoc)` warp in the replay paths.

## Fallback strategy

- **SLPS symbols missing (dlsym returns nil).** `fastFocus` returns `false`; the
  engine degrades to the CURRENT shipped behaviour — NS/AX `activateAndWaitForKey`
  then session replay. Slower (one activation wait) but identical to today, so no
  regression. Resolve the symbols once at startup (`_SLPSSetFrontProcessWithOptions`,
  `SLPSPostEventRecordTo`, `GetProcessForPID`, optional `_AXUIElementGetWindow`) and
  gate on a single `slpsAvailable` flag. No `@_silgen_name` — that would fail to
  *launch* if a symbol is absent; dlsym degrades at runtime instead. Verified on this
  machine: all resolve via the global image handle (SkyLight loads transitively via
  AppKit), no explicit `-framework SkyLight` link needed. (`SLEventPostToPid` also
  resolves but is not part of the plan — dead end, see above.)

- **Per-app overrides via the existing rules mechanism (commit `ad21116`,
  `AppPolicy`).** With session-fast the delivery path is a real session click, so the
  anticipated Chromium pid-delivery fallback is moot. Keep the per-app hook for:
  - apps where the *make-key-then-instant-post* ordering misbehaves → flag them to
    add the raise-confirm spin, or fall back to the full wait-then-replay path;
  - apps where `--post=ax` (if adopted) should be disabled or preferred;
  - the existing "Disabled" rule (already respected by `onDown`).
  Let `AppPolicy.record` learn misbehaving apps the same way the move probe does.

- **Occluded / cross-Space targets.** Session posting hit-tests the CURRENT z-order,
  so the target must be raised before the post lands — this is exactly what the
  make-key + optional raise-spin provides; verify with the occluded row of the
  session-fast table. Watch `_SLPSSetFrontProcessWithOptions` for unwanted Space
  jumps (user's A/B table); if observed, guard fast-focus to same-Space targets and
  fall back to NS/AX for off-Space windows.

## Order of integration

Land cursor continuity first (self-contained, no private APIs, immediate feel win),
then SLPS fast focus (biggest latency drop, dlsym-guarded, window-scoped focus as a
bonus), then the session-fast inversion (small once fast focus is in: post
immediately instead of waiting for the poll). Do NOT integrate pid/sl delivery —
keep those spike modes only as documentation of the dead end. Keep
`spike/clickthrough2.swift`'s default flags (`nsax/session/freeze`) as the
regression baseline while iterating.
