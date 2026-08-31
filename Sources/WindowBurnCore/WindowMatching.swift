import CoreGraphics
import Foundation

public struct TargetWindow: Equatable, Sendable {
  public let ownerPID: pid_t
  public let title: String?
  public let frame: CGRect

  public init(ownerPID: pid_t, title: String?, frame: CGRect) {
    self.ownerPID = ownerPID
    self.title = title
    self.frame = frame
  }
}

public struct WindowCandidate: Equatable, Sendable {
  public let id: UInt32
  public let ownerPID: pid_t
  public let title: String?
  public let frame: CGRect
  public let isOnScreen: Bool

  public init(
    id: UInt32,
    ownerPID: pid_t,
    title: String?,
    frame: CGRect,
    isOnScreen: Bool
  ) {
    self.id = id
    self.ownerPID = ownerPID
    self.title = title
    self.frame = frame
    self.isOnScreen = isOnScreen
  }
}

public struct PointWindowCandidate: Equatable, Sendable {
  public let id: UInt32
  public let ownerPID: pid_t
  public let title: String?
  public let frame: CGRect
  public let layer: Int
  public let isOnScreen: Bool
  public let alpha: Double

  public init(
    id: UInt32,
    ownerPID: pid_t,
    title: String?,
    frame: CGRect,
    layer: Int,
    isOnScreen: Bool,
    alpha: Double
  ) {
    self.id = id
    self.ownerPID = ownerPID
    self.title = title
    self.frame = frame
    self.layer = layer
    self.isOnScreen = isOnScreen
    self.alpha = alpha
  }
}

public enum WindowAtPointMatcher {
  public static func frontmost(
    at point: CGPoint,
    amongFrontToBack candidates: [PointWindowCandidate],
    excludingPID: pid_t
  ) -> PointWindowCandidate? {
    candidates.first {
      $0.ownerPID != excludingPID
        && $0.layer == 0
        && $0.isOnScreen
        && $0.alpha > 0.01
        && $0.frame.width > 1
        && $0.frame.height > 1
        && $0.frame.contains(point)
    }
  }
}

public enum WindowMatcher {
  public static func bestMatch(
    for target: TargetWindow,
    among candidates: [WindowCandidate]
  ) -> WindowCandidate? {
    candidates
      .filter { $0.ownerPID == target.ownerPID && $0.isOnScreen }
      .map { ($0, score(candidate: $0, target: target)) }
      .filter { $0.1 >= 0.25 }
      .max { left, right in left.1 < right.1 }?
      .0
  }

  private static func score(candidate: WindowCandidate, target: TargetWindow) -> Double {
    let intersection = candidate.frame.intersection(target.frame)
    let intersectionArea = max(0, intersection.width) * max(0, intersection.height)
    let unionArea =
      candidate.frame.width * candidate.frame.height
      + target.frame.width * target.frame.height
      - intersectionArea
    let overlap = unionArea > 0 ? intersectionArea / unionArea : 0

    let targetTitle = normalizedTitle(target.title)
    let candidateTitle = normalizedTitle(candidate.title)
    let titleBonus: Double
    if !targetTitle.isEmpty, targetTitle == candidateTitle {
      titleBonus = 0.4
    } else if targetTitle.isEmpty || candidateTitle.isEmpty {
      titleBonus = 0.05
    } else {
      titleBonus = 0
    }

    return overlap + titleBonus
  }

  private static func normalizedTitle(_ title: String?) -> String {
    title?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
  }
}
