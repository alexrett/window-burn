import CoreGraphics
import Testing

@testable import WindowBurnCore

@Suite("Overlay geometry")
struct GeometryTests {
  @Test("Flips ScreenCaptureKit top-left coordinates into AppKit space")
  func convertsMainDisplayCoordinates() {
    let captured = CGRect(x: 100, y: 150, width: 800, height: 600)

    let overlay = ScreenCoordinateConverter.appKitFrame(
      for: captured,
      mainDisplayHeight: 1_000,
      padding: 50
    )

    #expect(overlay == CGRect(x: 50, y: 200, width: 900, height: 700))
  }

  @Test("Keeps a monitor above the main display above in AppKit space")
  func convertsNegativeCaptureY() {
    let captured = CGRect(x: 0, y: -900, width: 1_440, height: 900)

    let overlay = ScreenCoordinateConverter.appKitFrame(
      for: captured,
      mainDisplayHeight: 900,
      padding: 0
    )

    #expect(overlay == CGRect(x: 0, y: 900, width: 1_440, height: 900))
  }

  @Test("Converts a live Quartz pointer into AppKit coordinates")
  func convertsPointerCoordinates() {
    let point = ScreenCoordinateConverter.appKitPoint(
      forQuartzPoint: CGPoint(x: 320, y: 180),
      mainDisplayHeight: 1_000
    )

    #expect(point == CGPoint(x: 320, y: 820))
  }

  @Test("The overlay shadow separates only the surviving external silhouette")
  func preservesWindowDepthDuringBurn() {
    let visibleEdge = OverlayDepthModel.exteriorShadowOpacity(
      outsideDistance: 0.012,
      materialVisibility: 1,
      isNativeWindowVisible: false
    )
    let nativeShadowStillVisible = OverlayDepthModel.exteriorShadowOpacity(
      outsideDistance: 0.012,
      materialVisibility: 1,
      isNativeWindowVisible: true
    )
    let burnedEdge = OverlayDepthModel.exteriorShadowOpacity(
      outsideDistance: 0.012,
      materialVisibility: 0,
      isNativeWindowVisible: false
    )
    let beyondShadow = OverlayDepthModel.exteriorShadowOpacity(
      outsideDistance: 0.09,
      materialVisibility: 1,
      isNativeWindowVisible: false
    )

    #expect(visibleEdge > 0.15)
    #expect(nativeShadowStillVisible == 0)
    #expect(burnedEdge == 0)
    #expect(beyondShadow == 0)
  }
}

@Suite("Capture pixel sizing")
struct CapturePixelSizingTests {
  @Test("Uses one pixel per point on a non-Retina display")
  func externalDisplayScale() {
    let size = CapturePixelSizing.pixelSize(
      for: CGSize(width: 1_280, height: 720),
      pointPixelScale: 1
    )

    #expect(size == PixelSize(width: 1_280, height: 720))
  }

  @Test("Uses two pixels per point on a Retina display")
  func retinaDisplayScale() {
    let size = CapturePixelSizing.pixelSize(
      for: CGSize(width: 1_280, height: 720),
      pointPixelScale: 2
    )

    #expect(size == PixelSize(width: 2_560, height: 1_440))
  }

  @Test("Rounds fractional display scales and never produces zero")
  func fractionalAndTinyDimensions() {
    let fractional = CapturePixelSizing.pixelSize(
      for: CGSize(width: 853, height: 479),
      pointPixelScale: 1.5
    )
    let tiny = CapturePixelSizing.pixelSize(
      for: CGSize(width: 0, height: 0),
      pointPixelScale: 1
    )

    #expect(fractional == PixelSize(width: 1_280, height: 719))
    #expect(tiny == PixelSize(width: 1, height: 1))
  }
}

@Suite("Interactive render sizing")
struct InteractiveRenderSizingTests {
  @Test("Caps a large Retina overlay while preserving its aspect ratio")
  func capsLargeRetinaOverlay() {
    let size = InteractiveRenderSizing.pixelSize(
      for: CGSize(width: 1_878, height: 1_240),
      pointPixelScale: 2,
      maximumPixelCount: 2_000_000
    )

    #expect(size.width * size.height <= 2_000_000)
    #expect(abs(Double(size.width) / Double(size.height) - 1_878.0 / 1_240.0) < 0.002)
  }

  @Test("Leaves a small external-display overlay at native resolution")
  func keepsSmallOverlayNative() {
    let size = InteractiveRenderSizing.pixelSize(
      for: CGSize(width: 900, height: 600),
      pointPixelScale: 1,
      maximumPixelCount: 2_000_000
    )

    #expect(size == PixelSize(width: 900, height: 600))
  }
}

@Suite("Burn timing")
struct BurnTimingTests {
  @Test(arguments: [
    (-0.2, 0.0),
    (0.0, 0.0),
    (0.6, 0.5),
    (1.2, 1.0),
    (2.0, 1.0),
  ])
  func progressIsClamped(elapsed: Double, expected: Double) {
    #expect(BurnTiming.progress(elapsed: elapsed, duration: 1.2) == expected)
  }
}

@Suite("Backdrop capture geometry")
struct BackdropCaptureGeometryTests {
  @Test("Chooses the display containing the largest part of the target window")
  func choosesDisplayByLargestIntersection() {
    let window = CGRect(x: 420, y: 180, width: 720, height: 520)
    let displays = [
      CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
      CGRect(x: 0, y: 0, width: 1_710, height: 1_107),
      CGRect(x: 1_710, y: -900, width: 1_440, height: 900),
    ]

    let displayIndex = BackdropCaptureGeometry.displayIndex(
      containingMostOf: window,
      among: displays
    )

    #expect(displayIndex == 1)
  }

  @Test("Supports a window straddling two displays")
  func choosesDisplayForStraddlingWindow() {
    let window = CGRect(x: 1_500, y: 120, width: 700, height: 500)
    let displays = [
      CGRect(x: 0, y: 0, width: 1_710, height: 1_107),
      CGRect(x: 1_710, y: 0, width: 1_440, height: 900),
    ]

    let displayIndex = BackdropCaptureGeometry.displayIndex(
      containingMostOf: window,
      among: displays
    )

    #expect(displayIndex == 1)
  }

  @Test("Converts a global window frame into display-local coordinates")
  func makesDisplayLocalSourceRect() {
    let display = CGRect(x: 1_710, y: -900, width: 1_440, height: 900)
    let window = CGRect(x: 1_820, y: -720, width: 500, height: 400)

    let sourceRect = BackdropCaptureGeometry.sourceRect(
      for: window,
      in: display
    )

    #expect(sourceRect == CGRect(x: 110, y: 180, width: 500, height: 400))
  }

  @Test("Returns no display when none are available")
  func handlesMissingDisplays() {
    let displayIndex = BackdropCaptureGeometry.displayIndex(
      containingMostOf: CGRect(x: 100, y: 75, width: 640, height: 480),
      among: []
    )

    #expect(displayIndex == nil)
  }
}
