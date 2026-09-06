import CoreGraphics
import Foundation
import OSLog
import QuartzCore

/// Opt-in timing and event counts. Never records window contents or pointer coordinates.
enum InputDiagnostics {
  static let isEnabled = CommandLine.arguments.contains("--input-diagnostics")
  private static let recorder = InputDiagnosticsRecorder()
  @MainActor private static var heartbeatTimer: Timer?

  @MainActor static func start() {
    guard isEnabled, heartbeatTimer == nil else { return }
    let recorder = recorder
    recorder.heartbeat()
    let timer = Timer(timeInterval: 0.1, repeats: true) { _ in recorder.heartbeat() }
    heartbeatTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    recorder.start()
  }

  static func productionTap(_ tap: CFMachPort) {
    guard isEnabled else { return }
    recorder.productionTap(tap)
  }

  static func eventTap(
    type: CGEventType, duration: TimeInterval, timestamp: CGEventTimestamp = 0
  ) {
    guard isEnabled else { return }
    recorder.productionEvent(type: type, duration: duration, timestamp: timestamp)
  }

  static func cursorMoved(point: CGPoint) {
    guard isEnabled else { return }
    recorder.cursorMoved(point: point)
  }

  static func recoverySample(point: CGPoint, isPressed: Bool) {
    guard isEnabled else { return }
    recorder.recoverySample(point: point, isPressed: isPressed)
  }

  static func drawableWait(_ duration: TimeInterval) {
    guard isEnabled else { return }
    recorder.drawableWait(duration)
  }
}

// All mutable metrics are guarded by the lock. The report source is configured once
// before resume; the HID tap and its run loop are owned exclusively by their thread.
private final class InputDiagnosticsRecorder: @unchecked Sendable {
  private struct EventCounts {
    var down = 0
    var moved = 0
    var dragged = 0
    var up = 0
    var disabledByTimeout = 0
    var disabledByUserInput = 0

    mutating func add(_ type: CGEventType) {
      switch type {
      case .leftMouseDown: down += 1
      case .mouseMoved: moved += 1
      case .leftMouseDragged: dragged += 1
      case .leftMouseUp: up += 1
      case .tapDisabledByTimeout: disabledByTimeout += 1
      case .tapDisabledByUserInput: disabledByUserInput += 1
      default: break
      }
    }

    var description: String {
      "down=\(down),move=\(moved),drag=\(dragged),up=\(up),"
        + "timeout=\(disabledByTimeout),userDisabled=\(disabledByUserInput)"
    }
  }

  private struct IntervalMetrics {
    var raw = EventCounts()
    var production = EventCounts()
    var maximumCallbackDuration: TimeInterval = 0
    var slowCallbacks = 0
    var eventAgeSamples = 0
    var maximumEventAge: TimeInterval = 0
    var cursorMoves = 0
    var cursorPositionChanges = 0
    var recoverySamples = 0
    var recoveryPositionChanges = 0
    var recoveryPressedSamples = 0
    var drawableSamples = 0
    var maximumDrawableWait: TimeInterval = 0
  }

  private struct State {
    var started = false
    var observerAvailable = false
    var productionTap: CFMachPort?
    var heartbeat: TimeInterval = 0
    var previousRecoveryPoint: CGPoint?
    var previousCursorPoint: CGPoint?
    var previousHIDPoint: CGPoint?
    var previousSessionPoint: CGPoint?
    var interval = IntervalMetrics()
  }

  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "input-diagnostics")
  private let lock = NSLock()
  private var state = State()
  private let reportTimer = DispatchSource.makeTimerSource(
    queue: DispatchQueue(label: "dev.malikov.WindowBurn.input-diagnostics", qos: .utility)
  )

  func start() {
    let shouldStart = lock.withLock {
      guard !state.started else { return false }
      state.started = true
      return true
    }
    guard shouldStart else { return }
    let thread = Thread { [self] in runHIDObserver() }
    thread.name = "Window Burn input diagnostics HID observer"
    thread.qualityOfService = .userInteractive
    thread.start()
    reportTimer.setEventHandler { [weak self] in self?.report() }
    reportTimer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(50))
    reportTimer.resume()
    logger.notice("Input diagnostics enabled; interval counts only, no pointer coordinates")
  }

  func heartbeat() {
    lock.withLock { state.heartbeat = CACurrentMediaTime() }
  }

  func productionTap(_ tap: CFMachPort) {
    lock.withLock { state.productionTap = tap }
  }

  func productionEvent(
    type: CGEventType, duration: TimeInterval, timestamp: CGEventTimestamp
  ) {
    let eventAge: TimeInterval?
    if timestamp != 0, type != .tapDisabledByTimeout, type != .tapDisabledByUserInput {
      let uptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
      let elapsedNanoseconds = uptimeNanoseconds >= timestamp ? uptimeNanoseconds - timestamp : 0
      eventAge = max(0, Double(elapsedNanoseconds) / 1_000_000_000 - duration)
    } else {
      eventAge = nil
    }
    lock.withLock {
      state.interval.production.add(type)
      state.interval.maximumCallbackDuration = max(
        state.interval.maximumCallbackDuration, duration
      )
      if duration >= 0.016 { state.interval.slowCallbacks += 1 }
      if let eventAge {
        state.interval.eventAgeSamples += 1
        state.interval.maximumEventAge = max(state.interval.maximumEventAge, eventAge)
      }
    }
  }

  func rawEvent(_ type: CGEventType) {
    lock.withLock { state.interval.raw.add(type) }
  }

  func cursorMoved(point: CGPoint) {
    lock.withLock {
      state.interval.cursorMoves += 1
      if let previous = state.previousCursorPoint, previous != point {
        state.interval.cursorPositionChanges += 1
      }
      state.previousCursorPoint = point
    }
  }

  func recoverySample(point: CGPoint, isPressed: Bool) {
    lock.withLock {
      state.interval.recoverySamples += 1
      if let previous = state.previousRecoveryPoint, previous != point {
        state.interval.recoveryPositionChanges += 1
      }
      if isPressed { state.interval.recoveryPressedSamples += 1 }
      state.previousRecoveryPoint = point
    }
  }

  func drawableWait(_ duration: TimeInterval) {
    lock.withLock {
      state.interval.drawableSamples += 1
      state.interval.maximumDrawableWait = max(state.interval.maximumDrawableWait, duration)
    }
  }

  private func runHIDObserver() {
    let context = InputDiagnosticsHIDContext(recorder: self)
    let mask = [
      CGEventType.leftMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp,
    ].reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cghidEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: inputDiagnosticsHIDCallback,
        userInfo: Unmanaged.passUnretained(context).toOpaque()
      ),
      let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    else {
      logger.error("Read-only HID observer unavailable; other diagnostic metrics remain active")
      return
    }
    context.tap = tap
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopAddSource(runLoop, source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    lock.withLock { state.observerAvailable = true }
    withExtendedLifetime(context) { CFRunLoopRun() }
    lock.withLock { state.observerAvailable = false }
    CFRunLoopRemoveSource(runLoop, source, .commonModes)
    CFMachPortInvalidate(tap)
  }

  private func report() {
    let now = CACurrentMediaTime()
    let productionTap = lock.withLock { state.productionTap }
    let productionTapEnabled = productionTap.map { CGEvent.tapIsEnabled(tap: $0) }
    let hidPressed = CGEventSource.buttonState(.hidSystemState, button: .left)
    let sessionPressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
    let hidPoint = CGEventSource(stateID: .hidSystemState).flatMap { CGEvent(source: $0)?.location }
    let sessionPoint = CGEventSource(stateID: .combinedSessionState).flatMap {
      CGEvent(source: $0)?.location
    }
    let report = lock.withLock {
      let interval = state.interval
      state.interval = IntervalMetrics()
      let hidChanged = changed(previous: state.previousHIDPoint, current: hidPoint)
      let sessionChanged = changed(previous: state.previousSessionPoint, current: sessionPoint)
      state.previousHIDPoint = hidPoint
      state.previousSessionPoint = sessionPoint
      return (
        interval, max(0, now - state.heartbeat), state.observerAvailable,
        hidChanged, sessionChanged
      )
    }
    let (metrics, heartbeatAge, observerAvailable, hidChanged, sessionChanged) = report
    let message =
      "hidObserver=\(observerAvailable) raw[\(metrics.raw.description)] "
      + "tap[\(metrics.production.description)] "
      + "tapEnabled=\(productionTapEnabled.map(String.init) ?? "unavailable") "
      + "callbackMaxMs=\(milliseconds(metrics.maximumCallbackDuration)) "
      + "callbacksOver16ms=\(metrics.slowCallbacks) "
      + "eventAge[samples=\(metrics.eventAgeSamples),maxMs=\(milliseconds(metrics.maximumEventAge))] "
      + "cursor[calls=\(metrics.cursorMoves),changed=\(metrics.cursorPositionChanges)] "
      + "mainAgeMs=\(milliseconds(heartbeatAge)) "
      + "recovery[samples=\(metrics.recoverySamples),changed=\(metrics.recoveryPositionChanges),"
      + "pressed=\(metrics.recoveryPressedSamples)] "
      + "buttons[hid=\(hidPressed),session=\(sessionPressed)] "
      + "positionChanged[hid=\(hidChanged),session=\(sessionChanged)] "
      + "drawable[samples=\(metrics.drawableSamples),maxMs=\(milliseconds(metrics.maximumDrawableWait))]"
    logger.notice("\(message, privacy: .public)")
  }

  private func changed(previous: CGPoint?, current: CGPoint?) -> String {
    guard let previous, let current else { return "unavailable" }
    return previous != current ? "yes" : "no"
  }

  private func milliseconds(_ duration: TimeInterval) -> String {
    String(format: "%.2f", duration * 1_000)
  }
}

/// Only the observer thread touches the tap. Its retained lifetime spans CFRunLoopRun.
private final class InputDiagnosticsHIDContext {
  let recorder: InputDiagnosticsRecorder
  var tap: CFMachPort?

  init(recorder: InputDiagnosticsRecorder) { self.recorder = recorder }
}

private func inputDiagnosticsHIDCallback(
  proxy: CGEventTapProxy,
  type: CGEventType,
  event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  if let userInfo {
    let context = Unmanaged<InputDiagnosticsHIDContext>.fromOpaque(userInfo).takeUnretainedValue()
    context.recorder.rawEvent(type)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput, let tap = context.tap {
      CGEvent.tapEnable(tap: tap, enable: true)
    }
  }
  return Unmanaged.passUnretained(event)
}
