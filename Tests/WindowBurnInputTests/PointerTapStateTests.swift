import ApplicationServices
import CoreGraphics
import Foundation
import Testing
import WindowBurnCore

@testable import WindowBurn

@Suite struct PointerTapStateTests {
  private func input() -> PointerTapState {
    let input = PointerTapState(clock: { 100 })
    input.configure(
      mode: .torch,
      surfaces: [.init(id: UUID(), frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
      canStart: false)
    return input
  }

  private func event(_ timestamp: UInt64, point: CGPoint = CGPoint(x: 50, y: 50)) throws -> CGEvent
  {
    let event = try #require(CGEvent(source: nil))
    event.timestamp = timestamp
    event.location = point
    return event
  }

  @Test func oldClickCannotTargetANewWindowAtItsFormerCoordinates() throws {
    let input = PointerTapState(clock: { 1_000_000_000 })
    input.configure(
      mode: .torch,
      surfaces: [.init(id: UUID(), frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
      canStart: false)
    #expect(!input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(input.drain().routes.isEmpty)
  }

  @Test func windowIdentityMismatchPassesThroughStaleNativeSnapshot() throws {
    let input = PointerTapState(clock: { 100 })
    let id = UUID()
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    input.configure(mode: .torch, surfaces: [], canStart: true)
    input.publishTargets(
      ResolvedPointerTargets(
        windows: .init(
          regions: [.init(id: id, frame: frame)], capturedAt: ProcessInfo.processInfo.systemUptime),
        targets: [
          id: ResolvedPointerTarget(
            windowID: 42,
            window: AccessibleWindow(
              target: .init(ownerPID: 1, title: nil, frame: frame),
              element: AXUIElementCreateApplication(1)), closeControl: nil)
        ]
      ))
    #expect(
      !input.receive(type: .leftMouseDown, point: CGPoint(x: 50, y: 50), timestamp: 1, windowID: 43)
    )
    #expect(input.drain().routes.isEmpty)
  }

  @Test func fullQueueStillShieldsBurningSurfaceFromNativeClicks() throws {
    let input = input()
    for time in stride(from: UInt64(1), through: 127, by: 2) {
      #expect(input.receive(type: .leftMouseDown, event: try event(time)))
      #expect(input.receive(type: .leftMouseUp, event: try event(time + 1)))
    }
    #expect(input.receive(type: .leftMouseDown, event: try event(129)))
    #expect(input.receive(type: .leftMouseDragged, event: try event(130)))
    #expect(input.receive(type: .leftMouseUp, event: try event(131)))
    #expect(input.drain().events.count == 128)
  }

  @Test func repeatClicksAndDragStayOwnedWhileMainDoesNotDrain() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(input.receive(type: .leftMouseDragged, event: try event(2)))
    #expect(input.receive(type: .leftMouseUp, event: try event(3)))
    #expect(input.receive(type: .leftMouseDown, event: try event(4)))
    #expect(input.receive(type: .leftMouseUp, event: try event(5)))
    let batch = input.drain()
    #expect(batch.events.map(\.kind) == [.down, .dragged, .up, .down, .up])
    #expect(batch.routes.count == 2)
  }

  @Test func delayedReleaseFromPreviousGestureCannotFinishNewGesture() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(10)))
    #expect(input.receive(type: .leftMouseUp, event: try event(20)))
    #expect(input.receive(type: .leftMouseDown, event: try event(30)))
    #expect(input.receive(type: .leftMouseUp, event: try event(20)))
    #expect(input.receive(type: .leftMouseDragged, event: try event(40)))
    #expect(input.receive(type: .leftMouseUp, event: try event(50)))
    #expect(input.drain().events.map(\.timestamp) == [10, 20, 30, 40, 50])
  }

  @Test func modeOffThenOnCannotReplayCancelledClicks() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    input.configure(mode: .close, surfaces: [], canStart: true)
    input.configure(mode: .torch, surfaces: [], canStart: true)
    #expect(input.receive(type: .leftMouseUp, event: try event(2)))
    let batch = input.drain()
    #expect(batch.routes.isEmpty)
    #expect(batch.events.map(\.kind) == [.down, .up])
  }

  @Test func unknownTargetsKeepTheirNativeSequence() throws {
    let input = PointerTapState(clock: { 100 })
    input.configure(mode: .torch, surfaces: [], canStart: true)
    #expect(!input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(!input.receive(type: .leftMouseDragged, event: try event(2)))
    #expect(!input.receive(type: .leftMouseUp, event: try event(3)))
    #expect(input.drain().routes.isEmpty)
  }

  @Test func missedReleaseFinishesOnceBeforeTheNextClick() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(input.receive(type: .leftMouseDown, event: try event(2)))
    #expect(input.receive(type: .leftMouseUp, event: try event(3)))
    #expect(input.drain().events.map(\.kind) == [.down, .up, .down, .up])
  }

  @Test func queuedGestureCannotRewindTheLatestPointer() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    let latest = CGPoint(x: 120, y: 150)
    #expect(!input.receive(type: .mouseMoved, event: try event(30, point: latest)))
    #expect(input.receive(type: .leftMouseDragged, event: try event(20)))
    #expect(input.latestPointerLocation == latest)
    #expect(input.receive(type: .leftMouseUp, event: try event(25)))
    #expect(input.latestPointerLocation == latest)
  }
}
