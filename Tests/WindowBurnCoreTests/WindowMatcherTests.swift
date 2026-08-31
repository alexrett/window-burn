import CoreGraphics
import Testing

@testable import WindowBurnCore

@Suite("ScreenCaptureKit window matching")
struct WindowMatcherTests {
  @Test("Prefers the same process, title, and nearest frame")
  func prefersExactWindow() throws {
    let target = TargetWindow(
      ownerPID: 42,
      title: "Notes",
      frame: CGRect(x: 120, y: 80, width: 800, height: 600)
    )
    let candidates = [
      WindowCandidate(
        id: 1,
        ownerPID: 99,
        title: "Notes",
        frame: target.frame,
        isOnScreen: true
      ),
      WindowCandidate(
        id: 2,
        ownerPID: 42,
        title: "Other",
        frame: CGRect(x: 1_000, y: 80, width: 800, height: 600),
        isOnScreen: true
      ),
      WindowCandidate(
        id: 3,
        ownerPID: 42,
        title: "Notes",
        frame: CGRect(x: 122, y: 82, width: 796, height: 596),
        isOnScreen: true
      ),
    ]

    let result = try #require(WindowMatcher.bestMatch(for: target, among: candidates))

    #expect(result.id == 3)
  }

  @Test("Does not select off-screen or foreign-process windows")
  func rejectsInvalidCandidates() {
    let target = TargetWindow(
      ownerPID: 42,
      title: "Terminal",
      frame: CGRect(x: 0, y: 0, width: 640, height: 480)
    )
    let candidates = [
      WindowCandidate(
        id: 1,
        ownerPID: 42,
        title: "Terminal",
        frame: target.frame,
        isOnScreen: false
      ),
      WindowCandidate(
        id: 2,
        ownerPID: 7,
        title: "Terminal",
        frame: target.frame,
        isOnScreen: true
      ),
    ]

    #expect(WindowMatcher.bestMatch(for: target, among: candidates) == nil)
  }
}

@Suite("WindowServer point matching")
struct WindowAtPointMatcherTests {
  @Test("Chooses the frontmost normal window and ignores overlays and the caller")
  func choosesFrontmostEligibleWindow() throws {
    let point = CGPoint(x: 400, y: 300)
    let sharedFrame = CGRect(x: 100, y: 100, width: 800, height: 600)
    let candidates = [
      PointWindowCandidate(
        id: 1,
        ownerPID: 99,
        title: "Torch cursor",
        frame: sharedFrame,
        layer: 25,
        isOnScreen: true,
        alpha: 1
      ),
      PointWindowCandidate(
        id: 2,
        ownerPID: 42,
        title: "Own overlay",
        frame: sharedFrame,
        layer: 0,
        isOnScreen: true,
        alpha: 1
      ),
      PointWindowCandidate(
        id: 3,
        ownerPID: 650,
        title: "Telegram",
        frame: sharedFrame,
        layer: 0,
        isOnScreen: true,
        alpha: 1
      ),
      PointWindowCandidate(
        id: 4,
        ownerPID: 7,
        title: "Behind",
        frame: sharedFrame,
        layer: 0,
        isOnScreen: true,
        alpha: 1
      ),
    ]

    let result = try #require(
      WindowAtPointMatcher.frontmost(
        at: point,
        amongFrontToBack: candidates,
        excludingPID: 42
      )
    )

    #expect(result.id == 3)
  }

  @Test("Rejects invisible and transparent windows")
  func rejectsInvisibleWindows() {
    let point = CGPoint(x: 20, y: 20)
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let candidates = [
      PointWindowCandidate(
        id: 1,
        ownerPID: 8,
        title: nil,
        frame: frame,
        layer: 0,
        isOnScreen: false,
        alpha: 1
      ),
      PointWindowCandidate(
        id: 2,
        ownerPID: 9,
        title: nil,
        frame: frame,
        layer: 0,
        isOnScreen: true,
        alpha: 0
      ),
    ]

    #expect(
      WindowAtPointMatcher.frontmost(
        at: point,
        amongFrontToBack: candidates,
        excludingPID: 42
      ) == nil
    )
  }
}
