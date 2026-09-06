import AppKit
import Testing

@testable import WindowBurn

@Suite(.serialized) struct PointerDrainTimerTests {
  @Test(.timeLimit(.minutes(1)))
  @MainActor func drainsBetweenActorJobs() async {
    var timer: Timer?
    await withCheckedContinuation { continuation in
      timer = WindowControlInterceptor.scheduleDrain {
        MainActor.preconditionIsolated()
        #expect(Thread.isMainThread)
        timer?.invalidate()
        timer = nil
        continuation.resume()
      }
    }
  }

  @Test(arguments: [RunLoop.Mode.default, .eventTracking, .modalPanel])
  @MainActor func drainsOnMainActorInEachAppKitMode(mode: RunLoop.Mode) {
    // A SwiftPM test host does not install all of AppKit's common modes.
    let runLoop = CFRunLoopGetMain()
    let cfMode = CFRunLoopMode(rawValue: mode.rawValue as CFString)
    CFRunLoopAddCommonMode(runLoop, cfMode)
    var drains = 0
    let timer = WindowControlInterceptor.scheduleDrain {
      MainActor.preconditionIsolated()
      #expect(Thread.isMainThread)
      drains += 1
    }
    defer { timer.invalidate() }

    // Service the real timer source, without calling Timer.fire() or posting input.
    timer.fireDate = .distantPast
    CFRunLoopRunInMode(cfMode, 0.05, false)
    #expect(drains > 0, "Input must drain while this run-loop mode is active")
  }
}
