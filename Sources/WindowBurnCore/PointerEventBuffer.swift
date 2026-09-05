import CoreGraphics
import Foundation

public struct PointerInputEvent: Equatable, Sendable {
  public enum Kind: Equatable, Sendable {
    case down
    case dragged
    case up
    case moved

    fileprivate var isMotion: Bool { self == .dragged || self == .moved }
  }

  public let kind: Kind
  public let point: CGPoint
  public let timestamp: UInt64
  public let sequenceID: UInt64
  public let targetID: UUID?

  public init(
    kind: Kind,
    point: CGPoint,
    timestamp: UInt64,
    sequenceID: UInt64,
    targetID: UUID? = nil
  ) {
    self.kind = kind
    self.point = point
    self.timestamp = timestamp
    self.sequenceID = sequenceID
    self.targetID = targetID
  }
}

/// A bounded handoff from a pointer callback to an asynchronously serviced UI.
/// The owner must serialize access. Draining retains pointer freshness and the
/// release reservation for an accepted gesture whose button is still held.
public struct PointerEventBuffer: Sendable {
  private struct Gesture: Equatable, Sendable {
    let sequenceID: UInt64
    let targetID: UUID?

    init(_ event: PointerInputEvent) {
      sequenceID = event.sequenceID
      targetID = event.targetID
    }
  }

  public let capacity: Int
  public private(set) var latestPointerEvent: PointerInputEvent?
  public var count: Int { events.count }
  public var isGestureActive: Bool { activeGesture != nil }

  private var events: [PointerInputEvent] = []
  private var activeGesture: Gesture?

  public init(capacity: Int = 128) {
    precondition(capacity >= 2, "A pointer buffer must hold a complete click")
    self.capacity = capacity
    events.reserveCapacity(capacity)
  }

  /// Returns whether the event entered the delivery queue. A fresh event that
  /// cannot fit still updates the pointer snapshot. Stale or mismatched gesture
  /// events change neither the queue nor that snapshot.
  @discardableResult
  public mutating func append(_ event: PointerInputEvent) -> Bool {
    if let latestPointerEvent, event.timestamp < latestPointerEvent.timestamp {
      return false
    }
    switch event.kind {
    case .down:
      guard activeGesture == nil else { return false }
    case .dragged, .up:
      guard activeGesture == Gesture(event) else { return false }
    case .moved:
      break
    }
    latestPointerEvent = event

    switch event.kind {
    case .down:
      // Reserve both this down and its eventual up before accepting the click.
      guard makeRoom(for: 2) else { return false }
      events.append(event)
      activeGesture = Gesture(event)
    case .up:
      // Every successful down reserved this slot, including across a UI drain.
      events.append(event)
      activeGesture = nil
    case .dragged, .moved:
      if let last = events.last,
        last.kind == event.kind,
        last.sequenceID == event.sequenceID,
        last.targetID == event.targetID
      {
        events[events.count - 1] = event
        return true
      }
      let reservedRelease = isGestureActive ? 1 : 0
      guard makeRoom(for: 1 + reservedRelease) else { return false }
      events.append(event)
    }
    return true
  }

  public mutating func drain() -> [PointerInputEvent] {
    let pending = events
    events.removeAll(keepingCapacity: true)
    return pending
  }

  private mutating func makeRoom(for requiredSlots: Int) -> Bool {
    while events.count + requiredSlots > capacity {
      guard let index = events.firstIndex(where: { $0.kind.isMotion }) else {
        return false
      }
      events.remove(at: index)
    }
    return true
  }
}
