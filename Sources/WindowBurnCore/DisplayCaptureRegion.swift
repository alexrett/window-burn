import CoreGraphics

/// A display crop with an explicit pixel destination, including transparent off-display padding.
public struct DisplayCaptureRegion: Equatable, Sendable {
  public let pixelSize: PixelSize
  public let sourceRect: CGRect
  public let destinationRect: CGRect

  public init?(
    captureFrame: CGRect,
    displayFrame: CGRect,
    pointPixelScale: CGFloat
  ) {
    guard
      pointPixelScale.isFinite, pointPixelScale > 0,
      !captureFrame.isEmpty, !displayFrame.isEmpty,
      [captureFrame, displayFrame].allSatisfy({ frame in
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite)
      })
    else { return nil }

    let clippedFrame = captureFrame.intersection(displayFrame)
    guard !clippedFrame.isNull, !clippedFrame.isEmpty else { return nil }

    pixelSize = CapturePixelSizing.pixelSize(
      for: captureFrame.size,
      pointPixelScale: pointPixelScale
    )
    sourceRect = CGRect(
      x: clippedFrame.minX - displayFrame.minX,
      y: clippedFrame.minY - displayFrame.minY,
      width: clippedFrame.width,
      height: clippedFrame.height
    )

    // ScreenCaptureKit clamps negative source coordinates. Giving it the clipped
    // source and its matching destination preserves both the origin and native scale.
    let left = ((clippedFrame.minX - captureFrame.minX) * pointPixelScale).rounded()
    let top = ((clippedFrame.minY - captureFrame.minY) * pointPixelScale).rounded()
    let right = ((clippedFrame.maxX - captureFrame.minX) * pointPixelScale).rounded()
    let bottom = ((clippedFrame.maxY - captureFrame.minY) * pointPixelScale).rounded()
    destinationRect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
  }
}
