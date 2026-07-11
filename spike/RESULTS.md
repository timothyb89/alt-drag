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
./spike/clickthrough2 --post=pid                        # Experiment 2
./spike/clickthrough2 --cursor=move                     # Experiment 3
./spike/clickthrough2 --focus=slps --post=pid --cursor=move   # combined (recommended target)
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

Same format as the baseline. Key lines:

- `swallowed first-click on unfocused win (pid …, wid …) … [focus=… post=… cursor=…]`
- `posted mousedown -> pid … directly (deliver X.Xms)` — **Experiment 2 only**; delivery
  latency from hardware mousedown to the pid-post (the click-before-raise number).
- `activated in X.Xms [reason] (ns@… ax@… foc@…)` — activation latency + which signal
  led. `reason` is `ns-led` / `ax-led` / `front-only(grace)` / `timeout`. Expect
  single-digit ms with `--focus=slps`, 40–200ms with `--focus=nsax`.
- `replayed CLICK/DRAG … total X.Xms` — **session mode**; end-to-end mousedown→delivery.
- `posted mouseup -> pid … — CLICK/DRAG delivered direct, total X.Xms` — **pid mode**.

`activation ms` column = the `activated in` value. `delivery ms` column = the
`deliver` value (pid mode) or the `total` value (session mode). `visible reaction` =
did the control actuate / cursor glide, observed by eye.

---

## Experiment 1 — SLPS fast focus (`--focus=slps`, post=session, cursor=freeze)

Compare activation latency vs. the `nsax` baseline for the same targets. Success
target from the spec: p95 activation < 10ms.

| Target | nsax activation ms | slps activation ms | reason (slps) | Space jump? | Notes |
|---|---|---|---|---|---|
| Native app (Finder / System Settings) |  |  |  |  |  |
| Xcode |  |  |  |  |  |
| Safari |  |  |  |  |  |
| Chrome / Chromium |  |  |  |  |  |
| Electron (Slack / VS Code) |  |  |  |  |  |
| Window on another Space/display |  |  |  |  | watch for unwanted Space switch |

## Experiment 2 — click before raise (`--post=pid`, focus=nsax, cursor=freeze)

Open question: does AppKit still swallow pid-posted input as first-mouse while the
app is inactive? Click a button/tab in each unfocused target.

| Target | delivery ms (deliver→post) | control actuated? | fields 91/92 routed correctly? | Notes |
|---|---|---|---|---|
| Native app (Finder / System Settings / Xcode) |  |  |  | core case, "should work" |
| Safari (native WebKit) |  |  |  |  |
| Chrome / Chromium |  |  |  | may reject synthesized input; see primer-click note |
| Electron (Slack / VS Code) |  |  |  | Chromium-derived, uncertain |
| Occluded: target behind another window of same app |  |  |  | the "impossible" case |
| Occluded: target behind another app's window |  |  |  | fields 91/92 must route |

Chromium fallback probes (only if Chrome/Electron ignores the click):
- [ ] primer click at (-1,-1) posted to the pid ~5ms before the real one
- [ ] run `--focus=slps` fast-focus first, THEN post (`--focus=slps --post=pid`)

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

- Which `--focus` mode wins, and by how much (ns/ax gap):
- Does `--post=pid` deliver inactive-app clicks, or is first-mouse still applied?
- Which apps need the Chromium fallback:
- Any Space-switch or focus-stealing surprises from SLPS:
- Chosen combination to integrate (see `spike/INTEGRATION.md`):
