import Testing

@testable import WindowBurnCore

@Suite("Stateful combustion")
struct CombustionModelTests {
  @Test("Dry material ignites and loses fuel")
  func dryMaterialBurns() {
    let next = CombustionModel.step(
      state: CombustionCellState(heat: 1, moisture: 0, fuel: 1, damage: 0),
      neighboringHeat: 0.8,
      sourceHeat: 1,
      deltaTime: 1.0 / 60.0,
      profile: .cinematic
    )

    #expect(next.fuel < 1)
    #expect(next.damage > 0)
    #expect(next.heat > 0.9)
  }

  @Test("Moisture consumes heat before the material burns")
  func moistureDelaysCombustion() {
    let dry = CombustionModel.step(
      state: CombustionCellState(heat: 1, moisture: 0, fuel: 1, damage: 0),
      neighboringHeat: 0.8,
      sourceHeat: 1,
      deltaTime: 1.0 / 60.0,
      profile: .cinematic
    )
    let wet = CombustionModel.step(
      state: CombustionCellState(heat: 1, moisture: 1, fuel: 1, damage: 0),
      neighboringHeat: 0.8,
      sourceHeat: 1,
      deltaTime: 1.0 / 60.0,
      profile: .cinematic
    )

    #expect(wet.moisture < 1)
    #expect(wet.fuel > dry.fuel)
    #expect(wet.damage < dry.damage)
  }

  @Test("Evaporation removes heat from wet material")
  func evaporationCoolsMaterial() {
    let dry = CombustionModel.step(
      state: CombustionCellState(heat: 0, moisture: 0, fuel: 0, damage: 1),
      neighboringHeat: 0,
      sourceHeat: 1,
      deltaTime: 1.0 / 15.0,
      profile: .cinematic
    )
    let wet = CombustionModel.step(
      state: CombustionCellState(heat: 0, moisture: 1, fuel: 0, damage: 1),
      neighboringHeat: 0,
      sourceHeat: 1,
      deltaTime: 1.0 / 15.0,
      profile: .cinematic
    )

    #expect(wet.heat < dry.heat)
    #expect(wet.moisture < 1)
  }

  @Test("A sustained flame eventually dries and burns soaked material")
  func sustainedHeatOvercomesMoisture() {
    var state = CombustionCellState(heat: 0, moisture: 1, fuel: 1, damage: 0)

    for _ in 0..<(60 * 4) {
      state = CombustionModel.step(
        state: state,
        neighboringHeat: 0.9,
        sourceHeat: 1,
        deltaTime: 1.0 / 60.0,
        profile: .cinematic
      )
    }

    #expect(state.moisture < 0.05)
    #expect(state.fuel < 0.1)
    #expect(state.damage > 0.9)
  }

  @Test("Damage is monotonic and all channels stay bounded")
  func stateRemainsStable() {
    let initial = CombustionCellState(heat: 4, moisture: -1, fuel: 0.4, damage: 0.7)
    let next = CombustionModel.step(
      state: initial,
      neighboringHeat: 3,
      sourceHeat: 5,
      deltaTime: 1,
      profile: .cinematic
    )

    #expect(next.heat >= 0 && next.heat <= CombustionProfile.cinematic.maximumHeat)
    #expect(next.moisture >= 0 && next.moisture <= 1)
    #expect(next.fuel >= 0 && next.fuel <= 1)
    #expect(next.damage >= initial.damage && next.damage <= 1)
  }

  @Test("Heated soaked material steams visibly before it flames")
  func wetMaterialProducesVisibleSteam() {
    let response = CombustionVisualModel.response(
      depositedMoisture: 1,
      remainingMoisture: 0.72,
      heat: 1,
      damage: 0.05,
      progress: 0.45,
      isRadial: true
    )

    #expect(response.steamOpacity >= 0.35)
    #expect(response.fireVisibility <= 0.10)
  }

  @Test("Dry material does not create a steam cloud")
  func dryMaterialDoesNotSteam() {
    let response = CombustionVisualModel.response(
      depositedMoisture: 0,
      remainingMoisture: 0,
      heat: 1,
      damage: 0.2,
      progress: 0.45,
      isRadial: true
    )

    #expect(response.steamOpacity == 0)
    #expect(response.fireVisibility > 0.9)
  }

  @Test("Freshly ignited material does not darken before it is damaged")
  func undamagedMaterialDoesNotScorch() {
    let fresh = CombustionVisualModel.response(
      depositedMoisture: 0.8,
      remainingMoisture: 0.8,
      heat: 1,
      damage: 0,
      progress: 0.1,
      isRadial: true
    )
    let damaged = CombustionVisualModel.response(
      depositedMoisture: 0.8,
      remainingMoisture: 0.2,
      heat: 1,
      damage: 0.25,
      progress: 0.3,
      isRadial: true
    )

    #expect(fresh.scorchOpacity == 0)
    #expect(damaged.scorchOpacity > fresh.scorchOpacity)
  }

  @Test("Radial fire collapses before it can linger on a window edge")
  func radialFireHasNoTerminalTail() {
    let response = CombustionVisualModel.response(
      depositedMoisture: 0,
      remainingMoisture: 0,
      heat: 1,
      damage: 0.7,
      progress: 0.82,
      isRadial: true
    )

    #expect(response.effectVisibility < 0.01)
    #expect(response.materialVisibility < 0.01)
  }

  @Test("Radial fire fades before rectangular clipping can create a straight seam")
  func radialFireFadesAtPhysicalBorder() {
    let atBorder = CombustionVisualModel.borderVisibility(
      distanceToBorder: 0,
      fadeWidth: 0.085,
      isRadial: true
    )
    let approachingBorder = CombustionVisualModel.borderVisibility(
      distanceToBorder: 0.03,
      fadeWidth: 0.085,
      isRadial: true
    )
    let safelyInside = CombustionVisualModel.borderVisibility(
      distanceToBorder: 0.10,
      fadeWidth: 0.085,
      isRadial: true
    )
    let sweepAtBorder = CombustionVisualModel.borderVisibility(
      distanceToBorder: 0,
      fadeWidth: 0.085,
      isRadial: false
    )

    #expect(atBorder == 0)
    #expect(approachingBorder > atBorder)
    #expect(approachingBorder < safelyInside)
    #expect(safelyInside == 1)
    #expect(sweepAtBorder == 1)
  }

  @Test("Terminal fade leaves the active middle of a burn untouched")
  func terminalFadeStartsLate() {
    let response = CombustionVisualModel.response(
      depositedMoisture: 0,
      remainingMoisture: 0,
      heat: 1,
      damage: 0.4,
      progress: 0.52,
      isRadial: true
    )

    #expect(response.effectVisibility == 1)
    #expect(response.materialVisibility > 0)
  }

  @Test("A radial overlay closes as soon as its visible burn has collapsed")
  func radialOverlayDoesNotLeaveAnEmptyFrame() {
    #expect(CombustionVisualModel.completionProgress(isRadial: true) == 0.82)
    #expect(CombustionVisualModel.completionProgress(isRadial: false) == 1)
  }
}
