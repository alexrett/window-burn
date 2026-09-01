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
}
