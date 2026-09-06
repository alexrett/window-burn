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
  Unsupported/covered/expired native regions pass ordinary input through. AX reads have
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
0.37 ms. This initial trial was short and did not yet include subjective
confirmation of the 18+ artwork.

`swift format lint --strict --recursive Package.swift Sources Tests` passes,
as do all 113 tests and the universal arm64/x86_64 release build. The signed local
app was rebuilt and relaunched with input diagnostics. The measurements above
were captured during implementation; subsequent cache guards and idle-artwork
changes had automated regression coverage but still needed final physical input
verification. The follow-up below records the final-build regression and retest.

### Follow-up: native entry blocked in every application

The user subsequently reported that both tools passed clicks and drags through
in Finder and other applications. Diagnostics on the actual physical events at
19:15:18–19:15:22 showed `decision=no-target`, fresh snapshots (25–92 ms), and no
native event window ID. This was a target-selection failure, before effect
creation or window-identity validation.

The live WindowServer list contained a full-screen `Screenshot` surface on layer
24 and cursor surfaces on layer 2147483630. The new resolver had treated every
nonzero layer as an opaque input blocker. WindowServer enumerates visual surfaces;
these click-through overlays therefore hid native input targets in the cache.
The cursor surface alone can cover the click point, even without screen recording.

The resolver now uses only visible normal application windows (layer 0) for
native targets and occlusion, matching the existing `WindowAtPointMatcher` rule.
Unsupported normal windows still block targets behind them. Active effect surfaces
continue to use their explicit interaction regions. The regression test uses the
observed full-screen recording and cursor layers above a normal Finder window:
it failed before the filter change and passes afterward, with coverage for the
cursor alone as well as the recording overlay. Additional interceptor
tests cover first native entry for both tools with unavailable and matching event
window IDs, retaining the original target through drag and release after refresh.

Window Burn's own status menu suspends new interception while tracking, so its
items cannot act on a normal window or burning surface underneath. A gesture
accepted before the menu opens keeps ownership of its remaining drag/release.
The suspension and restoration paths also have interceptor regression coverage.

Final signed build, physical retest at 19:25:46–19:26:08: the user confirmed
"Оба режима работают" and "вот сейчас просто идеально". Soaking started on a
native Finder window from its first down, followed by ignition. Torch then
started on another native Finder window and accepted three additional ignition
sites. All eight downs, 208 drags and eight releases reached the production tap,
matching the independent HID observer; no timeouts or disabled intervals occurred.
Maximum callback: 0.52 ms; event age: 0.99 ms; drawable acquisition: 1.16 ms.

All 123 tests pass, including cursor-layer cases with and without the recording
overlay. Strict Swift format lint, `git diff --check`, the universal arm64/x86_64
release build and the signed-app verification pass. The running app's Mach-O UUID
matches the tested debug build. Local evidence is saved under ignored
`dist/input-diagnostics/native-layer-fix/`.

Regression coverage includes the core queue plus the actual interceptor's routing
state, with rapid clicks, delayed release, missed release, mode off/on, unknown
windows, expired snapshots, native-window identity mismatch, stale coordinates,
and full-queue shielding. These tests construct events but never post UI input.
The separate fixture is intentionally local under ignored `dist/input-review`.

## MainActor timer review — 2026-09-06

[Copilot's review of PR #5](https://github.com/alexrett/window-burn/pull/5#discussion_r3943913068)
questioned `MainActor.assumeIsolated` in the timer callback and suggested an
asynchronous `Task { @MainActor ... }` instead. The callback type itself does not
express actor isolation, but this timer is explicitly installed on `RunLoop.main`
in common modes. It is created and invalidated from the main actor. Its private
production owner never fires it manually or adds it to another run loop.

[Apple documents](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html)
synchronous timer delivery on the owning run loop and the default, event-tracking
and modal modes included in AppKit's common modes. The production scheduler is
now a small testable method, with the scheduling invariant next to the runtime
isolation assertion.

`PointerDrainTimerTests` services the actual production timer source, without
posting mouse input. It checks MainActor isolation both between actor jobs and
inside nested default, event-tracking and modal run loops. The synchronous
implementation passes all four cases. Temporarily replacing its callback with
the proposed `Task` caused all three nested-loop cases to observe zero drains
before their loop returned. This demonstrates a delivery-order difference in
that scenario, not a claim that every asynchronous timer callback is incorrect.
The synchronous implementation is retained; the reported isolation failure was
not reproduced. No timer frequency, pointer routing or rendering behavior changed.
The follow-up review correctly identified test pollution from adding modes to the
main run loop's common-mode set. Extra test modes are now registered only on the
timer under test and removed by invalidation. This probes actor isolation and
synchronous delivery, not AppKit's initialization of its common-mode set. A
regression test places a separate timer in common modes: the old test setup fired
it four times in a new private mode; the isolated setup leaves it untouched.

Local validation passes: all 126 tests, strict Swift format lint, and the universal
arm64/x86_64 release build.

Run diagnostics with:

```sh
./script/build_and_run.sh --input-diagnostics --torch
./script/build_and_run.sh --input-diagnostics --soak-and-burn
```

The resolver reports aggregate timing/counts only. Down-event decisions are
buffered on the tap and logged by the main drain only with `--input-diagnostics`;
they include the rejection reason, native/prepared window IDs and snapshot age.
They do not include window titles or contents. The existing input diagnostics
report raw/production event counts, callback age, cursor changes and drawable
waits. GPU duration and drawable acquisition wait are different measurements.
The [existing compositing limitations](input-and-compositing-audit.md#почему-cmd-tab-оставляет-мокрые-островки)
are outside this pointer repair.
