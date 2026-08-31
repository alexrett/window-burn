import AppKit
import MetalKit
import WindowBurnCore

enum BurnOverlayError: LocalizedError {
  case metalUnavailable

  var errorDescription: String? {
    "Metal is not available on this Mac."
  }
}

@MainActor
final class BurnOverlayController {
  static let padding: CGFloat = 84

  private var panel: NSPanel?
  private var renderer: BurnRenderer?

  func present(
    image: CGImage,
    panelFrame: CGRect,
    profile: BurnProfile,
    style: BurnRendererStyle = .sweep,
    onFirstFrame: (() throws -> Void)?,
    completion: (() -> Void)? = nil
  ) throws {
    dismiss()

    guard let device = MTLCreateSystemDefaultDevice() else {
      throw BurnOverlayError.metalUnavailable
    }

    let window = NSPanel(
      contentRect: panelFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.backgroundColor = .clear
    window.isOpaque = false
    window.hasShadow = false
    window.ignoresMouseEvents = true
    window.level = .screenSaver
    window.collectionBehavior = [
      .canJoinAllSpaces,
      .fullScreenAuxiliary,
      .ignoresCycle,
      .stationary,
    ]

    let metalView = MTKView(frame: CGRect(origin: .zero, size: panelFrame.size), device: device)
    metalView.autoresizingMask = [.width, .height]
    metalView.colorPixelFormat = .bgra8Unorm
    metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
    metalView.isPaused = true
    metalView.enableSetNeedsDisplay = true
    if case .soakAndBurn = style {
      let pixelSize = InteractiveRenderSizing.pixelSize(
        for: panelFrame.size,
        pointPixelScale: window.backingScaleFactor,
        maximumPixelCount: 2_000_000
      )
      metalView.autoResizeDrawable = false
      metalView.drawableSize = CGSize(width: pixelSize.width, height: pixelSize.height)
      metalView.preferredFramesPerSecond = 30
    } else {
      metalView.preferredFramesPerSecond = 60
    }
    metalView.wantsLayer = true
    metalView.layer?.isOpaque = false

    let burnRenderer = try BurnRenderer(
      device: device,
      image: image,
      profile: profile,
      style: style,
      horizontalPadding: Float(Self.padding / panelFrame.width),
      verticalPadding: Float(Self.padding / panelFrame.height),
      completion: { [weak self] in
        self?.dismiss()
        completion?()
      }
    )
    metalView.delegate = burnRenderer
    window.contentView = metalView

    panel = window
    renderer = burnRenderer
    window.orderFrontRegardless()

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
    panel?.orderOut(nil)
    panel = nil
    renderer = nil
  }
}
