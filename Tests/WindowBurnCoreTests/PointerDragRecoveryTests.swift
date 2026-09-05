import CoreGraphics
import Testing

@testable import WindowBurnCore

@Suite struct PointerDragRecoveryTests {
  @Test func recoversMotionAndMissingReleaseExactlyOnce() {
    var drag = PointerDragRecovery()
    drag.begin(at: .zero)
    let moved = CGPoint(x: 100, y: 200)
    #expect(drag.sample(at: moved, isPressed: true) == .dragged)
    #expect(drag.sample(at: moved, isPressed: true) == nil)
    #expect(drag.sample(at: moved, isPressed: false) == .up)
    #expect(!drag.isActive)
    #expect(drag.sample(at: moved, isPressed: false) == nil)
  }

  @Test func nativeReleaseAndCancellationStopRecovery() {
    var drag = PointerDragRecovery()
    #expect(drag.sample(at: .zero, isPressed: true) == nil)
    drag.begin(at: .zero)
    drag.end()
    #expect(drag.sample(at: CGPoint(x: 20, y: 30), isPressed: false) == nil)
  }
}
