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
    nextHeat = max(
      0,
      nextHeat - evaporatedMoisture * profile.moistureResistance * 0.85
    )
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

public struct CombustionVisualResponse: Equatable, Sendable {
  public let fireVisibility: Float
  public let steamOpacity: Float
  public let scorchOpacity: Float
  public let effectVisibility: Float
  public let materialVisibility: Float

  public init(
    fireVisibility: Float,
    steamOpacity: Float,
    scorchOpacity: Float,
    effectVisibility: Float,
    materialVisibility: Float
  ) {
    self.fireVisibility = fireVisibility
    self.steamOpacity = steamOpacity
    self.scorchOpacity = scorchOpacity
    self.effectVisibility = effectVisibility
    self.materialVisibility = materialVisibility
  }
}

public enum CombustionVisualModel {
  public static func completionProgress(isRadial: Bool) -> Float {
    isRadial ? 0.82 : 1
  }

  public static func response(
    depositedMoisture: Float,
    remainingMoisture: Float,
    heat: Float,
    damage: Float,
    progress: Float,
    isRadial: Bool
  ) -> CombustionVisualResponse {
    let depositedMoisture = clamp(depositedMoisture)
    let remainingMoisture = min(clamp(remainingMoisture), depositedMoisture)
    let heat = max(0, heat)
    let damage = clamp(damage)
    let progress = clamp(progress)

    let moistureDamping = 1 - smoothstep(0.08, 0.72, remainingMoisture) * 0.96
    let evaporatedMoisture = max(0, depositedMoisture - remainingMoisture)
    let boilingMoisture =
      smoothstep(0.12, 0.78, heat)
      * max(
        smoothstep(0.02, 0.32, evaporatedMoisture),
        smoothstep(0.16, 0.76, remainingMoisture) * 0.75
      )
    let steamOpacity = min(0.62, boilingMoisture * 0.62)
    let scorchOpacity =
      smoothstep(0.06, 0.34, damage)
      * (1 - smoothstep(0.72, 0.98, damage))

    let effectVisibility =
      isRadial
      ? 1 - smoothstep(0.60, 0.82, progress)
      : 1
    let terminalMaterialVisibility =
      isRadial
      ? 1 - smoothstep(0.70, 0.82, progress)
      : 1
    let undamagedMaterial = 1 - smoothstep(0.50, 0.98, damage)

    return CombustionVisualResponse(
      fireVisibility: moistureDamping,
      steamOpacity: steamOpacity,
      scorchOpacity: scorchOpacity,
      effectVisibility: effectVisibility,
      materialVisibility: undamagedMaterial * terminalMaterialVisibility
    )
  }

  private static func clamp(_ value: Float) -> Float {
    min(1, max(0, value))
  }

  private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    let normalized = clamp((value - edge0) / (edge1 - edge0))
    return normalized * normalized * (3 - 2 * normalized)
  }
}
