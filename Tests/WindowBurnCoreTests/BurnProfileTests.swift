import Testing

@testable import WindowBurnCore

@Suite("Random burn profile")
struct BurnProfileTests {
  @Test("Profiles stay inside the fast, visually safe ranges")
  func valuesStayInRange() {
    var generator = SeededGenerator(seed: 0xB0_11_5E_ED)

    for _ in 0..<200 {
      let profile = BurnProfile.random(using: &generator)

      #expect((0.62...0.88).contains(profile.duration))
      #expect((0...10_000).contains(profile.seed))
      #expect((-0.16...0.16).contains(profile.tilt))
      #expect((0.78...1.38).contains(profile.turbulence))
      #expect((0.075...0.13).contains(profile.charWidth))
    }
  }

  @Test("The same generator seed reproduces a burn")
  func deterministicForTesting() {
    var firstGenerator = SeededGenerator(seed: 41)
    var secondGenerator = SeededGenerator(seed: 41)

    let first = BurnProfile.random(using: &firstGenerator)
    let second = BurnProfile.random(using: &secondGenerator)

    #expect(first == second)
  }

  @Test("Consecutive burns vary")
  func consecutiveBurnsVary() {
    var generator = SeededGenerator(seed: 9)

    let first = BurnProfile.random(using: &generator)
    let second = BurnProfile.random(using: &generator)

    #expect(first != second)
  }

  @Test("Torch profiles burn slowly")
  func torchValuesStayInRange() {
    var generator = SeededGenerator(seed: 0xFA_CE)

    for _ in 0..<100 {
      let profile = BurnProfile.randomTorch(using: &generator)

      #expect((6.0...8.0).contains(profile.duration))
      #expect((0...10_000).contains(profile.seed))
      #expect(profile.tilt == 0)
      #expect((0.90...1.45).contains(profile.turbulence))
      #expect((0.055...0.09).contains(profile.charWidth))
    }
  }
}

private struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
