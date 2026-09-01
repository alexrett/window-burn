import CoreGraphics

public struct PixelSize: Equatable, Sendable {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }
}

public enum CapturePixelSizing {
  public static func pixelSize(
    for pointSize: CGSize,
    pointPixelScale: CGFloat
  ) -> PixelSize {
    let validScale = pointPixelScale > 0 ? pointPixelScale : 1
    return PixelSize(
      width: max(1, Int((pointSize.width * validScale).rounded(.toNearestOrAwayFromZero))),
      height: max(1, Int((pointSize.height * validScale).rounded(.toNearestOrAwayFromZero)))
    )
  }
}

public enum InteractiveRenderSizing {
  public static func pixelSize(
    for pointSize: CGSize,
    pointPixelScale: CGFloat,
    maximumPixelCount: Int
  ) -> PixelSize {
    let native = CapturePixelSizing.pixelSize(
      for: pointSize,
      pointPixelScale: pointPixelScale
    )
    let nativePixelCount = native.width * native.height
    guard maximumPixelCount > 0, nativePixelCount > maximumPixelCount else {
      return native
    }

    let reduction = sqrt(Double(maximumPixelCount) / Double(nativePixelCount))
    return PixelSize(
      width: max(1, Int((Double(native.width) * reduction).rounded(.down))),
      height: max(1, Int((Double(native.height) * reduction).rounded(.down)))
    )
  }
}

public enum BackdropCaptureGeometry {
  public static func displayIndex(
    containingMostOf windowFrame: CGRect,
    among displayFrames: [CGRect]
  ) -> Int? {
    var bestIndex: Int?
    var largestArea: CGFloat = 0
    for (index, displayFrame) in displayFrames.enumerated() {
      let intersection = windowFrame.intersection(displayFrame)
      let area = intersection.isNull ? 0 : intersection.width * intersection.height
      if area > largestArea {
        bestIndex = index
        largestArea = area
      }
    }
    return bestIndex
  }

  public static func sourceRect(
    for windowFrame: CGRect,
    in displayFrame: CGRect
  ) -> CGRect {
    CGRect(
      x: windowFrame.minX - displayFrame.minX,
      y: windowFrame.minY - displayFrame.minY,
      width: windowFrame.width,
      height: windowFrame.height
    )
  }
}

public enum ScreenCoordinateConverter {
  public static func appKitPoint(
    forQuartzPoint point: CGPoint,
    mainDisplayHeight: CGFloat
  ) -> CGPoint {
    CGPoint(x: point.x, y: mainDisplayHeight - point.y)
  }

  public static func appKitFrame(
    for captureFrame: CGRect,
    mainDisplayHeight: CGFloat,
    padding: CGFloat
  ) -> CGRect {
    CGRect(
      x: captureFrame.minX - padding,
      y: mainDisplayHeight - captureFrame.maxY - padding,
      width: captureFrame.width + padding * 2,
      height: captureFrame.height + padding * 2
    )
  }
}

public enum BurnTiming {
  public static func progress(elapsed: Double, duration: Double) -> Double {
    guard duration > 0 else { return 1 }
    return min(1, max(0, elapsed / duration))
  }
}

public enum OverlayDepthModel {
  public static func roundedRectangleSignedDistance(
    x: Float,
    y: Float,
    aspect: Float,
    cornerRadius: Float
  ) -> Float {
    let validAspect = max(0.001, aspect)
    let radius = min(0.5, validAspect * 0.5, max(0, cornerRadius))
    let distanceX = abs(x - 0.5) * validAspect - (validAspect * 0.5 - radius)
    let distanceY = abs(y - 0.5) - (0.5 - radius)
    let outsideX = max(0, distanceX)
    let outsideY = max(0, distanceY)
    let outside = sqrt(outsideX * outsideX + outsideY * outsideY)
    let inside = min(max(distanceX, distanceY), 0)
    return outside + inside - radius
  }

  public static func materialCoverage(
    sourceAlpha: Float,
    rectangleCoverage: Float
  ) -> Float {
    min(1, max(0, sourceAlpha)) * min(1, max(0, rectangleCoverage))
  }

  public static func exteriorShadowOpacity(
    outsideDistance: Float,
    materialVisibility: Float,
    isNativeWindowVisible: Bool
  ) -> Float {
    guard !isNativeWindowVisible else { return 0 }
    let distanceFade = 1 - smoothstep(0.006, 0.065, max(0, outsideDistance))
    let survivingMaterial = smoothstep(0.08, 0.72, materialVisibility)
    return distanceFade * survivingMaterial * 0.30
  }

  private static func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    let normalized = min(1, max(0, (value - edge0) / (edge1 - edge0)))
    return normalized * normalized * (3 - 2 * normalized)
  }
}
