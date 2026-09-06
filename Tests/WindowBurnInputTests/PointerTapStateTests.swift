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

  @Test func firstNativeTorchGestureAcceptsUnannotatedCGEvents() throws {
    try expectFirstNativeGesture(mode: .torch, eventWindowID: nil)
  }

  @Test func firstNativeSoakGestureAcceptsUnannotatedCGEvents() throws {
    try expectFirstNativeGesture(mode: .soak, eventWindowID: nil)
  }

  @Test func firstNativeTorchGestureAcceptsMatchingWindowIdentity() throws {
    try expectFirstNativeGesture(mode: .torch, eventWindowID: 42)
  }

  @Test func firstNativeSoakGestureAcceptsMatchingWindowIdentity() throws {
    try expectFirstNativeGesture(mode: .soak, eventWindowID: 42)
  }

  @Test func menuTrackingPassesNewClicksOverAnActiveBurningSurface() throws {
    let input = input()
    input.configure(
      mode: .torch,
      surfaces: [.init(id: UUID(), frame: CGRect(x: 0, y: 0, width: 200, height: 200))],
      canStart: true, isSuspended: true)

    #expect(!input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(!input.receive(type: .leftMouseDragged, event: try event(2)))
    #expect(!input.receive(type: .leftMouseUp, event: try event(3)))
    #expect(input.drain().routes.isEmpty)
  }

  @Test func menuTrackingPassesNewClicksOverAPreparedNativeWindow() throws {
    let input = PointerTapState(clock: { 100 })
    let id = UUID()
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
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
        ]))
    input.configure(mode: .soak, surfaces: [], canStart: true, isSuspended: true)

    #expect(!input.receive(type: .leftMouseDown, event: try event(1)))
    #expect(!input.receive(type: .leftMouseDragged, event: try event(2)))
    #expect(!input.receive(type: .leftMouseUp, event: try event(3)))
    #expect(input.drain().routes.isEmpty)

    input.configure(mode: .soak, surfaces: [], canStart: true, isSuspended: false)
    #expect(input.receive(type: .leftMouseDown, event: try event(4)))
    #expect(input.receive(type: .leftMouseUp, event: try event(5)))
    #expect(input.drain().routes.count == 1)
  }

  @Test func menuTrackingStillOwnsTheReleaseOfAnAlreadyAcceptedGesture() throws {
    let input = input()
    let surfaces = [
      PointerTargetSnapshot.Region(id: UUID(), frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    ]
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    input.configure(mode: .torch, surfaces: surfaces, canStart: true, isSuspended: true)

    #expect(input.receive(type: .leftMouseDragged, event: try event(2)))
    #expect(input.receive(type: .leftMouseUp, event: try event(3)))
    let batch = input.drain()
    #expect(batch.events.map(\.kind) == [.down, .dragged, .up])
    #expect(batch.routes.count == 1)
    #expect(!input.receive(type: .leftMouseDown, event: try event(4)))
    #expect(!input.receive(type: .leftMouseUp, event: try event(5)))

    input.configure(mode: .torch, surfaces: surfaces, canStart: true, isSuspended: false)
    #expect(input.receive(type: .leftMouseDown, event: try event(6)))
    #expect(input.receive(type: .leftMouseUp, event: try event(7)))
    #expect(input.drain().routes.count == 1)
  }

  @Test func menuClickAfterAMissedReleaseKeepsItsNativeUp() throws {
    let input = input()
    #expect(input.receive(type: .leftMouseDown, event: try event(1)))
    input.configure(mode: .torch, surfaces: [], canStart: true, isSuspended: true)

    #expect(!input.receive(type: .leftMouseDown, event: try event(2)))
    #expect(!input.receive(type: .leftMouseUp, event: try event(3)))
    let batch = input.drain()
    #expect(batch.events.filter { $0.kind == .down || $0.kind == .up }.map(\.timestamp) == [1, 2])
    #expect(batch.routes.count == 1)
  }

  private func expectFirstNativeGesture(
    mode: PointerTapState.Mode, eventWindowID: Int64?
  ) throws {
    let input = PointerTapState(clock: { 100 })
    let id = UUID()
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    let window = AccessibleWindow(
      target: .init(ownerPID: 1, title: "Original native window", frame: frame),
      element: AXUIElementCreateApplication(1))
    let closeControl = AccessibleWindowControl(
      window: window, kind: .close, button: AXUIElementCreateApplication(1))
    input.configure(mode: mode, surfaces: [], canStart: true)
    input.publishTargets(
      ResolvedPointerTargets(
        windows: .init(
          regions: [.init(id: id, frame: frame)], capturedAt: ProcessInfo.processInfo.systemUptime),
        targets: [
          id: ResolvedPointerTarget(windowID: 42, window: window, closeControl: closeControl)
        ]))

    let down = try event(10)
    if let eventWindowID {
      // CGEvent(source:) does not preserve writes to this annotation field.
      // Exercise a known native annotation through the value entry point.
      #expect(
        input.receive(
          type: .leftMouseDown, point: down.location, timestamp: down.timestamp,
          windowID: eventWindowID))
    } else {
      #expect(
        down.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent) == 0)
      #expect(input.receive(type: .leftMouseDown, event: down))
    }

    // A refresh may remove or replace the native window before the main actor
    // delivers this click. Its route must keep the original preflight handle.
    input.publishTargets(ResolvedPointerTargets())
    let initialBatch = input.drain()
    #expect(initialBatch.events.map(\.kind) == [.down])
    #expect(initialBatch.routes.count == 1)
    let acceptedDown = try #require(initialBatch.events.first)
    let routeID = try #require(acceptedDown.targetID)
    let route = try #require(initialBatch.routes[routeID])
    let retainedWindow: AccessibleWindow?
    switch route {
    case .torch(let original):
      #expect(mode == .torch)
      retainedWindow = original
    case .soak(let original):
      #expect(mode == .soak)
      retainedWindow = original
    case .close:
      Issue.record("An interactive tool click must retain its tool route")
      retainedWindow = nil
    }
    let retained = try #require(retainedWindow)
    #expect(retained.target == window.target)
    #expect(retained.element === window.element)

    #expect(input.receive(type: .leftMouseDragged, event: try event(20)))
    #expect(input.receive(type: .leftMouseUp, event: try event(30)))
    let terminalBatch = input.drain()
    #expect(terminalBatch.events.map(\.kind) == [.dragged, .up])
    #expect(terminalBatch.events.allSatisfy { $0.sequenceID == acceptedDown.sequenceID })
    #expect(terminalBatch.events.allSatisfy { $0.targetID == routeID })
    #expect(terminalBatch.routes.isEmpty)
    #expect(!input.receive(type: .leftMouseDragged, event: try event(40)))
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
