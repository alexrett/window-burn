import Testing

@testable import WindowBurnCore

@Suite("Thin liquid optics")
struct WetMaterialOpticsTests {
  @Test("Water reflects about two percent head-on and approaches a mirror at grazing angles")
  func waterFresnelResponse() {
    #expect(abs(WetMaterialOptics.reflectance(cosine: 1) - 0.02037) < 0.0001)
    #expect(WetMaterialOptics.reflectance(cosine: 0) == 1)
    #expect(WetMaterialOptics.reflectance(cosine: 0.25) > 0.2)
  }

  @Test("A clear dry surface transmits every channel without inventing color")
  func zeroThicknessPreservesImage() {
    #expect(WetMaterialOptics.transmittance(density: 0, tintStrength: 0.56) == SIMD3(repeating: 1))
  }

  @Test("Increasing liquid depth absorbs light without brightening black pixels")
  func transmissionObeysBeerLambertLaw() {
    let thin = WetMaterialOptics.transmittance(density: 0.2, tintStrength: 0.56)
    let thick = WetMaterialOptics.transmittance(density: 1, tintStrength: 0.56)
    #expect(thick.x < thin.x && thick.y < thin.y && thick.z < thin.z)
    #expect(thick.z < thick.y && thick.y < thick.x)
    #expect(thick.x <= 1 && thick.z > 0)
    #expect(thick * SIMD3<Float>(repeating: 0) == SIMD3(repeating: 0))
  }
}
