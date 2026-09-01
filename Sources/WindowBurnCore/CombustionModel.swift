public struct CombustionProfile: Equatable, Sendable {
  public let ignitionThreshold: Float
  public let moistureResistance: Float
  public let evaporationRate: Float
  public let fuelBurnRate: Float
  public let heatDecay: Float
  public let spreadRate: Float
  public let heatRelease: Float
  public let maximumHeat: Float

  public init(
    ignitionThreshold: Float,
    moistureResistance: Float,
    evaporationRate: Float,
    fuelBurnRate: Float,
    heatDecay: Float,
    spreadRate: Float,
    heatRelease: Float,
    maximumHeat: Float
  ) {
    self.ignitionThreshold = ignitionThreshold
    self.moistureResistance = moistureResistance
    self.evaporationRate = evaporationRate
    self.fuelBurnRate = fuelBurnRate
    self.heatDecay = heatDecay
    self.spreadRate = spreadRate
    self.heatRelease = heatRelease
    self.maximumHeat = maximumHeat
  }

  public static let cinematic = CombustionProfile(
    ignitionThreshold: 0.22,
    moistureResistance: 0.95,
    evaporationRate: 1.35,
    fuelBurnRate: 3.8,
    heatDecay: 0.42,
    spreadRate: 0.92,
    heatRelease: 0.85,
    maximumHeat: 1.5
  )
}

public struct CombustionCellState: Equatable, Sendable {
  public let heat: Float
  public let moisture: Float
  public let fuel: Float
  public let damage: Float

  public init(heat: Float, moisture: Float, fuel: Float, damage: Float) {
    self.heat = heat
    self.moisture = moisture
    self.fuel = fuel
    self.damage = damage
  }
}

public enum CombustionModel {
  public static func step(
    state: CombustionCellState,
    neighboringHeat: Float,
    sourceHeat: Float,
    deltaTime: Float,
    profile: CombustionProfile
  ) -> CombustionCellState {
    let deltaTime = min(max(deltaTime, 0), 1.0 / 15.0)
    let heat = min(max(state.heat, 0), profile.maximumHeat)
    let moisture = min(max(state.moisture, 0), 1)
    let fuel = min(max(state.fuel, 0), 1)
    let damage = min(max(state.damage, 0), 1)

    let retainedHeat = heat * max(0, 1 - profile.heatDecay * deltaTime)
    let spreadHeat = min(max(neighboringHeat, 0), profile.maximumHeat) * profile.spreadRate
    var nextHeat = min(
      max(max(retainedHeat, spreadHeat), max(sourceHeat, 0)),
      profile.maximumHeat
    )

    let evaporatedMoisture = min(
      moisture,
      nextHeat * profile.evaporationRate * deltaTime
    )
    let nextMoisture = moisture - evaporatedMoisture
    let combustibleHeat = max(
      0,
      nextHeat - profile.ignitionThreshold - nextMoisture * profile.moistureResistance
    )
    let burnedFuel = min(fuel, combustibleHeat * profile.fuelBurnRate * deltaTime)
    let nextFuel = fuel - burnedFuel
    nextHeat = min(nextHeat + burnedFuel * profile.heatRelease, profile.maximumHeat)

    return CombustionCellState(
      heat: nextHeat,
      moisture: nextMoisture,
      fuel: nextFuel,
      damage: max(damage, 1 - nextFuel)
    )
  }
}
