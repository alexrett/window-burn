import AppKit
import ImageIO
import WindowBurnCore

@MainActor
final class QualityReviewController {
  private let overlay = BurnOverlayController()
  private var fixture: NSWindow?
  private var backdrop: NSWindow?
  private var outputDirectory = URL(fileURLWithPath: "/tmp/window-burn-quality")
  private var startedAt = CACurrentMediaTime()
  private var events: [[String: Any]] = []
  private var completionReached = false
  private var stage = "setup"
  private var gpuSamples: [String: [Double]] = [:]
  private var captureProcess: Process?

  func run(outputDirectory: URL) async throws {
    self.outputDirectory = outputDirectory
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    startedAt = CACurrentMediaTime()
    var result: Result<Void, Error>?
    let work = Task { @MainActor in
      do {
        try await self.performReview()
        result = .success(())
      } catch {
        result = .failure(error)
      }
    }
    defer {
      work.cancel()
      if let captureProcess, captureProcess.isRunning { captureProcess.terminate() }
      overlay.dismiss()
      fixture?.orderOut(nil)
      backdrop?.orderOut(nil)
      fixture = nil
      backdrop = nil
    }
    do {
      for _ in 0..<600 {
        if let result { return try result.get() }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw failure("Quality review timed out after 60 seconds")
    } catch {
      try? status("failed: \(error.localizedDescription)")
      throw error
    }
  }

  private func performReview() async throws {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let visible = screen.visibleFrame
    let size = CGSize(width: min(760, visible.width - 240), height: min(430, visible.height - 260))
    let contentFrame = CGRect(
      x: (visible.midX - size.width / 2).rounded(),
      y: (visible.midY - size.height / 2).rounded(),
      width: size.width, height: size.height
    )
    let backdrop = NSWindow(
      contentRect: contentFrame.insetBy(dx: -160, dy: -160), styleMask: .borderless,
      backing: .buffered, defer: false
    )
    backdrop.backgroundColor = NSColor(srgbRed: 0.13, green: 0.20, blue: 0.25, alpha: 1)
    backdrop.isReleasedWhenClosed = false
    backdrop.animationBehavior = .none
    backdrop.level = .floating
    backdrop.hasShadow = false
    backdrop.orderFrontRegardless()
    self.backdrop = backdrop
    let fixture = NSWindow(
      contentRect: contentFrame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false
    )
    fixture.title = "Window Burn — native fixture"
    fixture.hasShadow = true
    fixture.isReleasedWhenClosed = false
    fixture.animationBehavior = .none
    fixture.hasShadow = true
    fixture.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    fixture.contentView = QualityFixtureView(frame: CGRect(origin: .zero, size: size))
    self.fixture = fixture
    NSApp.activate(ignoringOtherApps: true)
    fixture.makeKeyAndOrderFront(nil)
    let targetFrame = CGRect(
      x: fixture.frame.minX,
      y: (NSScreen.screens.first?.frame.maxY ?? 0) - fixture.frame.maxY,
      width: fixture.frame.width, height: fixture.frame.height
    )
    try writeJSON(
      [
        "x": targetFrame.minX, "y": targetFrame.minY,
        "width": targetFrame.width, "height": targetFrame.height,
        "padding": BurnOverlayController.padding,
        "screenScale": screen.backingScaleFactor,
      ], name: "fixture.json")
    try status("fixture-ready")
    try await Task.sleep(for: .seconds(1))
    let target = TargetWindow(
      ownerPID: ProcessInfo.processInfo.processIdentifier, title: fixture.title, frame: targetFrame
    )
    let captured = try await WindowCaptureService.capture(target: target)
    try Task.checkCancellation()
    try verifyCapturedShadow(captured, name: "capture-shadow")
    let native = try await snapshot(frame: targetFrame, name: "01-native")
    let panelFrame = ScreenCoordinateConverter.appKitFrame(
      for: captured.captureFrame, mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
      padding: BurnOverlayController.padding
    )
    let profile = BurnProfile(duration: 2.4, seed: 41, tilt: 0.03, turbulence: 1.1, charWidth: 0.07)
    completionReached = false
    try await overlay.present(
      image: captured.image, handoffImage: captured.handoffImage, shadowImage: captured.shadowImage,
      shadowSamplingOffset: captured.shadowSamplingOffset,
      panelFrame: panelFrame, profile: profile, startImmediately: false,
      completion: { [weak self] in self?.completionReached = true }
    )
    try status("cover-presented")
    let cover = try await snapshot(frame: targetFrame, name: "02-cover")
    fixture.orderOut(nil)
    try await Task.sleep(for: .milliseconds(150))
    let closedUnderCover = try await snapshot(frame: targetFrame, name: "02b-closed-under-cover")
    guard try await overlay.activateReplacementSurface() else { throw failure("No replacement") }
    try status("replacement-presented")
    let replacement = try await snapshot(frame: targetFrame, name: "03-replacement")
    try writeJSON(
      [
        "nativeToCover": difference(native, cover, frame: targetFrame),
        "nativeToClosedUnderCover": difference(native, closedUnderCover, frame: targetFrame),
        "nativeToReplacement": difference(native, replacement, frame: targetFrame),
        "note":
          "RGB errors are 8-bit sRGB values; independent /usr/sbin/screencapture display snapshots are compared.",
      ], name: "comparison.json")
    try await Task.sleep(for: .milliseconds(500))
    try status("burning")
    overlay.startBurning()
    try await waitForEffect()

    try await reviewTranslucency(fixture: fixture, target: target, panelFrame: panelFrame)
    fixture.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(350))
    let soaked = try await WindowCaptureService.capture(target: target)
    try Task.checkCancellation()
    let points = [
      BurnIgnitionPoint(x: 0.35, y: 0.34), BurnIgnitionPoint(x: 0.45, y: 0.42),
      BurnIgnitionPoint(x: 0.56, y: 0.37), BurnIgnitionPoint(x: 0.61, y: 0.52),
    ]
    completionReached = false
    try await overlay.present(
      image: soaked.image, backdropImage: soaked.backdropImage, shadowImage: soaked.shadowImage,
      shadowSamplingOffset: soaked.shadowSamplingOffset, panelFrame: panelFrame,
      profile: BurnProfile(duration: 6, seed: 41, tilt: 0, turbulence: 1.1, charWidth: 0.07),
      style: .soakAndBurn(initialSoakPoints: [points[0]]),
      completion: { [weak self] in self?.completionReached = true }
    )
    try status("soaking")
    for point in points.dropFirst() {
      try await samplePause(seconds: 0.45)
      _ = overlay.addSoakPoint(point)
    }
    try await samplePause(seconds: 1.5)
    _ = overlay.finishSoaking()
    _ = try await snapshot(frame: targetFrame, name: "04-wet")
    try await samplePause(seconds: 1)
    let wetHandoff = await WindowCaptureService.captureHandoff(targetFrame: targetFrame)
    try Task.checkCancellation()
    guard try await overlay.prepareForIgnitionHandoff(handoffImage: wetHandoff) else {
      throw failure("Could not prepare wet handoff")
    }
    fixture.orderOut(nil)
    try await Task.sleep(for: .milliseconds(150))
    guard try await overlay.activateReplacementSurface(),
      overlay.igniteSoakedWindow(at: BurnIgnitionPoint(x: 0.48, y: 0.65))
    else { throw failure("Could not ignite wet fixture") }
    try status("wet-burning")
    try await samplePause(seconds: 1.5)
    _ = try await snapshot(frame: targetFrame, name: "05-wet-fire")
    try await waitForEffect()
    try writeJSON(gpuStatistics(), name: "gpu-timings.json")
    try status("complete")
  }

  private func reviewTranslucency(fixture: NSWindow, target: TargetWindow, panelFrame: CGRect)
    async throws
  {
    fixture.alphaValue = 0.78
    defer { fixture.alphaValue = 1 }
    fixture.makeKeyAndOrderFront(nil)
    try await Task.sleep(for: .milliseconds(350))
    let captured = try await WindowCaptureService.capture(target: target)
    try Task.checkCancellation()
    try verifyCapturedShadow(captured, name: "translucent-capture-shadow")
    let native = try await snapshot(frame: target.frame, name: "06-translucent-native")
    try await overlay.present(
      image: captured.image, handoffImage: captured.handoffImage, shadowImage: captured.shadowImage,
      shadowSamplingOffset: captured.shadowSamplingOffset, panelFrame: panelFrame,
      profile: BurnProfile(duration: 2, seed: 41, tilt: 0, turbulence: 1, charWidth: 0.07),
      startImmediately: false
    )
    try status("translucent-cover-presented")
    let cover = try await snapshot(frame: target.frame, name: "07-translucent-cover")
    fixture.orderOut(nil)
    try await Task.sleep(for: .milliseconds(150))
    guard try await overlay.activateReplacementSurface() else {
      throw failure("No translucent replacement")
    }
    let replacement = try await snapshot(frame: target.frame, name: "08-translucent-replacement")
    try writeJSON(
      [
        "windowAlpha": 0.78,
        "nativeToCover": difference(native, cover, frame: target.frame),
        "nativeToReplacement": difference(native, replacement, frame: target.frame),
      ], name: "translucent-comparison.json")
    overlay.dismiss()
  }

  private func waitForEffect() async throws {
    for _ in 0..<240 {
      if completionReached { return }
      try await samplePause(seconds: 0.05)
    }
    throw failure("Effect did not complete within 12 seconds")
  }

  private func samplePause(seconds: TimeInterval) async throws {
    let end = CACurrentMediaTime() + seconds
    while CACurrentMediaTime() < end {
      if let duration = overlay.lastGPUFrameDuration, duration.isFinite, duration > 0 {
        gpuSamples[stage, default: []].append(duration * 1_000)
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func gpuStatistics() -> [String: Any] {
    var output: [String: Any] = [
      "note":
        "GPU execution milliseconds sampled every ~50ms; excludes presentation and CPU time and is not FPS."
    ]
    for (name, samples) in gpuSamples {
      let sorted = samples.sorted()
      output[name] = [
        "samples": sorted.count,
        "p50ms": sorted[Int(Double(sorted.count - 1) * 0.50)],
        "p95ms": sorted[Int(Double(sorted.count - 1) * 0.95)],
        "maxms": sorted[sorted.count - 1],
      ]
    }
    return output
  }

  private func snapshot(frame: CGRect, name: String) async throws -> CGImage {
    try Task.checkCancellation()
    let url = outputDirectory.appendingPathComponent("\(name).png")
    let padded = frame.insetBy(
      dx: -BurnOverlayController.padding, dy: -BurnOverlayController.padding)
    let region = [padded.minX, padded.minY, padded.width, padded.height]
      .map { String(Int($0.rounded())) }.joined(separator: ",")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = ["-x", "-R\(region)", url.path]
    process.standardOutput = FileHandle.nullDevice
    let errors = Pipe()
    process.standardError = errors
    captureProcess = process
    defer { captureProcess = nil }
    let exitStatus: Int32 = try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { completed in
        continuation.resume(returning: completed.terminationStatus)
      }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    try Task.checkCancellation()
    guard exitStatus == 0 else {
      let detail = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw failure("Screen capture failed for \(name): \(detail)")
    }
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw failure("Could not decode independent screenshot \(name).png") }
    return image
  }

  private func verifyCapturedShadow(_ captured: CapturedWindow, name: String) throws {
    guard let image = captured.shadowImage, let data = pixels(image) else {
      throw failure("The native fixture shadow was not captured")
    }
    let scale = CGFloat(captured.image.width) / captured.captureFrame.width
    let padding = Int((BurnOverlayController.padding * scale).rounded())
    var maximumAlpha = 0
    var nonzeroPixels = 0
    var sampledPixels = 0
    for y in 0..<image.height {
      for x in 0..<image.width
      where x < padding || y < padding || x >= padding + captured.image.width
        || y >= padding + captured.image.height
      {
        let alpha = Int(data[(y * image.width + x) * 4 + 3])
        maximumAlpha = max(maximumAlpha, alpha)
        nonzeroPixels += alpha > 0 ? 1 : 0
        sampledPixels += 1
      }
    }
    try writeJSON(
      [
        "maximumExteriorAlpha": maximumAlpha, "nonzeroExteriorPixels": nonzeroPixels,
        "sampledExteriorPixels": sampledPixels,
        "hasNativeShadow": maximumAlpha > 0 && nonzeroPixels > 0,
        "note": "The fixture hasShadow is true; fully transparent exterior is a capture failure.",
      ], name: "\(name).json")
    guard maximumAlpha > 0, nonzeroPixels > 0 else {
      throw failure("Captured fixture shadow is fully transparent outside the window body")
    }
  }

  private func difference(_ reference: CGImage, _ candidate: CGImage, frame: CGRect) -> [String:
    Any]
  {
    guard reference.width == candidate.width, reference.height == candidate.height,
      let lhs = pixels(reference), let rhs = pixels(candidate)
    else { return ["dimensionsMatch": false] }
    let scale = CGFloat(reference.width) / (frame.width + BurnOverlayController.padding * 2)
    let padding = BurnOverlayController.padding * scale
    let content = CGRect(
      x: padding, y: padding, width: frame.width * scale, height: frame.height * scale)
    var groups = Array(repeating: (sum: 0.0, maximum: 0, samples: 0, changed: 0), count: 3)
    for y in 0..<reference.height {
      for x in 0..<reference.width {
        let point = CGPoint(x: x, y: y)
        let corner =
          min(abs(point.x - content.minX), abs(point.x - content.maxX)) < 24 * scale
          && min(abs(point.y - content.minY), abs(point.y - content.maxY)) < 24 * scale
        let group = !content.contains(point) ? 2 : (corner ? 1 : 0)
        for channel in 0..<3 {
          let index = (y * reference.width + x) * 4 + channel
          let error = abs(Int(lhs[index]) - Int(rhs[index]))
          groups[group].sum += Double(error)
          groups[group].maximum = max(groups[group].maximum, error)
          groups[group].samples += 1
          groups[group].changed += error > 2 ? 1 : 0
        }
      }
    }
    var result: [String: Any] = [
      "dimensionsMatch": true, "width": reference.width, "height": reference.height,
    ]
    for (index, name) in ["content", "corners", "shadow"].enumerated() {
      let value = groups[index]
      result[name] = [
        "meanAbsoluteError": value.sum / Double(max(1, value.samples)),
        "maximumError": value.maximum,
        "fractionOverTwo": Double(value.changed) / Double(max(1, value.samples)),
        "withinTolerance": value.sum / Double(max(1, value.samples)) <= 1
          && value.maximum <= 8,
      ]
    }
    result["tolerance"] = ["meanAbsoluteErrorAtMost": 1, "maximumErrorAtMost": 8]
    return result
  }

  private func pixels(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let success = data.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else { return false }
      context.translateBy(x: 0, y: CGFloat(image.height))
      context.scaleBy(x: 1, y: -1)
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    return success ? data : nil
  }

  private func status(_ message: String) throws {
    stage = message
    events.append(["stage": message, "seconds": CACurrentMediaTime() - startedAt])
    try message.write(
      to: outputDirectory.appendingPathComponent("status.txt"), atomically: true, encoding: .utf8)
    try writeJSON(events, name: "timeline.json")
  }

  private func writeJSON(_ value: Any, name: String) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
      .write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
  }

  private func failure(_ message: String) -> NSError {
    NSError(
      domain: "WindowBurn.QualityReview", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}

@MainActor
private final class QualityFixtureView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor(srgbRed: 0.97, green: 0.95, blue: 0.90, alpha: 1).setFill()
    bounds.fill()
    let text: [(String, CGFloat, CGFloat)] = [
      ("A window, down to the last pixel.", 30, bounds.height - 80),
      ("Native titlebar · Retina text · preserved corners and shadow", 15, bounds.height - 115),
      ("Heat dries the paper. Flame follows the remaining fuel.", 18, 48),
    ]
    for (value, size, y) in text {
      (value as NSString).draw(
        at: CGPoint(x: 32, y: y),
        withAttributes: [
          .font: NSFont.systemFont(ofSize: size, weight: size > 20 ? .semibold : .regular),
          .foregroundColor: NSColor(srgbRed: 0.10, green: 0.15, blue: 0.18, alpha: 1),
        ])
    }
    for (index, color) in [NSColor.systemOrange, .systemTeal, .systemIndigo, .systemPink]
      .enumerated()
    {
      color.setFill()
      NSBezierPath(
        roundedRect: CGRect(x: 32 + CGFloat(index) * 174, y: 105, width: 156, height: 130),
        xRadius: 12, yRadius: 12
      ).fill()
    }
  }
}
