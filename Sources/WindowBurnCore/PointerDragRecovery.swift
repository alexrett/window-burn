import CoreGraphics

/// Reconciles a captured gesture with hardware state when an event tap loses events.
public struct PointerDragRecovery {
  public enum Update: Equatable { case dragged, up }
  public private(set) var isActive = false
  private var lastPoint = CGPoint.zero

  public init() {}

  public mutating func begin(at point: CGPoint) {
    isActive = true
    lastPoint = point
  }

  public mutating func end() { isActive = false }

  public mutating func sample(at point: CGPoint, isPressed: Bool) -> Update? {
    guard isActive else { return nil }
    guard isPressed else {
      end()
      return .up
    }
    guard point != lastPoint else { return nil }
    lastPoint = point
    return .dragged
  }
}
