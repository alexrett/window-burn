import Testing

@testable import WindowBurnCore

@Suite("Soak and burn mode")
struct SoakAndBurnTests {
  @Test("The gag advances from the liquid badge to the torch and resets after burning")
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
    #expect(SoakEffect.amount(heldFor: 99) > SoakEffect.amount(heldFor: 2))
  }

  @Test("A dragged stream keeps every spaced sample without a duration cap")
  func samplesDraggedStream() {
    var trail = SoakTrail()

    var didAdd = trail.add(BurnIgnitionPoint(x: 0.1, y: 0.1))
    #expect(didAdd)
    didAdd = trail.add(BurnIgnitionPoint(x: 0.11, y: 0.11))
    #expect(!didAdd)
    didAdd = trail.add(BurnIgnitionPoint(x: 0.3, y: 0.3))
    #expect(didAdd)

    var longTrail = SoakTrail()
    for index in 0..<128 {
      let column = index % 20
      let row = index / 20
      let point = BurnIgnitionPoint(
        x: Float(column) * 0.045,
        y: Float(row) * 0.045
      )
      let didAddPoint = longTrail.add(point)
      #expect(didAddPoint)
    }
    #expect(longTrail.points.count == 128)
  }

  @Test("Every wet sample can be deposited immediately while the newest impact stays live")
  func drainsWetSamplesForRasterization() {
    var queue = WetDepositQueue()
    var expectedLatestPoint: BurnIgnitionPoint?

    for index in 0..<100 {
      let column = index % 20
      let row = index / 20
      let point = BurnIgnitionPoint(
        x: Float(column) * 0.045,
        y: Float(row) * 0.045
      )
      let didAddPoint = queue.add(point)
      #expect(didAddPoint)
      expectedLatestPoint = point
    }

    let deposits = queue.takePendingDeposits()
    #expect(queue.totalPointCount == 100)
    #expect(deposits.count == 100)
    #expect(queue.pendingDeposits.isEmpty)
    #expect(queue.latestPoint == expectedLatestPoint)
    #expect(queue.takePendingDeposits().isEmpty)
  }

  @Test("The deposit queue preserves point spacing after a raster update")
  func preservesSpacingAfterRasterUpdate() {
    var queue = WetDepositQueue()

    var didAddPoint = queue.add(BurnIgnitionPoint(x: 0.1, y: 0.1))
    #expect(didAddPoint)
    didAddPoint = queue.add(BurnIgnitionPoint(x: 0.2, y: 0.2))
    #expect(didAddPoint)
    _ = queue.takePendingDeposits()

    let nearbyPoint = BurnIgnitionPoint(x: 0.21, y: 0.21)
    didAddPoint = queue.add(nearbyPoint)
    #expect(!didAddPoint)
    #expect(queue.latestPoint == nearbyPoint)
    didAddPoint = queue.add(BurnIgnitionPoint(x: 0.3, y: 0.3))
    #expect(didAddPoint)
  }

  @Test("Only the newest sample is the live impact while the nozzle is open")
  func keepsOneActiveImpact() {
    #expect(!SoakEffect.isActiveImpact(index: 0, count: 3, isSoaking: true))
    #expect(!SoakEffect.isActiveImpact(index: 1, count: 3, isSoaking: true))
    #expect(SoakEffect.isActiveImpact(index: 2, count: 3, isSoaking: true))
  }

  @Test("Closing the nozzle leaves wet imprints but no active impact")
  func deactivatesImpactAfterRelease() {
    #expect(!SoakEffect.isActiveImpact(index: 0, count: 1, isSoaking: false))
    #expect(!SoakEffect.isActiveImpact(index: 0, count: 0, isSoaking: true))
    #expect(!SoakEffect.isActiveImpact(index: 2, count: 2, isSoaking: true))
  }

  @Test("The special mode turns itself off once the burn starts")
  func disablesAfterIgnition() {
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .readyToSoak))
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .soaking))
    #expect(SoakAndBurnModePolicy.shouldRemainEnabled(after: .readyToBurn))
    #expect(!SoakAndBurnModePolicy.shouldRemainEnabled(after: .burning))
  }

  @Test("A dry overlay leaves the native window contour untouched until ignition")
  func preservesTheNativeWindowOutsideWetAreas() {
    #expect(WetPaperCompositing.sourceCoverage(effectCoverage: 0, isBurning: false) == 0)
    #expect(WetPaperCompositing.sourceCoverage(effectCoverage: 0.62, isBurning: false) == 0.62)
    #expect(WetPaperCompositing.sourceCoverage(effectCoverage: 0, isBurning: true) == 1)
  }

  @Test("The captured window is fully covered before the native window closes")
  func preparesAnAtomicBurnHandoff() {
    #expect(
      WetPaperCompositing.sourceCoverage(
        effectCoverage: 0,
        isBurning: false,
        isHandoffPrepared: true
      ) == 1
    )
  }

  @Test("A ruptured hole is no longer combustible material")
  func excludesHolesFromCombustion() {
    #expect(WetPaperCompositing.materialCoverage(ruptureCoverage: 0) == 1)
    #expect(WetPaperCompositing.materialCoverage(ruptureCoverage: 0.35) == 0.65)
    #expect(WetPaperCompositing.materialCoverage(ruptureCoverage: 1) == 0)
  }

  @Test("Wetness and torn edges contribute to the local overlay only")
  func combinesLocalEffectCoverage() {
    #expect(
      WetPaperCompositing.effectCoverage(
        absorption: 0.18,
        liquid: 0.44,
        droplet: 0.12,
        rupture: 0.72,
        tornEdge: 0.35
      ) == 0.72
    )
  }
}
