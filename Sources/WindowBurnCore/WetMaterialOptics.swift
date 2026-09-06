import Foundation

/// Thin-film optics; color is transmitted through liquid, with a separate specular reflection.
public enum WetMaterialOptics {
  public static let refractiveIndex: Float = 1.333

  public static func reflectance(cosine: Float) -> Float {
    let normalReflection = pow((1 - refractiveIndex) / (1 + refractiveIndex), 2)
    return normalReflection + (1 - normalReflection) * pow(1 - min(max(cosine, 0), 1), 5)
  }

  public static func transmittance(density: Float, tintStrength: Float) -> SIMD3<Float> {
    let opticalDepth = max(0, density) * max(0, tintStrength)
    return SIMD3(
      exp(-opticalDepth * 0.11),
      exp(-opticalDepth * 0.26),
      exp(-opticalDepth * 1.15)
    )
  }
}
