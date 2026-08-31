import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

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
  var isTorchModeEnabled = false
  var isSoakAndBurnModeEnabled = false

  init(
    closeHandler: @escaping CloseHandler,
    torchHandler: @escaping TorchHandler,
    soakAndBurnHandler: @escaping SoakAndBurnHandler
  ) throws {
    self.closeHandler = closeHandler
    self.torchHandler = torchHandler
    self.soakAndBurnHandler = soakAndBurnHandler

    let eventMask =
      (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseDragged.rawValue)
      | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)
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
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: eventTap, enable: true)
    logger.info("Close-button, torch, and soak-and-burn mouse interception is active")
  }

  func stop() {
    guard let runLoopSource else { return }
    CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    self.runLoopSource = nil
    eventTap = nil
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
      _ = soakAndBurnHandler(.up, location)
      logger.info("Finished an intercepted soak-and-burn pointer sequence")
      return true
    }

    if type == .leftMouseDragged, isSuppressingSoakSequence {
      _ = soakAndBurnHandler(.dragged, location)
      return true
    }

    if type == .leftMouseDown, isSoakAndBurnModeEnabled,
      soakAndBurnHandler(.down, location)
    {
      isSuppressingSoakSequence = true
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

  let shouldSuppress = MainActor.assumeIsolated {
    interceptor.shouldSuppress(type: type, location: location)
  }
  return shouldSuppress ? nil : Unmanaged.passUnretained(event)
}
