import CoreGraphics
import Foundation
import Testing

@testable import WindowBurnCore

@Suite("Torch burn")
struct TorchBurnTests {
  @Test("Torch mode toggles off on the second shortcut press")
  func torchModeToggle() {
    #expect(TorchModeTransition.toggled(from: false))
    #expect(!TorchModeTransition.toggled(from: true))
  }

  @Test("Normalizes a screen click inside the captured window")
  func normalizesIgnitionPoint() throws {
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    let point = try #require(
      TorchBurnGeometry.normalizedIgnition(
        screenPoint: CGPoint(x: 300, y: 350),
        captureFrame: frame
      )
    )

    #expect(point == BurnIgnitionPoint(x: 0.25, y: 0.25))
  }

  @Test("Rejects clicks outside the captured window")
  func rejectsOutsidePoint() {
    let frame = CGRect(x: 100, y: 200, width: 800, height: 600)

    #expect(
      TorchBurnGeometry.normalizedIgnition(
        screenPoint: CGPoint(x: 99, y: 350),
        captureFrame: frame
      ) == nil
    )
  }

  @Test("Keeps a bounded set of timed ignition points")
  func boundsIgnitionCount() {
    var field = TorchIgnitionField()

    for index in 0..<(TorchIgnitionField.maximumCount + 2) {
      field.add(
        point: BurnIgnitionPoint(x: Float(index) / 10, y: 0.5),
        startedAt: Double(index)
      )
    }

    #expect(field.ignitions.count == TorchIgnitionField.maximumCount)
    #expect(field.ignitions.first?.startedAt == 0)
    #expect(field.ignitions.last?.startedAt == Double(TorchIgnitionField.maximumCount - 1))
  }

  @Test("Routes an overlapping click to the most recently ignited window")
  func routesClickToMostRecentWindow() throws {
    let olderWindow = UUID()
    let newerWindow = UUID()
    var registry = TorchWindowSessionRegistry()

    let registeredOlderWindow = registry.register(
      id: olderWindow,
      captureFrame: CGRect(x: 100, y: 100, width: 500, height: 400)
    )
    let registeredNewerWindow = registry.register(
      id: newerWindow,
      captureFrame: CGRect(x: 300, y: 200, width: 500, height: 400)
    )
    #expect(registeredOlderWindow)
    #expect(registeredNewerWindow)

    let match = try #require(
      registry.sessionID(containing: CGPoint(x: 350, y: 250))
    )
    #expect(match == newerWindow)
  }

  @Test("Completing one torch window leaves the other sessions active")
  func removesOnlyCompletedWindow() {
    let firstWindow = UUID()
    let secondWindow = UUID()
    var registry = TorchWindowSessionRegistry()
    let firstFrame = CGRect(x: 100, y: 100, width: 300, height: 250)
    let secondFrame = CGRect(x: 500, y: 100, width: 300, height: 250)

    let registeredFirstWindow = registry.register(id: firstWindow, captureFrame: firstFrame)
    let registeredSecondWindow = registry.register(id: secondWindow, captureFrame: secondFrame)
    #expect(registeredFirstWindow)
    #expect(registeredSecondWindow)

    registry.remove(id: firstWindow)

    #expect(registry.count == 1)
    #expect(registry.sessionID(containing: firstFrame.center) == nil)
    #expect(registry.sessionID(containing: secondFrame.center) == secondWindow)
  }

  @Test("Bounds the number of simultaneously burning windows")
  func boundsConcurrentWindowCount() {
    var registry = TorchWindowSessionRegistry()

    for index in 0..<TorchWindowSessionRegistry.maximumConcurrentWindows {
      let registered = registry.register(
        id: UUID(),
        captureFrame: CGRect(x: CGFloat(index * 120), y: 0, width: 100, height: 100)
      )
      #expect(registered)
    }

    let registeredOverflowWindow = registry.register(
      id: UUID(),
      captureFrame: CGRect(x: 900, y: 0, width: 100, height: 100)
    )
    #expect(!registeredOverflowWindow)
  }
}

extension CGRect {
  fileprivate var center: CGPoint {
    CGPoint(x: midX, y: midY)
  }
}
