import Foundation

public enum SoakAndBurnPhase: Equatable, Sendable {
  case readyToSoak
  case soaking
  case readyToBurn
  case burning
}

public enum SoakAndBurnModePolicy {
  public static func shouldRemainEnabled(after phase: SoakAndBurnPhase) -> Bool {
    phase != .burning
  }
}

public struct SoakAndBurnSession: Equatable, Sendable {
  public private(set) var phase: SoakAndBurnPhase = .readyToSoak

  public init() {}

  @discardableResult
  public mutating func beginSoaking() -> Bool {
    guard phase == .readyToSoak else { return false }
    phase = .soaking
    return true
  }

  @discardableResult
  public mutating func finishSoaking() -> Bool {
    guard phase == .soaking else { return false }
    phase = .readyToBurn
    return true
  }

  @discardableResult
  public mutating func beginBurning() -> Bool {
    guard phase == .readyToBurn else { return false }
    phase = .burning
    return true
  }

  public mutating func reset() {
    phase = .readyToSoak
  }
}

public enum SoakEffect {
  public static func wetness(heldFor duration: TimeInterval) -> Float {
    let normalizedDuration = max(0, duration)
    return Float(min(1, 0.18 + normalizedDuration / 1.65))
  }
}

public struct SoakTrail: Equatable, Sendable {
  public static let maximumCount = 12
  public static let minimumPointSpacing: Float = 0.035

  public private(set) var points: [BurnIgnitionPoint]

  public init(points: [BurnIgnitionPoint] = []) {
    self.points = Array(points.prefix(Self.maximumCount))
  }

  @discardableResult
  public mutating func add(_ point: BurnIgnitionPoint) -> Bool {
    guard points.count < Self.maximumCount else { return false }
    if let last = points.last {
      let deltaX = point.x - last.x
      let deltaY = point.y - last.y
      let minimumDistanceSquared = Self.minimumPointSpacing * Self.minimumPointSpacing
      guard deltaX * deltaX + deltaY * deltaY >= minimumDistanceSquared else {
        return false
      }
    }
    points.append(point)
    return true
  }
}
