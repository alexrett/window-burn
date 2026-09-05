import CoreGraphics
import OSLog
@preconcurrency import ScreenCaptureKit
import WindowBurnCore

struct CapturedWindow {
  let image: CGImage
  let backdropImage: CGImage
  let shadowImage: CGImage?
  let shadowSamplingOffset: CGPoint
  let captureFrame: CGRect
  let handoffImage: CGImage?
}

enum WindowCaptureError: LocalizedError {
  case permissionMissing
  case noMatchingWindow
  case noMatchingDisplay
  case invalidImage

  var errorDescription: String? {
    switch self {
    case .permissionMissing:
      "Screen Recording permission is missing. Grant it in System Settings, restart Window Burn, and retry."
    case .noMatchingWindow:
      "ScreenCaptureKit could not match the focused window."
    case .noMatchingDisplay:
      "ScreenCaptureKit could not match the focused window to a display."
    case .invalidImage:
      "ScreenCaptureKit returned an image that could not be cropped to the window."
    }
  }
}

@MainActor
enum WindowCaptureService {
  private static let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "capture")

  static func capture(
    target: TargetWindow,
    excludingWindowIDs: Set<CGWindowID> = []
  ) async throws -> CapturedWindow {
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
    let windowFilter = SCContentFilter(desktopIndependentWindow: window)
    let pointPixelScale = CGFloat(windowFilter.pointPixelScale)
    let pixelSize = CapturePixelSizing.pixelSize(
      for: window.frame.size,
      pointPixelScale: pointPixelScale
    )
    let paddedFrame = window.frame.insetBy(
      dx: -BurnOverlayController.padding,
      dy: -BurnOverlayController.padding
    )
    let paddedRegion = DisplayCaptureRegion(
      captureFrame: paddedFrame,
      displayFrame: display.frame,
      pointPixelScale: pointPixelScale
    )
    let usesDisplayGeometry = display.frame.contains(window.frame)

    // The window and its native shadow come from one compositor image. All
    // independent captures run together so their contents stay close in time.
    async let surface = { @MainActor in
      try await captureSurface(
        window: window,
        display: display,
        independentFilter: windowFilter,
        pixelSize: pixelSize,
        pointPixelScale: pointPixelScale,
        paddedRegion: usesDisplayGeometry ? paddedRegion : nil
      )
    }()
    async let backdrop = { @MainActor in
      try await captureBackdrop(
        window: window,
        display: display,
        pointPixelScale: pointPixelScale,
        excluding: content.windows.filter { excludingWindowIDs.contains($0.windowID) }
      )
    }()
    async let handoff = { @MainActor in
      await captureCompositedPatch(
        display: display,
        region: usesDisplayGeometry ? paddedRegion : nil,
        excluding: content.windows.filter { excludingWindowIDs.contains($0.windowID) }
      )
    }()
    let ((image, shadowImage, shadowOffset), backdropImage, handoffImage) = try await (
      surface, backdrop, handoff
    )

    logger.info(
      "Captured \(window.frame.width, format: .fixed(precision: 0))×\(window.frame.height, format: .fixed(precision: 0)) points at \(pointPixelScale, format: .fixed(precision: 2))×; display geometry: \(usesDisplayGeometry)"
    )
    return CapturedWindow(
      image: image,
      backdropImage: backdropImage,
      shadowImage: shadowImage,
      shadowSamplingOffset: shadowOffset,
      captureFrame: window.frame,
      handoffImage: handoffImage
    )
  }

  /// Refreshes the visible compositor surface immediately before a delayed handoff.
  /// The frame is the unpadded window frame in Quartz screen coordinates.
  static func captureHandoff(
    targetFrame: CGRect,
    excludingWindowIDs: Set<CGWindowID> = []
  ) async -> CGImage? {
    guard PermissionService.hasScreenCaptureAccess else { return nil }
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )
      guard let display = content.displays.first(where: { $0.frame.contains(targetFrame) }) else {
        return nil
      }
      let filter = SCContentFilter(display: display, excludingWindows: [])
      let region = DisplayCaptureRegion(
        captureFrame: targetFrame.insetBy(
          dx: -BurnOverlayController.padding,
          dy: -BurnOverlayController.padding
        ),
        displayFrame: display.frame,
        pointPixelScale: CGFloat(filter.pointPixelScale)
      )
      return await captureCompositedPatch(
        display: display,
        region: region,
        excluding: content.windows.filter { excludingWindowIDs.contains($0.windowID) }
      )
    } catch {
      logger.warning(
        "Handoff snapshot unavailable: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func captureSurface(
    window: SCWindow,
    display: SCDisplay,
    independentFilter: SCContentFilter,
    pixelSize: PixelSize,
    pointPixelScale: CGFloat,
    paddedRegion: DisplayCaptureRegion?
  ) async throws -> (CGImage, CGImage?, CGPoint) {
    if let paddedRegion {
      let configuration = displayConfiguration(for: paddedRegion)
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: display, including: [window]),
        configuration: configuration
      )
      let paddingPixels = (BurnOverlayController.padding * pointPixelScale).rounded()
      guard
        let windowImage = image.cropping(
          to: CGRect(
            x: paddingPixels,
            y: paddingPixels,
            width: CGFloat(pixelSize.width),
            height: CGFloat(pixelSize.height)
          )
        )
      else { throw WindowCaptureError.invalidImage }
      return (windowImage, image, .zero)
    }

    // A display filter clips a window spanning multiple displays. Preserve the
    // desktop-independent fallback for this case until multi-display compositing exists.
    let configuration = SCStreamConfiguration()
    configuration.width = pixelSize.width
    configuration.height = pixelSize.height
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    configuration.scalesToFit = false
    configuration.preservesAspectRatio = true
    configuration.colorSpaceName = CGColorSpace.displayP3
    async let image = { @MainActor in
      try await SCScreenshotManager.captureImage(
        contentFilter: independentFilter,
        configuration: configuration
      )
    }()
    async let shadow = { @MainActor in
      await captureAlignedShadow(
        contentFilter: independentFilter,
        expectedContentSize: pixelSize,
        pointPixelScale: pointPixelScale,
        padding: BurnOverlayController.padding
      )
    }()
    let (windowImage, shadowCapture) = try await (image, shadow)
    return (windowImage, shadowCapture?.image, shadowCapture?.samplingOffset ?? .zero)
  }

  private static func captureBackdrop(
    window: SCWindow,
    display: SCDisplay,
    pointPixelScale: CGFloat,
    excluding windows: [SCWindow]
  ) async throws -> CGImage {
    guard
      let region = DisplayCaptureRegion(
        captureFrame: window.frame,
        displayFrame: display.frame,
        pointPixelScale: pointPixelScale
      )
    else { throw WindowCaptureError.noMatchingDisplay }
    return try await SCScreenshotManager.captureImage(
      contentFilter: SCContentFilter(display: display, excludingWindows: [window] + windows),
      configuration: displayConfiguration(for: region)
    )
  }

  private static func captureCompositedPatch(
    display: SCDisplay,
    region: DisplayCaptureRegion?,
    excluding windows: [SCWindow]
  ) async -> CGImage? {
    guard let region else { return nil }
    do {
      return try await SCScreenshotManager.captureImage(
        contentFilter: SCContentFilter(display: display, excludingWindows: windows),
        configuration: displayConfiguration(for: region)
      )
    } catch {
      logger.warning(
        "Handoff snapshot unavailable: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  private static func displayConfiguration(for region: DisplayCaptureRegion)
    -> SCStreamConfiguration
  {
    let configuration = SCStreamConfiguration()
    configuration.width = region.pixelSize.width
    configuration.height = region.pixelSize.height
    configuration.sourceRect = region.sourceRect
    configuration.destinationRect = region.destinationRect
    configuration.showsCursor = false
    // Screenshot capture applies the single-window shadow flag to display
    // filters too. Its default is true, which silently removes native shadows.
    configuration.ignoreShadowsDisplay = false
    configuration.ignoreShadowsSingleWindow = false
    configuration.scalesToFit = false
    configuration.preservesAspectRatio = true
    configuration.colorSpaceName = CGColorSpace.displayP3
    return configuration
  }

  private static func captureAlignedShadow(
    contentFilter: SCContentFilter,
    expectedContentSize: PixelSize,
    pointPixelScale: CGFloat,
    padding: CGFloat
  ) async -> (image: CGImage, samplingOffset: CGPoint)? {
    let paddingPixels = max(1, Int((padding * pointPixelScale).rounded()))
    let configuration = SCStreamConfiguration()
    configuration.width = expectedContentSize.width + paddingPixels * 2
    configuration.height = expectedContentSize.height + paddingPixels * 2
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = false
    configuration.colorSpaceName = CGColorSpace.displayP3
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
          expectedContentSize: CGSize(
            width: expectedContentSize.width,
            height: expectedContentSize.height
          )
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
