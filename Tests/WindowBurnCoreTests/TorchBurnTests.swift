import CoreGraphics
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
}
