import AppKit
import Testing

@testable import WindowBurn

@Suite(.serialized) struct PointerDrainTimerTests {
  @Test(.timeLimit(.minutes(1)))
  @MainActor func drainsBetweenActorJobs() async throws {
    var drains = 0
    let timer = WindowControlInterceptor.scheduleDrain {
      MainActor.preconditionIsolated()
      #expect(Thread.isMainThread)
      drains += 1
    }
    defer { timer.invalidate() }
    // Sleep cooperatively so a timeout/cancellation also invalidates the timer.
    while drains == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test(arguments: [RunLoop.Mode.default, .eventTracking, .modalPanel])
  @MainActor func drainsOnMainActorInEachAppKitMode(mode: RunLoop.Mode) {
    let cfMode = CFRunLoopMode(rawValue: mode.rawValue as CFString)
    var drains = 0
    let timer = WindowControlInterceptor.scheduleDrain {
      MainActor.preconditionIsolated()
      #expect(Thread.isMainThread)
      drains += 1
    }
    defer { timer.invalidate() }
    // The test host lacks AppKit's common modes. Add extra modes only to this
    // timer; invalidation removes them without altering the global common set.
    if mode != .default { RunLoop.main.add(timer, forMode: mode) }

    // Service the real timer source, without calling Timer.fire() or posting input.
    timer.fireDate = .distantPast
    CFRunLoopRunInMode(cfMode, 0.05, false)
    #expect(drains > 0, "Input must drain while this run-loop mode is active")
  }

  @Test @MainActor func modeProbeDoesNotChangeOtherCommonModeTimers() {
    let isolatedMode = RunLoop.Mode("WindowBurn-test-\(UUID().uuidString)")
    var unrelatedDrains = 0
    let unrelatedTimer = WindowControlInterceptor.scheduleDrain { unrelatedDrains += 1 }
    defer { unrelatedTimer.invalidate() }
    unrelatedTimer.fireDate = .distantPast

    drainsOnMainActorInEachAppKitMode(mode: isolatedMode)

    #expect(unrelatedDrains == 0, "The probe must not add modes to unrelated common-mode timers")
  }
}
