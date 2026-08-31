import Foundation

public struct BurnProfile: Equatable, Sendable {
  public let duration: TimeInterval
  public let seed: Float
  public let tilt: Float
  public let turbulence: Float
  public let charWidth: Float

  public init(
    duration: TimeInterval,
    seed: Float,
    tilt: Float,
    turbulence: Float,
    charWidth: Float
  ) {
    self.duration = duration
    self.seed = seed
    self.tilt = tilt
    self.turbulence = turbulence
    self.charWidth = charWidth
  }

  public static func random() -> BurnProfile {
    var generator = SystemRandomNumberGenerator()
    return random(using: &generator)
  }

  public static func random<Generator: RandomNumberGenerator>(
    using generator: inout Generator
  ) -> BurnProfile {
    BurnProfile(
      duration: .random(in: 0.62...0.88, using: &generator),
      seed: .random(in: 0...10_000, using: &generator),
      tilt: .random(in: -0.16...0.16, using: &generator),
      turbulence: .random(in: 0.78...1.38, using: &generator),
      charWidth: .random(in: 0.075...0.13, using: &generator)
    )
  }

  public static func randomTorch() -> BurnProfile {
    var generator = SystemRandomNumberGenerator()
    return randomTorch(using: &generator)
  }

  public static func randomTorch<Generator: RandomNumberGenerator>(
    using generator: inout Generator
  ) -> BurnProfile {
    BurnProfile(
      duration: .random(in: 6.0...8.0, using: &generator),
      seed: .random(in: 0...10_000, using: &generator),
      tilt: 0,
      turbulence: .random(in: 0.90...1.45, using: &generator),
      charWidth: .random(in: 0.055...0.09, using: &generator)
    )
  }
}
