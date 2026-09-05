import CoreGraphics
import Foundation
import Testing

@testable import WindowBurnCore

@Suite("Asynchronous pointer event buffer")
struct PointerEventBufferTests {
  @Test("Rapid clicks retain their complete order when the UI drains later")
  func preservesRapidClickOrdering() {
    var buffer = PointerEventBuffer(capacity: 4)
    let events = [
      event(.down, time: 1, sequence: 1),
      event(.up, time: 2, sequence: 1),
      event(.down, time: 3, sequence: 2),
      event(.up, time: 4, sequence: 2),
    ]

    for event in events { #expect(buffer.append(event) == true) }

    #expect(buffer.drain() == events)
    #expect(buffer.count == 0)
    #expect(buffer.latestPointerEvent == events.last)
    #expect(!buffer.isGestureActive)
  }

  @Test("Consecutive motion coalesces without replacing gesture boundaries")
  func coalescesMotion() {
    var buffer = PointerEventBuffer(capacity: 6)
    let down = event(.down, time: 1, sequence: 1)
    let lastDrag = event(.dragged, time: 3, sequence: 1)
    let up = event(.up, time: 4, sequence: 1)
    let lastMove = event(.moved, time: 6, sequence: 0)

    #expect(buffer.append(down) == true)
    #expect(buffer.append(event(.dragged, time: 2, sequence: 1)) == true)
    #expect(buffer.append(lastDrag) == true)
    #expect(buffer.append(up) == true)
    #expect(buffer.append(event(.moved, time: 5, sequence: 0)) == true)
    #expect(buffer.append(lastMove) == true)

    #expect(buffer.drain() == [down, lastDrag, up, lastMove])
  }

  @Test("Motion from different sequences or targets is not coalesced")
  func keepsMotionIdentity() {
    var buffer = PointerEventBuffer(capacity: 4)
    let first = event(.moved, time: 1, sequence: 1)
    let second = event(.moved, time: 2, sequence: 2)
    let third = event(.moved, time: 3, sequence: 2, target: UUID())

    #expect(buffer.append(first) == true)
    #expect(buffer.append(second) == true)
    #expect(buffer.append(third) == true)

    #expect(buffer.drain() == [first, second, third])
  }

  @Test("A full queue refuses a new click without losing accepted clicks")
  func refusesClickWithoutTerminalCapacity() {
    var buffer = PointerEventBuffer(capacity: 3)
    let down = event(.down, time: 1, sequence: 1)
    let up = event(.up, time: 2, sequence: 1)

    #expect(buffer.append(down) == true)
    #expect(buffer.append(up) == true)
    #expect(buffer.append(event(.down, time: 3, sequence: 2)) == false)
    #expect(!buffer.isGestureActive)
    #expect(buffer.append(event(.up, time: 4, sequence: 2)) == false)
    #expect(buffer.drain() == [down, up])
  }

  @Test("The reserved release slot survives a drain while the button is held")
  func reservesReleaseAcrossDrain() {
    var buffer = PointerEventBuffer(capacity: 2)
    let down = event(.down, time: 1, sequence: 1)
    let drag = event(.dragged, time: 2, sequence: 1)
    let up = event(.up, time: 3, sequence: 1)

    #expect(buffer.append(down) == true)
    #expect(buffer.drain() == [down])
    #expect(buffer.isGestureActive)
    #expect(buffer.append(drag) == true)
    #expect(buffer.append(up) == true)
    #expect(buffer.drain() == [drag, up])
    #expect(!buffer.isGestureActive)
  }

  @Test("Queue pressure removes motion before rejecting a complete click")
  func evictsMotionBeforeClickBoundaries() {
    var buffer = PointerEventBuffer(capacity: 3)
    let down = event(.down, time: 3, sequence: 1)
    let up = event(.up, time: 5, sequence: 1)

    #expect(buffer.append(event(.moved, time: 1, sequence: 0)) == true)
    #expect(buffer.append(event(.moved, time: 2, sequence: 2)) == true)
    #expect(buffer.append(down) == true)
    #expect(buffer.append(event(.dragged, time: 4, sequence: 1)) == true)
    #expect(buffer.append(up) == true)

    let drained = buffer.drain()
    #expect(drained.count <= 3)
    #expect(drained.filter { $0.kind == .down || $0.kind == .up } == [down, up])
    #expect(drained.last == up)
  }

  @Test("Cursor position stays fresh even when there is no room for queued motion")
  func recordsLatestPointerAtCapacity() {
    var buffer = PointerEventBuffer(capacity: 2)
    let down = event(.down, time: 1, sequence: 1)
    let drag = event(.dragged, time: 2, sequence: 1)
    let up = event(.up, time: 3, sequence: 1)

    #expect(buffer.append(down) == true)
    #expect(buffer.append(drag) == false)
    #expect(buffer.latestPointerEvent == drag)
    #expect(buffer.append(up) == true)
    #expect(buffer.drain() == [down, up])
  }

  @Test("Late coordinates cannot rewind the cursor before or after a drain")
  func rejectsStaleTimestamps() {
    var buffer = PointerEventBuffer()
    let latest = event(.moved, time: 20, sequence: 0)

    #expect(buffer.append(latest) == true)
    #expect(buffer.append(event(.moved, time: 10, sequence: 0)) == false)
    #expect(buffer.drain() == [latest])
    #expect(buffer.append(event(.moved, time: 15, sequence: 0)) == false)
    #expect(buffer.latestPointerEvent == latest)
    #expect(buffer.count == 0)
  }

  @Test("Equal timestamps preserve a down and up delivered at the same tick")
  func acceptsEqualTimestamps() {
    var buffer = PointerEventBuffer()
    let down = event(.down, time: 1, sequence: 1)
    let up = event(.up, time: 1, sequence: 1)

    #expect(buffer.append(down) == true)
    #expect(buffer.append(up) == true)
    #expect(buffer.drain() == [down, up])
  }

  @Test("An old gesture cannot end or add deposits to the currently held gesture")
  func rejectsUnmatchedSequenceEvents() {
    var buffer = PointerEventBuffer()
    let target = UUID()
    let down = event(.down, time: 1, sequence: 2, target: target)
    let up = event(.up, time: 6, sequence: 2, target: target)

    #expect(buffer.append(down) == true)
    #expect(buffer.append(event(.dragged, time: 2, sequence: 1, target: target)) == false)
    #expect(buffer.append(event(.up, time: 3, sequence: 1, target: target)) == false)
    #expect(buffer.append(event(.down, time: 4, sequence: 3, target: target)) == false)
    #expect(buffer.append(event(.up, time: 5, sequence: 2, target: UUID())) == false)
    #expect(buffer.isGestureActive)
    #expect(buffer.latestPointerEvent == down)
    #expect(buffer.append(up) == true)
    #expect(buffer.drain() == [down, up])
  }

  @Test("A long held gesture stays bounded while retaining its start and release")
  func boundsLongGesture() {
    var buffer = PointerEventBuffer(capacity: 4)
    let down = event(.down, time: 1, sequence: 1)
    let up = event(.up, time: 10_001, sequence: 1)

    #expect(buffer.append(down) == true)
    for time in UInt64(2)...10_000 {
      #expect(buffer.append(event(.dragged, time: time, sequence: 1)) == true)
      #expect(buffer.count <= 3)
    }
    #expect(buffer.append(up) == true)

    let drained = buffer.drain()
    #expect(drained.count == 3)
    #expect(drained.first == down)
    #expect(drained[1].timestamp == 10_000)
    #expect(drained.last == up)
  }

  private func event(
    _ kind: PointerInputEvent.Kind,
    time: UInt64,
    sequence: UInt64,
    target: UUID? = nil
  ) -> PointerInputEvent {
    PointerInputEvent(
      kind: kind,
      point: CGPoint(x: Double(time), y: 20),
      timestamp: time,
      sequenceID: sequence,
      targetID: target
    )
  }
}
