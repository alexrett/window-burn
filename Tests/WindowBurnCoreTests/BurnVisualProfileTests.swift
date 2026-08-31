import Testing

@testable import WindowBurnCore

@Suite("Cinematic burn visual profile")
struct BurnVisualProfileTests {
  @Test("The flame layers expand outwards from a narrow hot edge")
  func flameLayerWidthsAreOrdered() {
    let profile = BurnVisualProfile.cinematic

    #expect(profile.hotCoreWidth > 0)
    #expect(profile.hotCoreWidth < profile.emberWidth)
    #expect(profile.emberWidth < profile.glowWidth)
    #expect(profile.glowWidth < profile.flameReach)
  }

  @Test("Burned pixels disappear instead of leaving a charcoal mask")
  func burnedAreaIsTransparent() {
    #expect(BurnVisualProfile.cinematic.residualCharOpacity == 0)
  }

  @Test("Cinematic fire includes visible airborne sparks")
  func sparksAreEnabled() {
    #expect(BurnVisualProfile.cinematic.sparkDensity >= 0.25)
    #expect(BurnVisualProfile.cinematic.sparkDensity <= 0.6)
  }
}
