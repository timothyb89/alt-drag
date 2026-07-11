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
./spike/clickthrough2 --post=pid                        # Experiment 2 (nsax sequencing)
./spike/clickthrough2 --cursor=move                     # Experiment 3
./spike/clickthrough2 --focus=slps --post=pid                 # Experiment 2b re-run (slps-first)
./spike/clickthrough2 --focus=slps --post=pid --cursor=move   # combined (recommended target)
./spike/clickthrough2 --focus=slps --post=pid --primer        # only if Chrome still ignores clicks
./spike/clickthrough2 --help
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
| Window on another Space/display |  |  |  |  | watch for unwanted Space switch |

> **Follow-up needed on "Space jump? y":** the table shows `y` everywhere, but this
> setup is multi-display, where activating a window on another display legitimately
> switches that display's Space — that isn't an SLPS defect. Please A/B the SAME
> window (same Space/display arrangement) under `--focus=nsax` and `--focus=slps`:
> the question is whether slps jumps Spaces in cases where native activation would
> NOT. Record both below.

| Same-window A/B | Space jump with nsax? | Space jump with slps? | Notes |
|---|---|---|---|
| Window on current Space, same display |  |  |  |
| Window on other display (its current Space) |  |  |  |
| Window on non-current Space, same display |  |  |  |

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
| Native app (Finder / System Settings / Xcode) |  |  |  | core case |
| Safari (native WebKit) |  |  |  |  |
| Chrome / Chromium |  |  |  | if dead, retry with `--primer` |
| Electron (Slack / VS Code) |  |  |  | if dead, retry with `--primer` |
| Occluded: target behind another window of same app |  |  |  | the "impossible" case |
| Occluded: target behind another app's window |  |  |  | fields 91/92 must route |

With `--primer` (only rows that failed above):

| Target | actuated with --primer? | Notes |
|---|---|---|
| Chrome / Chromium |  |  |
| Electron (Slack / VS Code) |  |  |

## Experiment 3 — cursor continuity (`--cursor=move`, focus=nsax, post=session)

Drag from a background window and watch the pointer during the activation wait.

| Target | cursor glides during activation? | drag stream coherent (down→drag→up)? | hover side-effects in prev frontmost app? | Notes |
|---|---|---|---|---|
| Native app |  |  |  | tooltips / hover highlights expected benign |
| Safari / browser text selection |  |  |  |  |

## Combined — recommended target (`--focus=slps --post=pid --cursor=move`)

| Target | activation ms | delivery ms | click instant? | cursor smooth? | live drag reaches target? | Notes |
|---|---|---|---|---|---|---|
| Native app |  |  |  |  |  |  |
| Safari |  |  |  |  |  |  |
| Chrome / Chromium |  |  |  |  |  | expect the per-app fallback here |
| Occluded window |  |  |  |  |  |  |

---

## Observations / conclusions

- Which `--focus` mode wins, and by how much (ns/ax gap): *(run 1: slps, 1–20ms vs
  40–185ms nsax — pending `raise@` re-measure to strip poll lag)*
- Does `--post=pid` deliver inactive-app clicks, or is first-mouse still applied?
  **Answered (run 1): first-mouse IS still applied at dispatch time — dead clicks
  everywhere until the app is active. Fixed via slps-first sequencing; see 2b.**
- Which apps need the Chromium fallback:
- Any Space-switch or focus-stealing surprises from SLPS:
- Chosen combination to integrate (see `spike/INTEGRATION.md`):
