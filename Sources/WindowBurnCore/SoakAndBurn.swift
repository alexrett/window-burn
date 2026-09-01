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
  public static func amount(heldFor duration: TimeInterval) -> Float {
    let normalizedDuration = max(0, duration)
    return Float(0.18 + normalizedDuration / 1.65)
  }

  public static func wetness(heldFor duration: TimeInterval) -> Float {
    min(1, amount(heldFor: duration))
  }

  public static func isActiveImpact(
    index: Int,
    count: Int,
    isSoaking: Bool
  ) -> Bool {
    isSoaking && count > 0 && index >= 0 && index == count - 1
  }
}

public enum WetPaperCompositing {
  public static func sourceCoverage(
    effectCoverage: Float,
    isBurning: Bool,
    isHandoffPrepared: Bool = false
  ) -> Float {
    isBurning || isHandoffPrepared ? 1 : clamp(effectCoverage)
  }

  public static func materialCoverage(ruptureCoverage: Float) -> Float {
    1 - clamp(ruptureCoverage)
  }

  public static func effectCoverage(
    absorption: Float,
    liquid: Float,
    droplet: Float,
    rupture: Float,
    tornEdge: Float
  ) -> Float {
    clamp(max(absorption, liquid, droplet, rupture, tornEdge))
  }

  private static func clamp(_ value: Float) -> Float {
    min(1, max(0, value))
  }
}

public struct SoakTrail: Equatable, Sendable {
  public static let minimumPointSpacing: Float = 0.035

  public private(set) var points: [BurnIgnitionPoint]

  public init(points: [BurnIgnitionPoint] = []) {
    self.points = points
  }

  @discardableResult
  public mutating func add(_ point: BurnIgnitionPoint) -> Bool {
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

public struct WetDepositQueue: Equatable, Sendable {
  public private(set) var pendingDeposits: [BurnIgnitionPoint]
  public private(set) var totalPointCount: Int
  public private(set) var latestPoint: BurnIgnitionPoint?

  private var lastDepositedPoint: BurnIgnitionPoint?

  public init(points: [BurnIgnitionPoint] = []) {
    pendingDeposits = []
    totalPointCount = 0
    latestPoint = nil
    lastDepositedPoint = nil
    for point in points {
      _ = add(point)
    }
  }

  @discardableResult
  public mutating func add(_ point: BurnIgnitionPoint) -> Bool {
    latestPoint = point
    if let lastDepositedPoint {
      let deltaX = point.x - lastDepositedPoint.x
      let deltaY = point.y - lastDepositedPoint.y
      let minimumDistanceSquared = SoakTrail.minimumPointSpacing * SoakTrail.minimumPointSpacing
      guard deltaX * deltaX + deltaY * deltaY >= minimumDistanceSquared else {
        return false
      }
    }

    pendingDeposits.append(point)
    totalPointCount += 1
    lastDepositedPoint = point
    return true
  }

  public mutating func takePendingDeposits() -> [BurnIgnitionPoint] {
    let deposits = pendingDeposits
    pendingDeposits.removeAll(keepingCapacity: true)
    return deposits
  }
}
