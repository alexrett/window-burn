import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import WindowBurnCore

enum WindowControlInterceptorError: LocalizedError {
  case eventTapUnavailable

  var errorDescription: String? {
    "Window Burn could not install its mouse event tap. Grant Accessibility and Input Monitoring permissions, restart the app, and retry."
  }
}

enum SoakAndBurnPointerEvent {
  case down
  case dragged
  case up
}

@MainActor
final class WindowControlInterceptor {
  typealias CloseHandler = @MainActor (AccessibleWindowControl) -> Bool
  typealias TorchHandler = @MainActor (CGPoint) -> Bool
  typealias SoakAndBurnHandler = @MainActor (SoakAndBurnPointerEvent, CGPoint) -> Bool

  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "interceptor")
  private let closeHandler: CloseHandler
  private let torchHandler: TorchHandler
  private let soakAndBurnHandler: SoakAndBurnHandler
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var suppressNextLeftMouseUp = false
  private var isSuppressingSoakSequence = false
  private var dragRecovery = PointerDragRecovery()
  private var dragTimer: Timer?
  var isTorchModeEnabled = false
  var isSoakAndBurnModeEnabled = false {
    didSet {
      if !isSoakAndBurnModeEnabled { stopDragRecovery() }
    }
  }

  init(
    closeHandler: @escaping CloseHandler,
    torchHandler: @escaping TorchHandler,
    soakAndBurnHandler: @escaping SoakAndBurnHandler
  ) throws {
    self.closeHandler = closeHandler
    self.torchHandler = torchHandler
    self.soakAndBurnHandler = soakAndBurnHandler

    var eventMask =
      (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
    // Observe possible session-level reclassification without suppressing mouseMoved.
    if InputDiagnostics.isEnabled {
      eventMask |= CGEventMask(1) << CGEventType.mouseMoved.rawValue
    }
    guard
      let eventTap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: eventMask,
        callback: windowControlEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      throw WindowControlInterceptorError.eventTapUnavailable
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
    self.eventTap = eventTap
    InputDiagnostics.productionTap(eventTap)
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    logger.info("Close-button, torch, and soak-and-burn mouse interception is active")
  }

  func stop() {
    stopDragRecovery()
    guard let runLoopSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    self.runLoopSource = nil
    eventTap = nil
  }

  private func stopDragRecovery() {
    dragTimer?.invalidate()
    dragTimer = nil
    dragRecovery.end()
  }

  private func startDragRecovery(at point: CGPoint) {
    stopDragRecovery()
    dragRecovery.begin(at: point)
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.recoverPointerState() }
    }
    dragTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func recoverPointerState() {
    guard
      let source = CGEventSource(stateID: .hidSystemState),
      let location = CGEvent(source: source)?.location
    else { return }
    let pressed = CGEventSource.buttonState(.hidSystemState, button: .left)
    InputDiagnostics.recoverySample(point: location, isPressed: pressed)
    switch dragRecovery.sample(at: location, isPressed: pressed) {
    case .dragged:
      _ = soakAndBurnHandler(.dragged, location)
    case .up:
      stopDragRecovery()
      _ = soakAndBurnHandler(.up, location)
      logger.notice("Recovered a soak pointer release from hardware state")
    case nil:
      break
    }
  }

  fileprivate func shouldSuppress(type: CGEventType, location: CGPoint) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
        logger.notice("Mouse event tap was re-enabled after macOS disabled it")
      }
      return false
    }

    if type == .leftMouseUp, suppressNextLeftMouseUp {
      suppressNextLeftMouseUp = false
      return true
    }

    if type == .leftMouseUp, isSuppressingSoakSequence {
      isSuppressingSoakSequence = false
      if dragRecovery.isActive {
        stopDragRecovery()
        _ = soakAndBurnHandler(.up, location)
      }
      logger.info("Finished an intercepted soak-and-burn pointer sequence")
      return true
    }

    if type == .leftMouseDragged, isSuppressingSoakSequence {
      if dragRecovery.sample(at: location, isPressed: true) != nil {
        _ = soakAndBurnHandler(.dragged, location)
      }
      return true
    }

    if type == .leftMouseDown {
      // A hardware-recovered release may never reach this tap.
      isSuppressingSoakSequence = false
      suppressNextLeftMouseUp = false
    }

    if type == .leftMouseDown, isSoakAndBurnModeEnabled,
      soakAndBurnHandler(.down, location)
    {
      isSuppressingSoakSequence = true
      startDragRecovery(at: location)
      logger.info("Intercepted a soak-and-burn click")
      return true
    }

    if type == .leftMouseDown, isTorchModeEnabled, torchHandler(location) {
      suppressNextLeftMouseUp = true
      logger.info("Intercepted a torch ignition click")
      return true
    }

    guard
      type == .leftMouseDown,
      let control = AccessibilityWindowService.windowControl(at: location),
      closeHandler(control)
    else {
      return false
    }

    suppressNextLeftMouseUp = true
    logger.info("Intercepted a \(control.kind.logName, privacy: .public) button click")
    return true
  }
}

private func windowControlEventTapCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let interceptor = Unmanaged<WindowControlInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
  let location = event.location
  let startedAt = ProcessInfo.processInfo.systemUptime
  defer {
    InputDiagnostics.eventTap(
      type: type, duration: ProcessInfo.processInfo.systemUptime - startedAt,
      timestamp: event.timestamp)
  }

  let shouldSuppress = MainActor.assumeIsolated {
    interceptor.shouldSuppress(type: type, location: location)
  }
  return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}
