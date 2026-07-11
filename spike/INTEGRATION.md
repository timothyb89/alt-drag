# Integration note — folding the experiments into `ClickThroughEngine`

Recommendation, updated after the first test run (see `spike/RESULTS.md`). Key
empirical facts now established:

- SLPS fast focus works: activation 1–20ms vs 40–185ms for the NS/AX race.
- `CGEventPostToPid` alone does NOT bypass first-mouse: fields 91/92 fix the
  routing, but AppKit applies the first-mouse rule at dispatch time from the app's
  active state, so a down posted before activation is discarded app-side (dead
  clicks in Finder, Chrome, and Electron alike).

**Recommended architecture** (the `--focus=slps --post=pid --cursor=move`
combination, with the run-1 correction):

> synchronous SLPS make-key (~1-2ms, in the tap callback) → postToPid the down
> (fields 91/92 set) → cosmetic AXRaise trailing async.

Event-queue ordering does the sequencing — the make-key records precede the
mousedown in the target's queue, so by dispatch time the app is active and
first-mouse no longer applies. No polling wait anywhere on the delivery path.
Graceful fallbacks (below) so nothing regresses on a future macOS or on
renderer-side input-filtering apps.

## What to fold in

1. **Experiment 1 (SLPS fast focus) — replace `activateAndWaitForKey`'s NS/AX race.**
   Add the dlsym-guarded `fastFocus(pid:wid:)` (from `clickthrough2.swift`) and call
   it in place of the `NSRunningApplication.activate` + AX-set + polling block. Keep
   the AXRaise afterward (cosmetic, matches yabai's
   `window_manager_focus_window_with_raise`). The engine's `topWindowOwnerPid`
   pre-check already runs a `CGWindowList` pass — extend it to also return the
   `CGWindowID` (or add `_AXUIElementGetWindow`, also dlsym-guarded) so `fastFocus`
   and the fields-91/92 post both have the target `wid`.

2. **Experiment 2 (deliver before raise) — post-to-pid, sequenced AFTER make-key.**
   On the swallowed mousedown: call `fastFocus` synchronously, then post
   `.leftMouseDown` to the target pid with fields 91/92 set (~1-2ms total), with the
   AXRaise trailing async. Post `.leftMouseDragged`/`.leftMouseUp` to the pid as the
   gesture continues/ends. Do NOT post before the app is active — run 1 proved those
   events are eaten as first-mouse regardless of the routing fields. This still
   removes the entire polling wait from the delivery path; the sequencing cost is
   the ~1-2ms synchronous make-key.

3. **Experiment 3 (cursor continuity) — mutate swallowed drags.** In
   `onDragged`, instead of returning `true` (swallow → `nil`) while pending, mutate the
   event to `.mouseMoved` and let it through (return `false` after `event.type =
   .mouseMoved`). Delete the `CGWarpMouseCursorPosition(lLoc)` warp in the replay
   paths. When pid-posting is active, also post a `.leftMouseDragged` copy (fields
   91/92) to the pid per mutated event so live drag motion reaches the target.

## Fallback strategy

- **SLPS symbols missing (dlsym returns nil).** `fastFocus` returns `false`; the
  engine degrades to **activate-then-post**: fire the existing NS/AX
  `activateAndWaitForKey` activators and hold the pid-post until a front signal
  confirms (this is `clickthrough2.swift`'s nsax sequencing — the down is deferred
  via the activation poll's onFront hook, and any drag/up posts queue behind it on
  the serial worker so the stream stays ordered). Slower (one activation wait) but
  correct. Resolve the symbols once at startup
  (`_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`, `GetProcessForPID`,
  optional `_AXUIElementGetWindow`) and gate on a single `slpsAvailable` flag. No
  `@_silgen_name` — that would fail to *launch* if a symbol is absent; dlsym degrades
  at runtime instead. Verified on this machine: all four resolve via the global image
  handle (SkyLight is loaded transitively by AppKit), so no explicit
  `-framework SkyLight` link is required.

- **Chromium / canvas apps reject synthesized pid input.** Even with correct
  sequencing, Chrome, Electron (Slack, VS Code), and other renderer-filtered surfaces
  may still ignore `CGEventPostToPid` clicks (renderer-side user-activation gating —
  distinct from the first-mouse issue, which sequencing fixes; the 2b re-run tells us
  whether this materialises). Route these through the **existing per-app
  override-rules mechanism from commit `ad21116`** (`AppPolicy` — the same map that
  already picks native vs. AX-move per bundle id). Add a click-through delivery policy
  per app:
  - default apps → `sync slps make-key + postToPid` (fast path);
  - apps flagged as input-filtering → `slps fast-focus + session replay` (post to
    `.cgSessionEventTap` after the window is key — slower but robust), and/or the
    primer-click trick (now the spike's `--primer` flag: a click at (-1,-1) pid-posted
    ~5ms ahead to satisfy the user-activation gate). Seed the flag for known Chromium
    bundle ids; let `AppPolicy.record` learn others if the spike shows the pid path
    silently failing for them (same learn-on-failure pattern the move probe already
    uses).

- **Occluded / cross-Space targets.** Fields 91/92 route the pid-posted event to the
  hit-tested window even when occluded (prove this in the Experiment 2 matrix). Watch
  `_SLPSSetFrontProcessWithOptions` for unwanted Space jumps on windows that live on
  another Space/display; if observed, guard fast-focus to same-Space targets and fall
  back to NS/AX for off-Space windows.

## Order of integration

Land Experiment 3 first (self-contained, no private APIs, immediate feel win), then
Experiment 1 (biggest latency drop, dlsym-guarded), then Experiment 2 (largest
architectural change — do it behind the `AppPolicy` per-app switch so Chromium can opt
back to the session-replay path). Keep `spike/clickthrough2.swift`'s default flags
(`nsax/session/freeze`) as the regression baseline while iterating.
