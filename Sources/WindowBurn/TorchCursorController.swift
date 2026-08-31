import AppKit
import WindowBurnCore

enum EffectCursorStyle: Equatable {
  case torch
  case adultBadge(isSoaking: Bool)

  var size: CGSize {
    switch self {
    case .torch:
      CGSize(width: 60, height: 84)
    case .adultBadge:
      CGSize(width: 76, height: 118)
    }
  }

  var hotSpot: CGPoint {
    switch self {
    case .torch:
      CGPoint(x: 30, y: 61)
    case .adultBadge:
      CGPoint(x: 38, y: 83)
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
    case .adultBadge(let isSoaking):
      drawAdultBadge(isSoaking: isSoaking, in: context)
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

  private func drawAdultBadge(isSoaking: Bool, in context: NSGraphicsContext) {
    let pulse = isSoaking ? CGFloat((sin(animationTime * 12) + 1) * 0.5) : 0
    context.saveGraphicsState()

    let glow = NSShadow()
    glow.shadowColor = NSColor.systemYellow.withAlphaComponent(0.18 + pulse * 0.22)
    glow.shadowBlurRadius = 6 + pulse * 5
    glow.shadowOffset = .zero
    glow.set()

    let badgeRect = CGRect(x: 11, y: 56, width: 54, height: 54)
    let badge = NSBezierPath(ovalIn: badgeRect)
    NSColor(calibratedWhite: 0.055, alpha: 0.96).setFill()
    badge.fill()
    NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.08, alpha: 0.98).setStroke()
    badge.lineWidth = 3
    badge.stroke()

    let label = NSString(string: "18+")
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 18, weight: .black),
      .foregroundColor: NSColor.white,
      .kern: -0.7,
    ]
    let labelSize = label.size(withAttributes: attributes)
    label.draw(
      at: CGPoint(
        x: badgeRect.midX - labelSize.width / 2,
        y: badgeRect.midY - labelSize.height / 2 + 1
      ),
      withAttributes: attributes
    )

    guard isSoaking else {
      context.restoreGraphicsState()
      return
    }

    let streamWave = CGFloat(sin(animationTime * 16) * 1.6)
    let stream = NSBezierPath()
    stream.move(to: CGPoint(x: 38, y: 57))
    stream.curve(
      to: CGPoint(x: 38, y: 6),
      controlPoint1: CGPoint(x: 36 + streamWave, y: 42),
      controlPoint2: CGPoint(x: 40 - streamWave, y: 18)
    )
    stream.lineWidth = 4.2
    stream.lineCapStyle = .round
    NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.08, alpha: 0.96).setStroke()
    stream.stroke()

    let splash = NSBezierPath(ovalIn: CGRect(x: 31.5, y: 2, width: 13, height: 5))
    NSColor(calibratedRed: 1, green: 0.82, blue: 0.16, alpha: 0.72).setFill()
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
