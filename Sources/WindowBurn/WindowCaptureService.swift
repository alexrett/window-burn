import CoreGraphics
import OSLog
import ScreenCaptureKit
import WindowBurnCore

struct CapturedWindow {
  let image: CGImage
  let backdropImage: CGImage
  let shadowImage: CGImage?
  let shadowSamplingOffset: CGPoint
  let captureFrame: CGRect
}

enum WindowCaptureError: LocalizedError {
  case permissionMissing
  case noMatchingWindow
  case noMatchingDisplay

  var errorDescription: String? {
    switch self {
    case .permissionMissing:
      "Screen Recording permission is missing. Grant it in System Settings, restart Window Burn, and retry."
    case .noMatchingWindow:
      "ScreenCaptureKit could not match the focused window."
    case .noMatchingDisplay:
      "ScreenCaptureKit could not match the focused window to a display."
    }
  }
}

enum WindowCaptureService {
  private static let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "capture")

  static func capture(target: TargetWindow) async throws -> CapturedWindow {
    guard PermissionService.hasScreenCaptureAccess else {
      throw WindowCaptureError.permissionMissing
    }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    let candidates = content.windows.map {
      WindowCandidate(
        id: $0.windowID,
        ownerPID: $0.owningApplication?.processID ?? -1,
        title: $0.title,
        frame: $0.frame,
        isOnScreen: $0.isOnScreen
      )
    }
    guard
      let match = WindowMatcher.bestMatch(for: target, among: candidates),
      let window = content.windows.first(where: { $0.windowID == match.id })
    else {
      throw WindowCaptureError.noMatchingWindow
    }

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let pixelSize = CapturePixelSizing.pixelSize(
      for: window.frame.size,
      pointPixelScale: CGFloat(filter.pointPixelScale)
    )
    let configuration = SCStreamConfiguration()
    configuration.width = pixelSize.width
    configuration.height = pixelSize.height
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.scalesToFit = true
    configuration.preservesAspectRatio = true

    logger.info(
      "Capturing \(window.frame.width, format: .fixed(precision: 0))×\(window.frame.height, format: .fixed(precision: 0)) points at \(filter.pointPixelScale, format: .fixed(precision: 2))× into \(pixelSize.width)×\(pixelSize.height) pixels"
    )

    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )

    let shadowCapture = await captureAlignedShadow(
      contentFilter: filter,
      windowImage: image,
      pointPixelScale: CGFloat(filter.pointPixelScale),
      padding: BurnOverlayController.padding
    )

    let displayFrames = content.displays.map(\.frame)
    guard
      let displayIndex = BackdropCaptureGeometry.displayIndex(
        containingMostOf: window.frame,
        among: displayFrames
      )
    else {
      throw WindowCaptureError.noMatchingDisplay
    }
    let display = content.displays[displayIndex]
    let backdropFilter = SCContentFilter(display: display, excludingWindows: [window])
    let backdropConfiguration = SCStreamConfiguration()
    backdropConfiguration.width = pixelSize.width
    backdropConfiguration.height = pixelSize.height
    backdropConfiguration.sourceRect = BackdropCaptureGeometry.sourceRect(
      for: window.frame,
      in: display.frame
    )
    backdropConfiguration.showsCursor = false
    backdropConfiguration.scalesToFit = true
    backdropConfiguration.preservesAspectRatio = true

    logger.info(
      "Capturing the same rect from display \(display.displayID) with target window \(window.windowID) excluded"
    )
    let backdropImage = try await SCScreenshotManager.captureImage(
      contentFilter: backdropFilter,
      configuration: backdropConfiguration
    )
    return CapturedWindow(
      image: image,
      backdropImage: backdropImage,
      shadowImage: shadowCapture?.image,
      shadowSamplingOffset: shadowCapture?.samplingOffset ?? .zero,
      captureFrame: window.frame
    )
  }

  private static func captureAlignedShadow(
    contentFilter: SCContentFilter,
    windowImage: CGImage,
    pointPixelScale: CGFloat,
    padding: CGFloat
  ) async -> (image: CGImage, samplingOffset: CGPoint)? {
    let paddingPixels = max(1, Int((padding * pointPixelScale).rounded()))
    let configuration = SCStreamConfiguration()
    configuration.width = windowImage.width + paddingPixels * 2
    configuration.height = windowImage.height + paddingPixels * 2
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = false
    configuration.scalesToFit = false
    configuration.preservesAspectRatio = true

    do {
      let shadowImage = try await SCScreenshotManager.captureImage(
        contentFilter: contentFilter,
        configuration: configuration
      )
      guard
        let capturedContentOrigin = opaqueContentOrigin(
          in: shadowImage,
          expectedContentSize: CGSize(width: windowImage.width, height: windowImage.height)
        )
      else {
        logger.warning("Could not align the captured native window shadow")
        return nil
      }
      let desiredContentOrigin = CGPoint(x: paddingPixels, y: paddingPixels)
      let samplingOffset = OverlayDepthModel.shadowSamplingOffset(
        capturedContentOrigin: capturedContentOrigin,
        desiredContentOrigin: desiredContentOrigin,
        textureSize: CGSize(width: shadowImage.width, height: shadowImage.height)
      )
      logger.info(
        "Captured native shadow with sampling offset \(samplingOffset.x, format: .fixed(precision: 4)), \(samplingOffset.y, format: .fixed(precision: 4))"
      )
      return (shadowImage, samplingOffset)
    } catch {
      logger.warning(
        "Native window shadow capture failed: \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  private static func opaqueContentOrigin(
    in image: CGImage,
    expectedContentSize: CGSize
  ) -> CGPoint? {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo =
      CGImageAlphaInfo.premultipliedLast.rawValue
      | CGBitmapInfo.byteOrder32Big.rawValue
    let drewImage = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let baseAddress = bytes.baseAddress,
        let context = CGContext(
          data: baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else {
        return false
      }
      context.translateBy(x: 0, y: CGFloat(height))
      context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard drewImage else { return nil }

    var maximumAlpha: UInt8 = 0
    for alphaIndex in stride(from: 3, to: pixels.count, by: bytesPerPixel) {
      maximumAlpha = max(maximumAlpha, pixels[alphaIndex])
    }
    guard maximumAlpha > 0 else { return nil }
    let threshold = UInt8(max(1, Int(Float(maximumAlpha) * 0.98)))
    var minimumX = width
    var minimumY = height
    var maximumX = -1
    var maximumY = -1
    for y in 0..<height {
      let rowStart = y * bytesPerRow
      for x in 0..<width
      where pixels[rowStart + x * bytesPerPixel + 3] >= threshold {
        minimumX = min(minimumX, x)
        minimumY = min(minimumY, y)
        maximumX = max(maximumX, x)
        maximumY = max(maximumY, y)
      }
    }
    guard maximumX >= minimumX, maximumY >= minimumY else { return nil }

    let detectedWidth = maximumX - minimumX + 1
    let detectedHeight = maximumY - minimumY + 1
    let expectedWidth = Int(expectedContentSize.width.rounded())
    let expectedHeight = Int(expectedContentSize.height.rounded())
    guard
      abs(detectedWidth - expectedWidth) <= 4,
      abs(detectedHeight - expectedHeight) <= 4
    else {
      return nil
    }
    let topOriginY = height - maximumY - 1
    return CGPoint(x: minimumX, y: topOriginY)
  }
}
