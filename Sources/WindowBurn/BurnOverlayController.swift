import AppKit
import MetalKit
import WindowBurnCore

enum BurnOverlayError: LocalizedError {
  case metalUnavailable

  var errorDescription: String? {
    "Metal is not available on this Mac."
  }
}

enum BurnOverlayPresentation {
  case effectOverlay
  case demoWindow
}

@MainActor
final class BurnOverlayController {
  static let padding: CGFloat = 84

  private var window: NSWindow?
  private var renderer: BurnRenderer?

  func present(
    image: CGImage,
    backdropImage: CGImage? = nil,
    panelFrame: CGRect,
    profile: BurnProfile,
    style: BurnRendererStyle = .sweep,
    presentation: BurnOverlayPresentation = .effectOverlay,
    onFirstFrame: (() throws -> Void)?,
    completion: (() -> Void)? = nil
  ) throws {
    dismiss()

    guard let device = MTLCreateSystemDefaultDevice() else {
      throw BurnOverlayError.metalUnavailable
    }

    let window: NSWindow
    switch presentation {
    case .effectOverlay:
      let panel = NSPanel(
        contentRect: panelFrame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.level = .screenSaver
      panel.collectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
        .stationary,
      ]
      window = panel
    case .demoWindow:
      let demoWindow = NSWindow(
        contentRect: panelFrame,
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
      )
      demoWindow.title = "Window Burn Shader Demo"
      demoWindow.backgroundColor = .clear
      demoWindow.isOpaque = false
      demoWindow.hasShadow = true
      demoWindow.isReleasedWhenClosed = false
      window = demoWindow
    }
    let metalView = MTKView(frame: CGRect(origin: .zero, size: panelFrame.size), device: device)
    metalView.autoresizingMask = [.width, .height]
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
    metalView.isPaused = true
    metalView.enableSetNeedsDisplay = true
    if case .soakAndBurn = style {
      metalView.autoResizeDrawable = false
      metalView.preferredFramesPerSecond = 30
    } else {
      metalView.preferredFramesPerSecond = 60
    }
    metalView.wantsLayer = true
    metalView.layer?.isOpaque = false

    let burnRenderer = try BurnRenderer(
      device: device,
      image: image,
      backdropImage: backdropImage,
      profile: profile,
      style: style,
      horizontalPadding: presentation == .demoWindow ? 0 : Float(Self.padding / panelFrame.width),
      verticalPadding: presentation == .demoWindow ? 0 : Float(Self.padding / panelFrame.height),
      completion: { [weak self] in
        self?.dismiss()
        completion?()
      }
    )
    metalView.delegate = burnRenderer

    if case .soakAndBurn = style {
      let pointPixelScale = window.screen?.backingScaleFactor ?? window.backingScaleFactor
      let pixelSize = InteractiveRenderSizing.pixelSize(
        for: metalView.bounds.size,
        pointPixelScale: pointPixelScale,
        maximumPixelCount: 2_000_000
      )
      metalView.layer?.contentsScale = pointPixelScale
      metalView.drawableSize = CGSize(width: pixelSize.width, height: pixelSize.height)
    }
    window.contentView = metalView

    self.window = window
    renderer = burnRenderer
    switch presentation {
    case .effectOverlay:
      window.orderFrontRegardless()
    case .demoWindow:
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }

    metalView.draw()
    do {
      try onFirstFrame?()
    } catch {
      dismiss()
      throw error
    }

    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = false
    burnRenderer.start()
  }

  @discardableResult
  func addIgnition(_ point: BurnIgnitionPoint) -> Bool {
    renderer?.addIgnition(point) ?? false
  }

  @discardableResult
  func finishSoaking() -> Bool {
    renderer?.finishSoaking() ?? false
  }

  @discardableResult
  func addSoakPoint(_ point: BurnIgnitionPoint) -> Bool {
    renderer?.addSoakPoint(point) ?? false
  }

  @discardableResult
  func igniteSoakedWindow(at point: BurnIgnitionPoint) -> Bool {
    renderer?.igniteSoakedWindow(at: point) ?? false
  }

  func dismiss() {
    window?.orderOut(nil)
    window = nil
    renderer = nil
  }
}
