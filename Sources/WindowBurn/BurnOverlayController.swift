import AppKit
import MetalKit
import QuartzCore
import WindowBurnCore

enum BurnOverlayError: LocalizedError {
  case metalUnavailable
  case rendererUnavailable

  var errorDescription: String? {
    switch self {
    case .metalUnavailable:
      "Metal is not available on this Mac."
    case .rendererUnavailable:
      "The burn overlay renderer is no longer available."
    }
  }
}

enum BurnOverlayPresentation {
  case effectOverlay
  case demoWindow
}

@MainActor
final class BurnOverlayController {
  nonisolated static let padding: CGFloat = 84

  private var window: NSWindow?
  private var metalView: MTKView?
  private var renderer: BurnRenderer?

  var lastGPUFrameDuration: TimeInterval? { renderer?.lastGPUFrameDuration }

  func present(
    image: CGImage,
    backdropImage: CGImage? = nil,
    handoffImage: CGImage? = nil,
    shadowImage: CGImage? = nil,
    shadowSamplingOffset: CGPoint = .zero,
    panelFrame: CGRect,
    profile: BurnProfile,
    style: BurnRendererStyle = .sweep,
    presentation: BurnOverlayPresentation = .effectOverlay,
    startImmediately: Bool = true,
    completion: (() -> Void)? = nil
  ) async throws {
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
    // AppKit's default ordering animation scales the first frames, exposing the handoff.
    window.animationBehavior = .none
    let metalView = MTKView(frame: CGRect(origin: .zero, size: panelFrame.size), device: device)
    metalView.autoresizingMask = [.width, .height]
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
    metalView.isPaused = true
    metalView.enableSetNeedsDisplay = true
    // Keep captured text and contours at the display's native resolution.
    // Only the simulation fields use a smaller grid.
    metalView.preferredFramesPerSecond = 60
    metalView.wantsLayer = true
    metalView.layer?.isOpaque = false
    // Keep the capture's wide gamut through the compositor (including titlebar accents).
    if let metalLayer = metalView.layer as? CAMetalLayer {
      metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
    }

    let burnRenderer = try BurnRenderer(
      device: device,
      image: image,
      backdropImage: backdropImage,
      shadowImage: shadowImage,
      handoffImage: handoffImage,
      shadowSamplingOffset: shadowSamplingOffset,
      profile: profile,
      style: style,
      horizontalPadding: presentation == .demoWindow ? 0 : Float(Self.padding / panelFrame.width),
      verticalPadding: presentation == .demoWindow ? 0 : Float(Self.padding / panelFrame.height),
      cornerRadius: 0,
      completion: { [weak self] in
        self?.dismiss()
        completion?()
      }
    )
    metalView.delegate = burnRenderer

    window.contentView = metalView

    self.window = window
    self.metalView = metalView
    renderer = burnRenderer
    switch presentation {
    case .effectOverlay:
      window.orderFrontRegardless()
    case .demoWindow:
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    }

    do {
      try await burnRenderer.presentFrame(in: metalView)
      guard self.window === window else { throw CancellationError() }
      try Task.checkCancellation()
    } catch {
      if self.window === window { dismiss() }
      throw error
    }

    if startImmediately {
      startBurning()
    }
  }

  func startBurning() {
    guard let metalView, let renderer else { return }
    renderer.start()
    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = false
  }

  @discardableResult
  func activateReplacementSurface() async throws -> Bool {
    guard
      let metalView,
      let renderer
    else {
      return false
    }
    let presentedWindow = window
    renderer.activateReplacementSurface()
    try await renderer.presentFrame(in: metalView)
    try Task.checkCancellation()
    return window === presentedWindow
  }

  @discardableResult
  func prepareForIgnitionHandoff(handoffImage: CGImage? = nil) async throws -> Bool {
    guard
      let metalView,
      let renderer,
      renderer.prepareForIgnitionHandoff()
    else {
      return false
    }
    let presentedWindow = window
    try renderer.setHandoffImage(handoffImage)
    try await renderer.presentFrame(in: metalView)
    try Task.checkCancellation()
    return window === presentedWindow
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
    metalView = nil
    renderer = nil
  }
}
