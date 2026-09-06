import CoreGraphics
import Foundation
import Testing

@testable import WindowBurnCore

@Suite struct PointerTargetSnapshotTests {
  private let point = CGPoint(x: 50, y: 50)
  private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

  @Test func burningSurfaceWinsOverWindowUnderneathEvenAfterCacheExpires() {
    let surface = UUID()
    let native = UUID()
    let snapshot = PointerTargetSnapshot(
      regions: [.init(id: native, frame: frame)], capturedAt: 1
    )
    #expect(
      snapshot.target(at: point, now: 10, surfaces: [.init(id: surface, frame: frame)]) == surface)
    #expect(snapshot.target(at: point, now: 10) == nil)
  }

  @Test func unknownFrontWindowOrMenuBlocksWindowBehindIt() {
    let native = UUID()
    let snapshot = PointerTargetSnapshot(
      regions: [.init(id: nil, frame: frame), .init(id: native, frame: frame)], capturedAt: 1
    )
    #expect(snapshot.target(at: point, now: 1.1) == nil)
  }

  @Test func frontmostSurfaceAndCloseButtonHitRegionsAreRespected() {
    let old = UUID()
    let new = UUID()
    let snapshot = PointerTargetSnapshot(regions: [], capturedAt: 1)
    #expect(
      snapshot.target(
        at: point, now: 1, surfaces: [.init(id: new, frame: frame), .init(id: old, frame: frame)])
        == new)
    let closeOnly = PointerTargetSnapshot(
      regions: [
        .init(id: old, frame: CGRect(x: 10, y: 10, width: 12, height: 12)),
        .init(id: nil, frame: frame),
      ], capturedAt: 1)
    #expect(closeOnly.target(at: point, now: 1) == nil)
    #expect(closeOnly.target(at: CGPoint(x: 15, y: 15), now: 1) == old)
  }
}
