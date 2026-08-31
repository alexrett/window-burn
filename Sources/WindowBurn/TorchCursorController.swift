import AppKit
import WindowBurnCore

enum EffectCursorStyle: Equatable {
  case torch
  case dog(isSoaking: Bool)

  var size: CGSize {
    switch self {
    case .torch:
      CGSize(width: 60, height: 84)
    case .dog:
      CGSize(width: 136, height: 100)
    }
  }

  var hotSpot: CGPoint {
    switch self {
    case .torch:
      CGPoint(x: 30, y: 61)
    case .dog:
      CGPoint(x: 116, y: 5)
    }
  }
}

@MainActor
final class TorchCursorController {
  private var panel: NSPanel?
  private var cursorView: EffectCursorView?
  private var timer: Timer?
  private var didHideSystemCursor = false
  private var isTemporarilyHidden = false
  private var isTrackingPointerDrag = false
  private(set) var style: EffectCursorStyle?
  var isEnabled: Bool { style != nil }

  func setEnabled(_ enabled: Bool) {
    setStyle(enabled ? .torch : nil)
  }

  func setStyle(_ style: EffectCursorStyle?) {
    guard style != self.style else { return }
    self.style = style

    guard let style else {
      isTrackingPointerDrag = false
      hide()
      return
    }

    cursorView?.style = style
    panel?.setContentSize(style.size)
    guard !isTemporarilyHidden else { return }
    show()
  }

  func setTemporarilyHidden(_ hidden: Bool) {
    guard hidden != isTemporarilyHidden else { return }
    isTemporarilyHidden = hidden
    if hidden {
      hide()
    } else if style != nil {
      show()
    }
  }

  func withoutOverlay<Result>(_ operation: () -> Result) -> Result {
    panel?.orderOut(nil)
    defer {
      if isEnabled, !isTemporarilyHidden {
        updatePosition()
        panel?.orderFrontRegardless()
      }
    }
    return operation()
  }

  func move(toQuartzPoint point: CGPoint) {
    let appKitPoint = ScreenCoordinateConverter.appKitPoint(
      forQuartzPoint: point,
      mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0
    )
    move(toAppKitPoint: appKitPoint)
  }

  func beginPointerDrag(atQuartzPoint point: CGPoint) {
    isTrackingPointerDrag = true
    move(toQuartzPoint: point)
  }

  func endPointerDrag(atQuartzPoint point: CGPoint) {
    move(toQuartzPoint: point)
    isTrackingPointerDrag = false
  }

  private func show() {
    guard let style, !isTemporarilyHidden else { return }

    if panel == nil {
      let panel = NSPanel(
        contentRect: CGRect(origin: .zero, size: style.size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.backgroundColor = .clear
      panel.isOpaque = false
      panel.hasShadow = false
      panel.ignoresMouseEvents = true
      panel.sharingType = .none
      panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
      panel.collectionBehavior = [
        .canJoinAllSpaces,
        .fullScreenAuxiliary,
        .ignoresCycle,
        .stationary,
      ]
      let cursorView = EffectCursorView(frame: CGRect(origin: .zero, size: style.size))
      cursorView.style = style
      cursorView.autoresizingMask = [.width, .height]
      cursorView.setAccessibilityElement(false)
      panel.contentView = cursorView
      self.cursorView = cursorView
      self.panel = panel
    }

    if !didHideSystemCursor {
      NSCursor.hide()
      didHideSystemCursor = true
    }
    updatePosition()
    panel?.orderFrontRegardless()

    if timer == nil {
      let timer = Timer(
        timeInterval: 1.0 / 30.0,
        target: self,
        selector: #selector(updatePosition),
        userInfo: nil,
        repeats: true
      )
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }
  }

  private func hide() {
    timer?.invalidate()
    timer = nil
    panel?.orderOut(nil)
    if didHideSystemCursor {
      NSCursor.unhide()
      didHideSystemCursor = false
    }
  }

  @objc private func updatePosition() {
    if !isTrackingPointerDrag {
      move(toAppKitPoint: NSEvent.mouseLocation)
    } else {
      updateArtwork()
    }
  }

  private func move(toAppKitPoint point: CGPoint) {
    guard let style else { return }
    panel?.setFrameOrigin(
      CGPoint(
        x: point.x - style.hotSpot.x,
        y: point.y - style.hotSpot.y
      )
    )
    updateArtwork()
  }

  private func updateArtwork() {
    cursorView?.animationTime = ProcessInfo.processInfo.systemUptime
    cursorView?.needsDisplay = true
  }
}

private final class EffectCursorView: NSView {
  private lazy var dogImage = Self.resourceImage(named: "dog-cursor")
  private lazy var torchImage = Self.resourceImage(named: "torch-base")

  var style: EffectCursorStyle = .torch {
    didSet { needsDisplay = true }
  }
  var animationTime: TimeInterval = 0

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let context = NSGraphicsContext.current else { return }

    switch style {
    case .torch:
      drawTorch(in: context)
    case .dog(let isSoaking):
      drawDog(isSoaking: isSoaking, in: context)
    }
  }

  private func drawTorch(in context: NSGraphicsContext) {
    let sway = CGFloat(sin(animationTime * 8.7) * 3.2 + sin(animationTime * 15.1) * 1.1)
    let pulse = CGFloat((sin(animationTime * 11.3) + 1) * 0.5)

    context.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.systemOrange.withAlphaComponent(0.76 + pulse * 0.18)
    glow.shadowBlurRadius = 11 + pulse * 5
    glow.shadowOffset = .zero
    glow.set()

    let outerFlame = NSBezierPath()
    outerFlame.move(to: CGPoint(x: 30, y: 82))
    outerFlame.curve(
      to: CGPoint(x: 13, y: 49),
      controlPoint1: CGPoint(x: 22 + sway, y: 74),
      controlPoint2: CGPoint(x: 11 - sway * 0.5, y: 62)
    )
    outerFlame.curve(
      to: CGPoint(x: 30, y: 39),
      controlPoint1: CGPoint(x: 12, y: 42),
      controlPoint2: CGPoint(x: 21, y: 38)
    )
    outerFlame.curve(
      to: CGPoint(x: 47, y: 51),
      controlPoint1: CGPoint(x: 42, y: 38),
      controlPoint2: CGPoint(x: 49 + sway * 0.35, y: 43)
    )
    outerFlame.curve(
      to: CGPoint(x: 31, y: 74 + pulse * 4),
      controlPoint1: CGPoint(x: 47, y: 62),
      controlPoint2: CGPoint(x: 38 + sway, y: 68)
    )
    outerFlame.curve(
      to: CGPoint(x: 30, y: 82),
      controlPoint1: CGPoint(x: 30 + sway, y: 77),
      controlPoint2: CGPoint(x: 30 + sway * 0.4, y: 80)
    )
    outerFlame.close()
    NSGradient(colors: [.systemRed, .systemOrange, .systemYellow])?.draw(
      in: outerFlame,
      angle: 90 + sway
    )

    let innerFlame = NSBezierPath()
    innerFlame.move(to: CGPoint(x: 31 + sway * 0.3, y: 69 + pulse * 3))
    innerFlame.curve(
      to: CGPoint(x: 21, y: 48),
      controlPoint1: CGPoint(x: 26 + sway, y: 62),
      controlPoint2: CGPoint(x: 19, y: 55)
    )
    innerFlame.curve(
      to: CGPoint(x: 31, y: 42),
      controlPoint1: CGPoint(x: 21, y: 43),
      controlPoint2: CGPoint(x: 27, y: 41)
    )
    innerFlame.curve(
      to: CGPoint(x: 31 + sway * 0.3, y: 69 + pulse * 3),
      controlPoint1: CGPoint(x: 39, y: 47),
      controlPoint2: CGPoint(x: 36 + sway * 0.4, y: 58)
    )
    innerFlame.close()
    NSColor(calibratedRed: 1, green: 0.94, blue: 0.31, alpha: 1).setFill()
    innerFlame.fill()
    context.restoreGraphicsState()

    torchImage?.draw(
      in: CGRect(x: 12, y: 0, width: 36, height: 54),
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )

    context.saveGraphicsState()
    let sparkPhase = CGFloat(animationTime.truncatingRemainder(dividingBy: 0.7) / 0.7)
    let spark = NSBezierPath(
      ovalIn: CGRect(
        x: 38 + sway * 0.4,
        y: 56 + sparkPhase * 22,
        width: 2.2 - sparkPhase,
        height: 2.2 - sparkPhase
      )
    )
    NSColor.systemYellow.withAlphaComponent(1 - sparkPhase).setFill()
    spark.fill()
    context.restoreGraphicsState()
  }

  private func drawDog(isSoaking: Bool, in context: NSGraphicsContext) {
    let bob = isSoaking ? CGFloat(sin(animationTime * 13) * 1.1) : 0
    dogImage?.draw(
      in: CGRect(x: 2, y: 13 + bob, width: 126, height: 84),
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: [.interpolation: NSImageInterpolation.high]
    )

    guard isSoaking else { return }
    context.saveGraphicsState()
    let pulse = CGFloat(sin(animationTime * 16) * 2.2)
    let stream = NSBezierPath()
    stream.move(to: CGPoint(x: 52, y: 39 + bob))
    stream.curve(
      to: CGPoint(x: 116, y: 5),
      controlPoint1: CGPoint(x: 73, y: 35 + pulse),
      controlPoint2: CGPoint(x: 103, y: 13 - pulse)
    )
    stream.lineWidth = 4.4
    stream.lineCapStyle = .round
    NSColor(calibratedRed: 0.99, green: 0.80, blue: 0.11, alpha: 0.92).setStroke()
    stream.stroke()

    let splash = NSBezierPath(ovalIn: CGRect(x: 109, y: 1, width: 15, height: 5.5))
    NSColor(calibratedRed: 1, green: 0.87, blue: 0.24, alpha: 0.70).setFill()
    splash.fill()
    context.restoreGraphicsState()
  }

  private static func resourceImage(named name: String) -> NSImage? {
    guard
      let url = Bundle.main.url(forResource: name, withExtension: "png")
        ?? Bundle.module.url(forResource: name, withExtension: "png")
    else {
      return nil
    }
    return NSImage(contentsOf: url)
  }
}
