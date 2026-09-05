# Pointer input repair — 2026-09-05

The shader snapshot was already committed in `fdf9f8e`; the input investigation
was saved through `f707026`. The supplied 36-second recording shows a Finder
window underneath a burning surface becoming active. Its cursor artwork is not
visible, so the recording alone cannot identify each missed click.

## Cause and change

The earlier [physical-input audit](input-and-compositing-audit.md) established
session-tap timeouts and events delivered seconds late. The tap was attached to
the main run loop, shared with drawable acquisition and cursor animation. Its
callbacks also performed AX lookup and hid/moved/ordered the cursor panel.
When that tap was disabled, the click-through effect panel let native windows
receive the input. The existing torch-session registry already routed repeated
clicks into the screenshot correctly when callbacks actually arrived.

The tap now owns a separate run-loop thread. Its callback uses prepared value
snapshots and a bounded queue; it never invokes AppKit, AX, rendering, or a
synchronous main-thread dispatch. Apple documents that the callback executes on
[the run loop hosting its source](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate(tap:place:options:eventsofinterest:callback:userinfo:)).

- A resolver worker prepares front-to-back native window and close-button regions.
  Unsupported/covered/expired regions pass ordinary input through. AX reads have
  an explicit per-handle deadline, and each application's window list is read
  once per refresh. Where an event supplies a native window ID, a mismatch rejects
  a stale target. The snapshot freshness limit is 300 ms; this remains a bounded
  cache, not a continuous AX/Space/window lifecycle observer.
- Active replacement surfaces take priority over native windows beneath them,
  including while their first screenshot is still being prepared. A queued click
  retains its original resolved window rather than hit-testing a different window
  later. Queue overflow on an existing effect consumes the whole click sequence
  without adding another mark, so it cannot activate the app beneath the effect.
- Accepted down/up pairs retain their order and reserved queue space. Motion is
  coalesced; the cursor uses the newest event position independently of the UI's
  gesture queue. Timestamps and sequence IDs reject old motion and old releases.
  Input older than 250 ms cannot start a new interaction. Mode cancellation drops
  pending tool actions while retaining ownership through the physical release.
- The cursor follows at 60 Hz, with artwork at 30 Hz and no repeated redraw of the
  static idle badge. Capture excludes its window ID, so it stays visible while
  preparing the effect. Hardware-position polling and synchronous cursor-panel
  manipulation inside the mouse callback have been removed.
- A nonblocking one-frame GPU gate precedes drawable acquisition. Busy animation
  frames are skipped; paused first-frame/handoff requests are retried after GPU
  completion. Compositor acknowledgement still gates native-window handoff, and
  no `waitUntilCompleted` remains on the main thread. Shaders are unchanged.

## Verification

Physical torch check, 18:31:37–18:31:58: the user confirmed that the cursor follows
and repeated clicks create new ignition sites. Two fixture windows burned, with
14 additional accepted ignition sites. Native fixture counters remained unchanged
through that attempt; the one initial native click was a separate automation
probe that bypassed the system event stream. Raw/production counts were 24/24
mouse downs, 7/7 drags and 24/24 releases. There were no tap timeouts or disabled
intervals. Maximum callback: 0.22 ms; event age: 1.46 ms; drawable wait: 1.01 ms.

A separate physical soak gesture at 18:32:52–18:32:57 was followed by ignition at
18:32:58. In the surrounding 18:32:51–18:32:59 interval the HID observer and
production tap both received 262 drags, two downs and two releases, with no
disabled intervals. Maximum callback: 0.14 ms; event age: 0.24 ms; drawable wait:
0.37 ms. This is a short gesture; the requested 15–20 second fixture check and
subjective confirmation of the 18+ artwork remain pending.

`swift format lint --strict --recursive Package.swift Sources Tests` passes,
as do all 113 tests and the universal arm64/x86_64 release build. The signed local
app was rebuilt and relaunched with input diagnostics. The measurements above
were captured during implementation; subsequent cache guards and idle-artwork
changes have automated regression coverage, with the final long gesture pending.

Regression coverage includes the core queue plus the actual interceptor's routing
state, with rapid clicks, delayed release, missed release, mode off/on, unknown
windows, expired snapshots, native-window identity mismatch, stale coordinates,
and full-queue shielding. These tests construct events but never post UI input.
The separate fixture is intentionally local under ignored `dist/input-review`.

Run diagnostics with:

```sh
./script/build_and_run.sh --input-diagnostics --torch
./script/build_and_run.sh --input-diagnostics --soak-and-burn
```

The resolver reports aggregate timing/counts only. The existing input diagnostics
report raw/production event counts, callback age, cursor changes and drawable
waits. GPU duration and drawable acquisition wait are different measurements.
The [existing compositing limitations](input-and-compositing-audit.md#почему-cmd-tab-оставляет-мокрые-островки)
are outside this pointer repair.
