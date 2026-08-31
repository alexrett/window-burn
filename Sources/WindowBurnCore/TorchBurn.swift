import CoreGraphics
import Foundation

public enum TorchModeTransition {
  public static func toggled(from isEnabled: Bool) -> Bool {
    !isEnabled
  }
}

public struct BurnIgnitionPoint: Equatable, Sendable {
  public let x: Float
  public let y: Float

  public init(x: Float, y: Float) {
    self.x = x
    self.y = y
  }
}

public struct TimedBurnIgnition: Equatable, Sendable {
  public let point: BurnIgnitionPoint
  public let startedAt: TimeInterval

  public init(point: BurnIgnitionPoint, startedAt: TimeInterval) {
    self.point = point
    self.startedAt = startedAt
  }
}

public struct TorchIgnitionField: Equatable, Sendable {
  public static let maximumCount = 8

  public private(set) var ignitions: [TimedBurnIgnition]

  public init(ignitions: [TimedBurnIgnition] = []) {
    self.ignitions = Array(ignitions.prefix(Self.maximumCount))
  }

  public mutating func add(point: BurnIgnitionPoint, startedAt: TimeInterval) {
    guard ignitions.count < Self.maximumCount else { return }
    ignitions.append(TimedBurnIgnition(point: point, startedAt: max(0, startedAt)))
  }
}

public enum TorchBurnGeometry {
  public static func normalizedIgnition(
    screenPoint: CGPoint,
    captureFrame: CGRect
  ) -> BurnIgnitionPoint? {
    guard
      captureFrame.width > 0,
      captureFrame.height > 0,
      captureFrame.contains(screenPoint)
    else {
      return nil
    }

    return BurnIgnitionPoint(
      x: Float((screenPoint.x - captureFrame.minX) / captureFrame.width),
      y: Float((screenPoint.y - captureFrame.minY) / captureFrame.height)
    )
  }
}
