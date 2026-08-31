import AppKit

enum DemoImageFactoryError: LocalizedError {
  case renderingFailed

  var errorDescription: String? {
    "Could not create the demo image."
  }
}

@MainActor
enum DemoImageFactory {
  static func make(size: CGSize) throws -> CGImage {
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * 2),
        pixelsHigh: Int(size.height * 2),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: .alphaFirst,
        bytesPerRow: 0,
        bitsPerPixel: 0
      ),
      let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap)
    else {
      throw DemoImageFactoryError.renderingFailed
    }
    bitmap.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    let bounds = CGRect(origin: .zero, size: size)
    let path = NSBezierPath(
      roundedRect: bounds.insetBy(dx: 2, dy: 2),
      xRadius: 22,
      yRadius: 22
    )
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()

    let gradient = NSGradient(colors: [
      NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.22, alpha: 1),
      NSColor(calibratedRed: 0.23, green: 0.10, blue: 0.31, alpha: 1),
    ])
    gradient?.draw(in: bounds, angle: -25)

    NSColor.white.withAlphaComponent(0.08).setFill()
    for index in 0..<12 {
      let x = CGFloat(index) * 74 - 40
      NSBezierPath(ovalIn: CGRect(x: x, y: 42, width: 160, height: 160)).fill()
    }
    NSGraphicsContext.current?.restoreGraphicsState()

    let title = "WINDOW BURN"
    let titleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 54, weight: .black),
      .foregroundColor: NSColor.white,
      .kern: 2.2,
    ]
    let titleSize = title.size(withAttributes: titleAttributes)
    title.draw(
      at: CGPoint(x: (size.width - titleSize.width) / 2, y: size.height / 2 + 12),
      withAttributes: titleAttributes
    )

    let subtitle = "A tiny Beryl-style experiment for macOS"
    let subtitleAttributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 20, weight: .medium),
      .foregroundColor: NSColor.white.withAlphaComponent(0.72),
    ]
    let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
    subtitle.draw(
      at: CGPoint(x: (size.width - subtitleSize.width) / 2, y: size.height / 2 - 38),
      withAttributes: subtitleAttributes
    )

    graphicsContext.flushGraphics()
    guard let cgImage = bitmap.cgImage else {
      throw DemoImageFactoryError.renderingFailed
    }
    return cgImage
  }
}
