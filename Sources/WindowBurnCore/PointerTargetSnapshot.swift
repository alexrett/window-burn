import CoreGraphics
import Foundation

/// Prepared off the event-tap thread. A nil ID blocks hit testing behind that region.
public struct PointerTargetSnapshot: Sendable {
  public struct Region: Sendable {
    public let id: UUID?
    public let frame: CGRect

    public init(id: UUID?, frame: CGRect) {
      self.id = id
      self.frame = frame
    }
  }

  public let regions: [Region]
  public let capturedAt: TimeInterval

  public init(regions: [Region], capturedAt: TimeInterval) {
    self.regions = regions
    self.capturedAt = capturedAt
  }

  public func target(
    at point: CGPoint, now: TimeInterval, surfaces: [Region] = []
  ) -> UUID? {
    // Replacement surfaces outlive the native window and its resolver cache.
    if let surface = surfaces.first(where: { $0.frame.contains(point) }) {
      return surface.id
    }
    guard now >= capturedAt, now - capturedAt <= 0.3 else { return nil }
    return regions.first(where: { $0.frame.contains(point) })?.id
  }
}
