import CoreGraphics
import Testing

@testable import WindowBurnCore

@Suite("Display capture region")
struct DisplayCaptureRegionTests {
  @Test("Keeps native pixels and a known origin for a padded window")
  func preservesNativePadding() throws {
    let region = try #require(
      DisplayCaptureRegion(
        captureFrame: CGRect(x: 377, y: 316, width: 748, height: 577),
        displayFrame: CGRect(x: 0, y: 0, width: 1_710, height: 1_107),
        pointPixelScale: 2
      )
    )

    #expect(region.pixelSize == PixelSize(width: 1_496, height: 1_154))
    #expect(region.sourceRect == CGRect(x: 377, y: 316, width: 748, height: 577))
    #expect(region.destinationRect == CGRect(x: 0, y: 0, width: 1_496, height: 1_154))
  }

  @Test("Clips a display-edge window without shifting or stretching its pixels")
  func preservesClippedPadding() throws {
    let region = try #require(
      DisplayCaptureRegion(
        captureFrame: CGRect(x: -84, y: -49, width: 1_878, height: 1_240),
        displayFrame: CGRect(x: 0, y: 0, width: 1_710, height: 1_107),
        pointPixelScale: 2
      )
    )

    #expect(region.pixelSize == PixelSize(width: 3_756, height: 2_480))
    #expect(region.sourceRect == CGRect(x: 0, y: 0, width: 1_710, height: 1_107))
    #expect(region.destinationRect == CGRect(x: 168, y: 98, width: 3_420, height: 2_214))
  }

  @Test("Converts a display above and left of the main display into local points")
  func supportsSecondaryDisplayCoordinates() throws {
    let region = try #require(
      DisplayCaptureRegion(
        captureFrame: CGRect(x: -1_960, y: -960, width: 700, height: 500),
        displayFrame: CGRect(x: -1_920, y: -900, width: 1_920, height: 1_080),
        pointPixelScale: 1
      )
    )

    #expect(region.pixelSize == PixelSize(width: 700, height: 500))
    #expect(region.sourceRect == CGRect(x: 0, y: 0, width: 660, height: 440))
    #expect(region.destinationRect == CGRect(x: 40, y: 60, width: 660, height: 440))
  }

  @Test("Rounds pixel edges consistently on a fractional scale")
  func roundsSharedEdges() throws {
    let region = try #require(
      DisplayCaptureRegion(
        captureFrame: CGRect(x: -1, y: 10, width: 853, height: 479),
        displayFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        pointPixelScale: 1.5
      )
    )

    #expect(region.pixelSize == PixelSize(width: 1_280, height: 719))
    #expect(region.destinationRect == CGRect(x: 2, y: 0, width: 1_278, height: 719))
  }

  @Test("Rejects empty, off-display, and invalid capture requests")
  func rejectsInvalidRegions() {
    let display = CGRect(x: 0, y: 0, width: 1_710, height: 1_107)
    for frame in [
      CGRect.zero,
      CGRect(x: 2_000, y: 100, width: 400, height: 300),
      CGRect(x: CGFloat.infinity, y: 100, width: 400, height: 300),
    ] {
      #expect(
        DisplayCaptureRegion(captureFrame: frame, displayFrame: display, pointPixelScale: 2) == nil
      )
    }
    for scale in [CGFloat.zero, -1, .nan, .infinity] {
      #expect(
        DisplayCaptureRegion(captureFrame: display, displayFrame: display, pointPixelScale: scale)
          == nil
      )
    }
  }
}
