import CoreGraphics
import OSLog
import ScreenCaptureKit
import WindowBurnCore

struct CapturedWindow {
  let image: CGImage
  let backdropImage: CGImage
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
      captureFrame: window.frame
    )
  }
}
