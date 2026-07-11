# Integration note — folding the experiments into `ClickThroughEngine`

Recommendation once `spike/RESULTS.md` is filled in. All three experiments are
independent wins; the target end-state combines them as
`--focus=slps --post=pid --cursor=move`, with graceful fallbacks so nothing regresses
on a future macOS or on renderer-side input-filtering apps.

## What to fold in

1. **Experiment 1 (SLPS fast focus) — replace `activateAndWaitForKey`'s NS/AX race.**
   Add the dlsym-guarded `fastFocus(pid:wid:)` (from `clickthrough2.swift`) and call
   it in place of the `NSRunningApplication.activate` + AX-set + polling block. Keep
   the AXRaise afterward (cosmetic, matches yabai's
   `window_manager_focus_window_with_raise`). The engine's `topWindowOwnerPid`
   pre-check already runs a `CGWindowList` pass — extend it to also return the
   `CGWindowID` (or add `_AXUIElementGetWindow`, also dlsym-guarded) so `fastFocus`
   and the fields-91/92 post both have the target `wid`.

2. **Experiment 2 (deliver before raise) — invert `tryFinish` to post-to-pid.**
   On the swallowed mousedown, post `.leftMouseDown` straight to the target pid with
   fields 91/92 set, immediately, and run activation in parallel as a cosmetic raise.
   Post `.leftMouseDragged`/`.leftMouseUp` to the pid as the gesture continues/ends.
   This removes the activation wait from the delivery path entirely.

3. **Experiment 3 (cursor continuity) — mutate swallowed drags.** In
   `onDragged`, instead of returning `true` (swallow → `nil`) while pending, mutate the
   event to `.mouseMoved` and let it through (return `false` after `event.type =
   .mouseMoved`). Delete the `CGWarpMouseCursorPosition(lLoc)` warp in the replay
   paths. When pid-posting is active, also post a `.leftMouseDragged` copy (fields
   91/92) to the pid per mutated event so live drag motion reaches the target.

## Fallback strategy

- **SLPS symbols missing (dlsym returns nil).** `fastFocus` returns `false`; the
  engine falls back to the existing NS/AX `activateAndWaitForKey` body. Resolve the
  symbols once at startup (`_SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`,
  `GetProcessForPID`, optional `_AXUIElementGetWindow`) and gate on a single
  `slpsAvailable` flag. No `@_silgen_name` — that would fail to *launch* if a symbol
  is absent; dlsym degrades at runtime instead. Verified on this machine: all four
  resolve via the global image handle (SkyLight is loaded transitively by AppKit), so
  no explicit `-framework SkyLight` link is required.

- **Chromium / canvas apps reject synthesized pid input.** Chrome, Electron (Slack,
  VS Code), and other renderer-filtered surfaces may ignore `CGEventPostToPid` clicks
  (first-mouse / user-activation gating). Route these through the **existing per-app
  override-rules mechanism from commit `ad21116`** (`AppPolicy` — the same map that
  already picks native vs. AX-move per bundle id). Add a click-through delivery policy
  per app:
  - default apps → `slps fast-focus + postToPid` (fast path);
  - apps flagged as input-filtering → `slps fast-focus + session replay` (post to
    `.cgSessionEventTap` after the window is key — slower but robust), and/or the
    primer-click trick (a click at (-1,-1) posted ~5ms ahead to satisfy the
    user-activation gate). Seed the flag for known Chromium bundle ids; let
    `AppPolicy.record` learn others if the spike shows the pid path silently failing
    for them (same learn-on-failure pattern the move probe already uses).

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
