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
