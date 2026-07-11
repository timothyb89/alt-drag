# Click-through latency experiments — results matrix

Template for the manual test run of `spike/clickthrough2` (see `spike/EXPERIMENTS.md`
for the hypotheses and `spike/INTEGRATION.md` for the recommended fold-in). Fill the
tables in as you run. Instrumentation matches the baseline `spike/clickthrough`, so
the numbers are directly comparable.

## Build & run

```sh
./spike/build.sh                      # builds clickthrough2 alongside the others
# or standalone:
xcrun swiftc -O spike/clickthrough2.swift -o spike/clickthrough2 \
    -framework Cocoa -framework ApplicationServices
```

Run a mode, then click controls in **background** (unfocused) windows with **no
modifiers** held:

```sh
./spike/clickthrough2                                   # baseline: nsax / session / freeze
./spike/clickthrough2 --focus=slps                      # Experiment 1
./spike/clickthrough2 --cursor=move                     # Experiment 3
./spike/clickthrough2 --focus=slps --post=session-fast              # Run 3: pragmatic path
./spike/clickthrough2 --focus=slps --post=session-fast --cursor=move   # combined (recommended)
./spike/clickthrough2 --focus=slps --post=session-fast --raise-wait # if early samples misroute
./spike/clickthrough2 --post=ax                                     # zero-raise AXPress probe
./spike/clickthrough2 --focus=slps --post=pid                       # run 2 (dead; kept for record)
./spike/clickthrough2 --focus=slps --post=sl                        # run 3 (dead; kept for record)
./spike/clickthrough2 --help
```

Receiver-side delivery probe (run 3; no clicking needed — fully programmatic):

```sh
./spike/eventprobe          # prints its pid / windowNumber / --probe-* poster line
./spike/clickthrough2 --probe-pid=<pid> --probe-at=<x,y> --probe-wid=<n> \
                      [--probe-post=pid|sl|session] [--probe-scan] [--probe-scan2] \
                      [--probe-cid=<connectionId>]
```

### Accessibility permission (required)

The binary creates a session `CGEventTap`; without Accessibility it prints
`FAILED to create event tap` and exits 1. Grant it under **System Settings >
Privacy & Security > Accessibility** to the process that launches it (your terminal
— e.g. Terminal.app / iTerm — or the binary itself if you launch it from Finder).
This is the same grant the baseline spike documents in its boot log. After toggling
the permission, fully relaunch the terminal so the new binary inherits it. On first
run per binary you may need to remove+re-add the entry (TCC keys on the binary path).

### Reading the log

Same format as the baseline. Key lines (updated after run 1):

- `swallowed first-click on unfocused win (pid …, wid …) … [focus=… post=… cursor=…]`
- `posted mousedown -> pid … directly (deliver X.Xms, after slps make-key)` —
  **Experiment 2, slps sequencing**: delivery latency from hardware mousedown to the
  pid-post, with the synchronous SLPS make-key (~1-2ms) included. Expect low
  single-digit ms.
- `posted mousedown -> pid … directly (deliver X.Xms, waited for nsax activation)` —
  **Experiment 2, nsax fallback sequencing**: the down was held until a front signal
  confirmed, so this reads 40–200ms. This is the degraded path (slps missing/forced off).
- `posted PRIMER click @(-1,-1) -> pid …` — the `--primer` throwaway click.
- `activated in X.Xms [reason] (ns@… ax@… foc@… raise@…)` — activation latency +
  which signal led. `reason` is `ns-led` / `ax-led` / `front-only(grace)` / `timeout`.
  **`raise@` is new**: when the target wid became the frontmost layer-0 window per
  CGWindowList z-order. The ns/ax polls lag the real CG-side focus flip (run 1 logged
  55–76ms "ns-led" slps activations that were visually near-instant), so use `raise@`
  for "window visibly raised" and treat ns/ax as the (laggy) app-active confirmations.
- `replayed CLICK/DRAG … total X.Xms (after-up X.Xms)` — **session mode**. `total` is
  mousedown→replay and INCLUDES your physical button-hold time (the replay fires on
  mouse-up), which is why run 1 showed 100–200ms totals despite 8.7ms activations.
  **`after-up` is the real added latency** (physical mouseup → replay post); judge the
  session path on that number.
- `posted mouseup -> pid … — CLICK/DRAG delivered direct, total X.Xms` — **pid mode**
  (total includes the physical hold here too; delivery latency is the `deliver` value).

`activation ms` column = the `activated in` value. `delivery ms` column = the
`deliver` value (pid mode) or the `after-up` value (session mode). `visible reaction` =
did the control actuate / cursor glide, observed by eye.

---

## Experiment 1 — SLPS fast focus (`--focus=slps`, post=session, cursor=freeze)

Compare activation latency vs. the `nsax` baseline for the same targets. Success
target from the spec: p95 activation < 10ms.

| Target | nsax activation ms | slps activation ms | reason (slps) | Space jump? | Notes |
|---|---|---|---|---|---|
| Native app (Finder / System Settings) | 64.6 | 13.7 | ns-led | y |  |
| Xcode |  |  |  |  |  |
| Safari |  |  |  |  |  |
| Chrome / Chromium | 148 | 19.1 | ns-led | y | NSAX mode sometimes brings too many windows to the front |
| Electron (Slack / VS Code) | 69.1 | 3.9 | ns-led | y |  |
| iTerm2 | 39.2 | 31.9 | ns-led | y | |
| Window on other display (its active Space) |  |  |  |  | same-display-other-Space is unclickable, hence N/A for this feature |

> **Follow-up needed on "Space jump? y":** the table shows `y` everywhere, but this
> setup is multi-display, where clicking a window on the other display legitimately
> moves focus there — that isn't an SLPS defect. Note the clicked window is always
> on a currently-active Space of some display (you can't click what isn't rendered),
> so the clicked window itself never triggers a Space switch. The risk is that
> **activation is app-scoped while the click is window-scoped**: app-level
> activation (nsax) can (a) yank a display to the Space of the app's *other* /
> most-recently-focused window — governed by Desktop & Dock ▸ "When switching to an
> application, switch to a Space with open windows for the application" — and
> (b) raise the app's other windows across Spaces/displays (the run-1 Chrome
> "brings too many windows to front" note). SLPS targets a single window id and is
> *expected* to avoid both. A/B the SAME clicked window under `--focus=nsax` and
> `--focus=slps`; the interesting setup is an app with additional windows on
> other Spaces.

| Same-window A/B (app has windows on multiple Spaces) | nsax: Space switch / extra windows raised? | slps: Space switch / extra windows raised? | Notes |
|---|---|---|---|
| Clicked window on current Space, current display | no (?) | no | any Space change at all is spurious |
| Clicked window on other display's active Space | yes, ~33% of the time | no | focus following you there is normal; jumping to a *third* Space / raising other windows is not |

> Note on run-1 slps numbers: the 31.9–55–76ms "activations" are poll-confirmation
> lag, not focus latency — the re-run's `raise@` field separates the real raise time
> from the laggy ns/ax confirmations.

Some NSAX log samples:
```
[clickthrough] swallowed first-click on unfocused win (pid 4205, wid 1510) @(872,746) — activating [focus=nsax post=session cursor=freeze]…
[clickthrough] activated in 18.1ms [ns-led] (ns@18.1 ax@18.1 foc@18.1)  ns-ax gap=0.0ms
[clickthrough] replayed CLICK @(872,746) clickState=1  total 96.7ms
[clickthrough] swallowed first-click on unfocused win (pid 4201, wid 56985) @(1902,727) — activating [focus=nsax post=session cursor=freeze]…
[clickthrough] activated in 98.2ms [front-only(grace)] (ns@57.9 ax@— foc@3.0)
[clickthrough] replayed CLICK @(1902,727) clickState=1  total 100.0ms
[clickthrough] swallowed first-click on unfocused win (pid 4204, wid 57568) @(879,1542) — activating [focus=nsax post=session cursor=freeze]…
[clickthrough] activated in 47.9ms [ns-led] (ns@47.9 ax@— foc@4.1)
[clickthrough] replayed CLICK @(879,1542) clickState=1  total 51.0ms
[clickthrough] swallowed first-click on unfocused win (pid 4205, wid 1113) @(-341,1356) — activating [focus=nsax post=session cursor=freeze]…
[clickthrough] activated in 185.0ms [front-only(grace)] (ns@160.5 ax@142.4 foc@—)  ns-ax gap=18.1ms
[clickthrough] replayed CLICK @(-341,1356) clickState=1  total 199.5ms
```

Some SLPS log samples:
```
[clickthrough] swallowed first-click on unfocused win (pid 4201, wid 56985) @(1730,800) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 55.3ms [ns-led] (ns@55.3 ax@— foc@55.3)
[clickthrough] replayed CLICK @(1730,800) clickState=1  total 108.6ms
[clickthrough] swallowed first-click on unfocused win (pid 4205, wid 1510) @(827,707) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 56.8ms [ns-led] (ns@56.8 ax@56.8 foc@56.8)  ns-ax gap=0.0ms
[clickthrough] replayed CLICK @(827,707) clickState=1  total 188.3ms
[clickthrough] swallowed first-click on unfocused win (pid 4204, wid 57568) @(954,1367) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 1.0ms [ns-led] (ns@1.0 ax@— foc@1.0)
[clickthrough] handoff -> LIVE gesture, down@(954,1367) native from here (25.1ms)
[clickthrough] live gesture ended (native up)
[clickthrough] swallowed first-click on unfocused win (pid 4205, wid 1113) @(-523,1294) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 8.7ms [ns-led] (ns@8.7 ax@8.7 foc@8.7)  ns-ax gap=0.0ms
[clickthrough] replayed CLICK @(-523,1294) clickState=1  total 206.5ms
[clickthrough] swallowed first-click on unfocused win (pid 4201, wid 196) @(-1440,1618) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 1.5ms [ns-led] (ns@1.5 ax@— foc@1.5)
[clickthrough] handoff -> LIVE gesture, down@(-1440,1618) native from here (33.4ms)
[clickthrough] live gesture ended (native up)
[clickthrough] swallowed first-click on unfocused win (pid 4205, wid 1113) @(-311,1497) — activating [focus=slps post=session cursor=freeze]…
[clickthrough] activated in 76.0ms [ns-led] (ns@76.0 ax@76.0 foc@76.0)  ns-ax gap=0.0ms
[clickthrough] replayed CLICK @(-311,1497) clickState=1  total 200.3ms
```

## Experiment 2 — click before raise (`--post=pid`, focus=nsax, cursor=freeze)

> **HYPOTHESIS ANSWERED (run 1): first-mouse IS applied to pid-posted events while
> the app is inactive.** Events were delivered (deliver@~1ms) and fields 91/92 routed
> them to the right window, but no control actuated anywhere — Finder, Chrome,
> Electron all dead clicks. Both down AND up were dispatched while the target was
> still inactive (activation confirmed 60–190ms later; e.g. Chrome: down@0.8ms,
> up@55.3ms, activated@93.6ms), and AppKit's first-mouse rule discarded them
> app-side at dispatch time. Posting to the pid bypasses window-server routing, not
> the first-mouse check. **Fix: slps-first sequencing** — the spike now synchronously
> makes the window key (~1-2ms) BEFORE posting the down, so the make-key records
> precede the mousedown in the target's event queue; re-run as Experiment 2b below.
> (Run-1 data preserved in the table below for the record.)

| Target | delivery ms (deliver→post) | control actuated? | fields 91/92 routed correctly? | Notes |
|---|---|---|---|---|
| Native app (Finder / System Settings / Xcode) | 83.9 | n |  | core case, "should work" |
| Safari (native WebKit) |  |  |  |  |
| Chrome / Chromium |  | n |  | may reject synthesized input; see primer-click note |
| Electron (Slack / VS Code) |  | n |  | Chromium-derived, uncertain |
| Occluded: target behind another window of same app |  |  |  | the "impossible" case |
| Occluded: target behind another app's window |  |  |  | fields 91/92 must route |

Chromium fallback probes (only if Chrome/Electron ignores the click):
- [ ] primer click at (-1,-1) posted to the pid ~5ms before the real one — now
      implemented as the `--primer` flag
- [x] run `--focus=slps` fast-focus first, THEN post (`--focus=slps --post=pid`) —
      now the default sequencing whenever slps is available; see Experiment 2b

Log sample from clicking between spaces to a Finder window:
```
[clickthrough] swallowed first-click on unfocused win (pid 4218, wid 94514) @(2458,261) — activating [focus=nsax post=pid cursor=freeze]…
[clickthrough] posted mousedown -> pid 4218 (wid 94514) directly (deliver 1.1ms) — activation is cosmetic
[clickthrough] activated in 61.4ms [ns-led] (ns@61.4 ax@61.4 foc@7.0)  ns-ax gap=0.0ms
[clickthrough] posted mouseup -> pid 4218 (wid 94514) — CLICK delivered direct, total 89.3ms
```

And one to a Chrome window:
```
[clickthrough] swallowed first-click on unfocused win (pid 4201, wid 56985) @(1204,619) — activating [focus=nsax post=pid cursor=freeze]…
[clickthrough] posted mousedown -> pid 4201 (wid 56985) directly (deliver 0.8ms) — activation is cosmetic
[clickthrough] posted mouseup -> pid 4201 (wid 56985) — CLICK delivered direct, total 55.3ms
[clickthrough] activated in 93.6ms [ns-led] (ns@93.6 ax@— foc@3.7)
```

## Experiment 2b — re-run with slps-first sequencing (`--focus=slps --post=pid`)

The down is now posted immediately AFTER a synchronous SLPS make-key (~1-2ms), so the
app is active by dispatch time and first-mouse should no longer apply. Look for
`posted mousedown -> … (deliver X.Xms, after slps make-key)` in the log; delivery
should stay low single-digit ms.

| Target | delivery ms (after slps make-key) | control actuated? | raise@ ms | Notes |
|---|---|---|---|---|
| Native app (Finder / System Settings / Xcode) | 9.8 | n | `-` (?) | core case |
| Safari (native WebKit) |  |  |  |  |
| Chrome / Chromium |  | n |  | if dead, retry with `--primer` |
| Electron (Slack / VS Code) |  | n |  | if dead, retry with `--primer` |
| Occluded: target behind another window of same app |  |  |  | the "impossible" case |
| Occluded: target behind another app's window |  |  |  | fields 91/92 must route |

Finder click attempt log:
```
[clickthrough] swallowed first-click on unfocused win (pid 4218, wid 94514) @(2199,322) — activating [focus=slps post=pid cursor=freeze]…
[clickthrough] posted mousedown -> pid 4218 (wid 94514) directly (deliver 9.8ms, after slps make-key)
[clickthrough] activated in 5.2ms [ns-led] (ns@5.2 ax@5.2 foc@5.2 raise@—)  ns-ax gap=0.0ms
[clickthrough] posted mouseup -> pid 4218 (wid 94514) — CLICK delivered direct, total 70.0ms
```

With `--primer` (only rows that failed above):

| Target | actuated with --primer? | Notes |
|---|---|---|
| Chrome / Chromium | n |  |
| Electron (Slack / VS Code) | n |  |

> **RUN-2 VERDICT: first-mouse theory FALSIFIED.** The Finder log above shows the app
> provably active at dispatch time (ns/ax/foc all @5.2ms, down posted at 9.8ms) and
> the click still dead — in native and Chromium apps alike, primer or not. The
> pid-delivery failure is not an activation-state problem. See Run 3.

## Run 3 — delivery mechanics, measured at the receiver (spike/eventprobe.swift)

Decisive receiver-side test, run programmatically (no human clicks): `eventprobe` is
a deliberately-inactive AppKit app (floating window + real NSButton) that logs every
event reaching its local monitor and `NSApplication.sendEvent` (type, windowNumber,
locationInWindow, clickCount, fields read back from the CGEvent), plus
`*** BUTTON ACTUATED ***`. The `--probe-*` poster in clickthrough2 fires tagged
down+up pairs at it via each delivery path. Findings (macOS 15.x, 2026-07-10):

| Delivery | mouse arrives? | windowNumber | button actuated? | keyboard arrives? |
|---|---|---|---|---|
| CGEventPostToPid, plain | yes (sendEvent) | **0 / hasWindow=false** | **no** | yes, windowNumber=66127 (bound) |
| CGEventPostToPid, fields 91/92 set | yes | **0** (f91/f92 read back fine) | **no** | — |
| SLEventPostToPid (same payloads) | yes | **0** — identical to CG variant | **no** | yes, bound |
| session tap (control, app INACTIVE) | yes | **bound** (66127), locInWindow correct | **YES** | n/a |

- **Theory confirmed**: pid-posted mouse events DO reach `sendEvent`, but arrive with
  `windowNumber=0` — no window-server window binding — so AppKit drops them before
  any view sees them. Keyboard events get bound by AppKit itself (key window), which
  is exactly why the community reports postToPid working for keyboard only.
- **Fields 91/92 are inert metadata**: readable on the arriving CGEvent, ignored for
  binding (run-1's "routing worked" claim was wrong — nothing was ever routed).
- **Field scan (51..58)**: **raw CGEvent field 51 IS the windowNumber carrier** —
  setting f51 = wid makes the NSEvent arrive with `windowNumber=wid, hasWindow=true`.
  (Field 55 is the event type — writing it kills the event. A genuine server-bound
  event reads f51=windowNumber, f52=owner CGS connection id, f55=type.)
- **But the hit-test location cannot be completed**: a f51-bound synthetic arrives
  with `locInWindow=(0,272)` = window top-left — the CGSEventRecord's separate
  `windowLocation` member is (0,0) and is NOT settable through the CGEvent field API
  (exhaustively scanned fields 51–90, int and double, plus f52=connection-id combos:
  windowNumber binds, location never moves, button never actuates).
- **Conclusion: pid/SL delivery is a dead end for mouse clicks** without dropping to
  raw `SLPSPostEventRecordTo` event records (where `windowLocation` could be filled —
  noted as a possible future probe, but session-fast makes it unnecessary).
- Bonus data point: the **session-posted control click actuated the button of an
  INACTIVE app** with zero activation — session delivery through the server binds
  everything correctly; the eaten-first-click problem is per-view `acceptsFirstMouse`
  policy, not a delivery constraint.

### Run 3 re-test — `--post=session-fast` (the pragmatic path)

Sync SLPS make-key, then session-post the down immediately (no ns/ax poll — run 2
showed real activation ~5ms while the poll reads 55–76ms); the rest of the gesture
flows natively. Expect `deliver` ~2–6ms and actuation everywhere session replay
worked. If early samples land in the OLD frontmost window (z-order flip not yet
server-side), re-run with `--raise-wait` and note it.

| Target | deliver ms | control actuated? | needed --raise-wait? | raise@ ms | Notes |
|---|---|---|---|---|---|
| Native app (Finder / System Settings) | 5.9 | y | n | 24.4 |  |
| Safari |  |  |  |  |  |
| Chrome / Chromium | 13.2 | y | no (*) | 8.7 | raise-wait improves consistency |
| Electron (Slack / VS Code) | 16.4 | y | n | 12.3 |  |
| Occluded: behind another app's window | 10.2 | y | n | 18.3 | session post needs the raise to land first |

Testing notes:
- The click was not released on the first click after starting, leading to an
  accidental drag gesture. Solved by clicking again and did not impact
  subsequent click attempts, only the first click after startup.

### Run 3 re-test — `--post=ax` (zero-raise AXPress probe)

AXPress the element under the cursor with NO activation; falls back to session-fast
when the element isn't pressable. Log: `AXPress on <role> (X.Xms, no activation)`.
Buttons/tabs only — drags and arbitrary canvas points use the fallback.

| Target | pressable element found? | actuated w/o any raise/focus? | ms | Notes |
|---|---|---|---|---|
| Native app button/tab |  |  |  |  |
| Safari link/button |  |  |  |  |
| Chrome button/tab |  |  |  | Chromium AX tree can be lazy off-focus |
| Electron |  |  |  |  |

n/a: I could not find any windows that did NOT result in: `AX element at click point not pressable — falling back to session-fast`

## Experiment 3 — cursor continuity (`--cursor=move`, focus=nsax, post=session)

Drag from a background window and watch the pointer during the activation wait.

| Target | cursor glides during activation? | drag stream coherent (down→drag→up)? | hover side-effects in prev frontmost app? | Notes |
|---|---|---|---|---|
| Native app | y | y | n | tooltips / hover highlights expected benign |
| Safari / browser text selection | y | y | n |  |

Testing notes:
- Cursor snapped back to initial click position the first time after starting. Fine on subsequent clicks.

## Combined — recommended target (`--focus=slps --post=session-fast --cursor=move`)

(Was `--post=pid` before run 3 killed direct delivery.)

| Target | activation ms | deliver ms | click instant? | cursor smooth? | live drag reaches target? | Notes |
|---|---|---|---|---|---|---|
| Native app | 6.3 | 4.3 | y | y | y |  |
| Safari | 28.7 | 12.9 | y | y | y |  |
| Chrome / Chromium | 7.4 | 10.8 | y | y | y | session delivery — no renderer filtering expected |
| Occluded window | 3.1 | 9.5 | y | y | y | may need --raise-wait |

---

## Observations / conclusions

- Which `--focus` mode wins, and by how much (ns/ax gap): *(run 1: slps, 1–20ms vs
  40–185ms nsax — pending `raise@` re-measure to strip poll lag)*
- Does `--post=pid` deliver inactive-app clicks, or is first-mouse still applied?
  **Answered (runs 1–3): dead either way, but NOT because of first-mouse. Run 2
  falsified the first-mouse theory (app active at dispatch, still dead); run 3's
  eventprobe pinned it: pid/SL-posted mouse events arrive with windowNumber=0 (no
  window-server binding) and AppKit drops them in sendEvent. Field 51 can bind the
  windowNumber but the record's windowLocation is unreachable — direct delivery is
  a dead end. Use `--post=session-fast`.**
- Which apps need the Chromium fallback: *(likely none now — session-fast delivers
  through the window server like a real click; verify in the session-fast table)*
- Any Space-switch or focus-stealing surprises from SLPS:
- Chosen combination to integrate (see `spike/INTEGRATION.md`):
  `--focus=slps --post=session-fast --cursor=move`, `--post=ax` optionally for
  pressable controls (zero-raise), pending the re-test tables above.
