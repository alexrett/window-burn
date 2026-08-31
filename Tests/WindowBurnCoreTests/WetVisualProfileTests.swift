import Testing

@testable import WindowBurnCore

@Suite("Cinematic wet-surface visual profile")
struct WetVisualProfileTests {
  @Test("An absorbed stain barely refracts the window")
  func opticalDistortionStaysSubtle() {
    let profile = WetVisualProfile.cinematic

    #expect((0.0002...0.0009).contains(profile.refractionStrength))
    #expect(profile.dispersionStrength > 0)
    #expect(profile.dispersionStrength < profile.refractionStrength)
  }

  @Test("The stain remains matte while the absorbed background stays blurred")
  func matteStainPreservesTheCapturedWindow() {
    let profile = WetVisualProfile.cinematic

    #expect((0.015...0.06).contains(profile.reflectionStrength))
    #expect((0.10...0.32).contains(profile.highlightIntensity))
    #expect((0.40...0.68).contains(profile.urineTintStrength))
    #expect((0.018...0.032).contains(profile.backgroundBlurRadius))
    #expect((0.82...0.98).contains(profile.backgroundBlurStrength))
  }

  @Test("Droplets break up the impact without carpeting the wet patch")
  func dropletsStaySparse() {
    #expect((0.03...0.09).contains(WetVisualProfile.cinematic.dropletDensity))
  }

  @Test("The absorbed patch expands locally with a small downward sag")
  func absorptionStaysLocal() {
    let profile = WetVisualProfile.cinematic

    #expect((0.055...0.085).contains(profile.impactRadius))
    #expect((0.13...0.19).contains(profile.absorptionRadius))
    #expect(profile.absorptionRadius > profile.impactRadius)
    #expect(profile.absorptionRadius < 0.22)
    #expect((0.02...0.05).contains(profile.verticalSag))
    #expect(profile.verticalSag < profile.absorptionRadius)
  }

  @Test("Prolonged soaking wrinkles the paper before it tears")
  func prolongedSoakingDamagesPaperGradually() {
    let profile = WetVisualProfile.cinematic

    #expect(profile.wrinkleStartDensity > 0.5)
    #expect(profile.wrinkleFullDensity > profile.wrinkleStartDensity)
    #expect(profile.tearStartDensity > profile.wrinkleFullDensity)
    #expect(profile.tearFullDensity > profile.tearStartDensity)

    let dry = profile.paperDamage(atDensity: 0)
    let wrinkling = profile.paperDamage(
      atDensity: (profile.wrinkleStartDensity + profile.wrinkleFullDensity) * 0.5
    )
    let weakening = profile.paperDamage(
      atDensity: (profile.tearStartDensity + profile.tearFullDensity) * 0.5
    )
    let torn = profile.paperDamage(atDensity: profile.tearFullDensity + 1)

    #expect(dry.wrinkle == 0)
    #expect(dry.rupture == 0)
    #expect((0..<1).contains(wrinkling.wrinkle))
    #expect(wrinkling.rupture == 0)
    #expect((0..<1).contains(weakening.rupture))
    #expect(torn.wrinkle == 1)
    #expect(torn.rupture == 1)
  }
}
