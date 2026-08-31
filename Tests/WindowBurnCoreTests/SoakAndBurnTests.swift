import Testing

@testable import WindowBurnCore

@Suite("Soak and burn mode")
struct SoakAndBurnTests {
  @Test("The gag advances from dog to torch and resets after burning")
  func advancesThroughTwoActs() {
    var session = SoakAndBurnSession()

    #expect(session.phase == .readyToSoak)
    var didTransition = session.beginSoaking()
    #expect(didTransition)
    #expect(session.phase == .soaking)
    didTransition = session.finishSoaking()
    #expect(didTransition)
    #expect(session.phase == .readyToBurn)
    didTransition = session.beginBurning()
    #expect(didTransition)
    #expect(session.phase == .burning)

    session.reset()
    #expect(session.phase == .readyToSoak)
  }

  @Test("Invalid clicks cannot skip either act")
  func rejectsInvalidTransitions() {
    var session = SoakAndBurnSession()

    var didTransition = session.finishSoaking()
    #expect(!didTransition)
    didTransition = session.beginBurning()
    #expect(!didTransition)
    didTransition = session.beginSoaking()
    #expect(didTransition)
    didTransition = session.beginSoaking()
    #expect(!didTransition)
    didTransition = session.beginBurning()
    #expect(!didTransition)
  }

  @Test("Wetness grows while held and remains visibly wet after a tap")
  func wetnessGrowsWithHoldDuration() {
    #expect(SoakEffect.wetness(heldFor: -1) == 0.18)
    #expect(SoakEffect.wetness(heldFor: 0.9) > 0.45)
    #expect(SoakEffect.wetness(heldFor: 99) == 1)
  }

  @Test("A dragged stream samples spaced points without flooding the renderer")
  func samplesDraggedStream() {
    var trail = SoakTrail()

    var didAdd = trail.add(BurnIgnitionPoint(x: 0.1, y: 0.1))
    #expect(didAdd)
    didAdd = trail.add(BurnIgnitionPoint(x: 0.11, y: 0.11))
    #expect(!didAdd)
    didAdd = trail.add(BurnIgnitionPoint(x: 0.3, y: 0.3))
    #expect(didAdd)

    for index in 0..<(SoakTrail.maximumCount + 4) {
      _ = trail.add(BurnIgnitionPoint(x: Float(index) / 10, y: 0.8))
    }
    #expect(trail.points.count == SoakTrail.maximumCount)
  }

  @Test("The special mode turns itself off once the burn starts")
  func disablesAfterIgnition() {
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .readyToSoak))
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .soaking))
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .readyToBurn))
    #expect(!SoakAndBurnModePolicy.shouldRemainEnabled(after: .burning))
  }
}
