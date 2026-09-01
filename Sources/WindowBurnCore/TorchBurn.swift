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

public struct TorchWindowSessionRegistry: Equatable, Sendable {
  public static let maximumConcurrentWindows = 4

  private struct Entry: Equatable, Sendable {
    let id: UUID
    var captureFrame: CGRect
  }

  private var entries: [Entry] = []

  public init() {}

  public var count: Int {
    entries.count
  }

  public var isAtCapacity: Bool {
    count >= Self.maximumConcurrentWindows
  }

  @discardableResult
  public mutating func register(id: UUID, captureFrame: CGRect) -> Bool {
    guard
      !isAtCapacity,
      !entries.contains(where: { $0.id == id }),
      captureFrame.width > 1,
      captureFrame.height > 1
    else {
      return false
    }
    entries.append(Entry(id: id, captureFrame: captureFrame))
    return true
  }

  @discardableResult
  public mutating func updateCaptureFrame(id: UUID, captureFrame: CGRect) -> Bool {
    guard
      captureFrame.width > 1,
      captureFrame.height > 1,
      let index = entries.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    entries[index].captureFrame = captureFrame
    return true
  }

  public func sessionID(containing screenPoint: CGPoint) -> UUID? {
    entries.last(where: { $0.captureFrame.contains(screenPoint) })?.id
  }

  public mutating func remove(id: UUID) {
    entries.removeAll(where: { $0.id == id })
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
