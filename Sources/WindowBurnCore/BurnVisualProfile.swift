public struct BurnVisualProfile: Equatable, Sendable {
  public let hotCoreWidth: Float
  public let emberWidth: Float
  public let glowWidth: Float
  public let flameReach: Float
  public let sparkDensity: Float
  public let residualCharOpacity: Float

  public init(
    hotCoreWidth: Float,
    emberWidth: Float,
    glowWidth: Float,
    flameReach: Float,
    sparkDensity: Float,
    residualCharOpacity: Float
  ) {
    self.hotCoreWidth = hotCoreWidth
    self.emberWidth = emberWidth
    self.glowWidth = glowWidth
    self.flameReach = flameReach
    self.sparkDensity = sparkDensity
    self.residualCharOpacity = residualCharOpacity
  }

  public static let cinematic = BurnVisualProfile(
    hotCoreWidth: 0.0038,
    emberWidth: 0.024,
    glowWidth: 0.094,
    flameReach: 0.20,
    sparkDensity: 0.28,
    residualCharOpacity: 0
  )
}
