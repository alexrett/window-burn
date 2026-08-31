public struct WetPaperDamage: Equatable, Sendable {
  public let wrinkle: Float
  public let rupture: Float

  public init(wrinkle: Float, rupture: Float) {
    self.wrinkle = wrinkle
    self.rupture = rupture
  }
}

public struct WetVisualProfile: Equatable, Sendable {
  public let refractionStrength: Float
  public let dispersionStrength: Float
  public let reflectionStrength: Float
  public let highlightIntensity: Float
  public let dropletDensity: Float
  public let impactRadius: Float
  public let absorptionRadius: Float
  public let verticalSag: Float
  public let urineTintStrength: Float
  public let backgroundBlurRadius: Float
  public let backgroundBlurStrength: Float
  public let wrinkleStartDensity: Float
  public let wrinkleFullDensity: Float
  public let tearStartDensity: Float
  public let tearFullDensity: Float

  public init(
    refractionStrength: Float,
    dispersionStrength: Float,
    reflectionStrength: Float,
    highlightIntensity: Float,
    dropletDensity: Float,
    impactRadius: Float,
    absorptionRadius: Float,
    verticalSag: Float,
    urineTintStrength: Float,
    backgroundBlurRadius: Float,
    backgroundBlurStrength: Float,
    wrinkleStartDensity: Float,
    wrinkleFullDensity: Float,
    tearStartDensity: Float,
    tearFullDensity: Float
  ) {
    self.refractionStrength = refractionStrength
    self.dispersionStrength = dispersionStrength
    self.reflectionStrength = reflectionStrength
    self.highlightIntensity = highlightIntensity
    self.dropletDensity = dropletDensity
    self.impactRadius = impactRadius
    self.absorptionRadius = absorptionRadius
    self.verticalSag = verticalSag
    self.urineTintStrength = urineTintStrength
    self.backgroundBlurRadius = backgroundBlurRadius
    self.backgroundBlurStrength = backgroundBlurStrength
    self.wrinkleStartDensity = wrinkleStartDensity
    self.wrinkleFullDensity = wrinkleFullDensity
    self.tearStartDensity = tearStartDensity
    self.tearFullDensity = tearFullDensity
  }

  public func paperDamage(atDensity density: Float) -> WetPaperDamage {
    WetPaperDamage(
      wrinkle: Self.smoothstep(
        from: wrinkleStartDensity,
        to: wrinkleFullDensity,
        value: density
      ),
      rupture: Self.smoothstep(
        from: tearStartDensity,
        to: tearFullDensity,
        value: density
      )
    )
  }

  private static func smoothstep(from lowerBound: Float, to upperBound: Float, value: Float)
    -> Float
  {
    let progress = min(max((value - lowerBound) / (upperBound - lowerBound), 0), 1)
    return progress * progress * (3 - 2 * progress)
  }

  public static let cinematic = WetVisualProfile(
    refractionStrength: 0.00045,
    dispersionStrength: 0.000008,
    reflectionStrength: 0.028,
    highlightIntensity: 0.20,
    dropletDensity: 0.055,
    impactRadius: 0.064,
    absorptionRadius: 0.155,
    verticalSag: 0.034,
    urineTintStrength: 0.56,
    backgroundBlurRadius: 0.024,
    backgroundBlurStrength: 0.90,
    wrinkleStartDensity: 0.62,
    wrinkleFullDensity: 1.80,
    tearStartDensity: 3.0,
    tearFullDensity: 5.4
  )
}
