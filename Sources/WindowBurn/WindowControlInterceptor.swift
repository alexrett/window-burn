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

enum SoakAndBurnPointerEvent { case down, dragged, up }

@MainActor
final class WindowControlInterceptor {
  typealias CloseHandler = @MainActor (AccessibleWindowControl) -> Bool
  typealias TorchHandler = @MainActor (CGPoint, AccessibleWindow?) -> Bool
  typealias SoakAndBurnHandler =
    @MainActor (SoakAndBurnPointerEvent, CGPoint, AccessibleWindow?) -> Bool

  private let closeHandler: CloseHandler
  private let torchHandler: TorchHandler
  private let soakAndBurnHandler: SoakAndBurnHandler
  private let input = PointerTapState()
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "input-diagnostics")
  private var resolver: PointerTargetResolver?
  private var drainTimer: Timer?
  private var acceptedSoakSequence: UInt64?
  var interactionState: (() -> (surfaces: [PointerTargetSnapshot.Region], canStart: Bool))?
  var isMenuTracking = false { didSet { publishConfiguration() } }
  var isTorchModeEnabled = false { didSet { publishConfiguration() } }
  var isSoakAndBurnModeEnabled = false {
    didSet {
      if !isSoakAndBurnModeEnabled { acceptedSoakSequence = nil }
      publishConfiguration()
    }
  }
  var latestPointerLocation: CGPoint? { input.latestPointerLocation }

  init(
    closeHandler: @escaping CloseHandler,
    torchHandler: @escaping TorchHandler,
    soakAndBurnHandler: @escaping SoakAndBurnHandler
  ) throws {
    self.closeHandler = closeHandler
    self.torchHandler = torchHandler
    self.soakAndBurnHandler = soakAndBurnHandler
    try input.start()
    resolver = PointerTargetResolver { [input] in input.publishTargets($0) }
    drainTimer = Self.scheduleDrain { [weak self] in self?.drain() }
  }

  static func scheduleDrain(_ drain: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
      // The timer is installed only on RunLoop.main below. Keep delivery
      // synchronous in common modes, including AppKit menu/drag tracking.
      MainActor.assumeIsolated { drain() }
    }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  func stop() {
    resolver?.stop()
    resolver = nil
    drainTimer?.invalidate()
    drainTimer = nil
    input.stop()
  }

  private func publishConfiguration() {
    let state = interactionState?()
    input.configure(
      mode: isSoakAndBurnModeEnabled ? .soak : (isTorchModeEnabled ? .torch : .close),
      surfaces: state?.surfaces ?? [], canStart: state?.canStart ?? true,
      isSuspended: isMenuTracking
    )
  }

  private func drain() {
    let batch = input.drain()
    for diagnostic in batch.diagnostics {
      logger.notice(
        "Pointer down: mode=\(diagnostic.mode, privacy: .public) decision=\(diagnostic.reason, privacy: .public) eventWindow=\(diagnostic.eventWindowID) preparedWindow=\(diagnostic.preparedWindowID) snapshotAgeMs=\(diagnostic.snapshotAge * 1_000, format: .fixed(precision: 2))"
      )
    }
    for event in batch.events {
      switch event.kind {
      case .down:
        guard let id = event.targetID, let route = batch.routes[id] else { continue }
        switch route {
        case .close(let control):
          if !closeHandler(control) { try? AccessibilityWindowService.perform(control) }
        case .torch(let window):
          guard isTorchModeEnabled else { continue }
          _ = torchHandler(event.point, window)
        case .soak(let window):
          guard isSoakAndBurnModeEnabled else { continue }
          if soakAndBurnHandler(.down, event.point, window) {
            acceptedSoakSequence = event.sequenceID
          }
        }
        publishConfiguration()
      case .dragged:
        if event.sequenceID == acceptedSoakSequence {
          _ = soakAndBurnHandler(.dragged, event.point, nil)
        }
      case .up:
        if event.sequenceID == acceptedSoakSequence {
          acceptedSoakSequence = nil
          _ = soakAndBurnHandler(.up, event.point, nil)
        }
      case .moved:
        break
      }
    }
    publishConfiguration()
  }
}

struct PointerDownDiagnostic: Sendable {
  let mode: String
  let reason: String
  let eventWindowID: Int64
  let preparedWindowID: CGWindowID
  let snapshotAge: TimeInterval
}

enum PointerRoute: Sendable {
  case close(AccessibleWindowControl)
  case torch(AccessibleWindow?)
  case soak(AccessibleWindow?)
}

/// The lock protects only value snapshots and a bounded queue. No AX, AppKit, GPU,
/// disk I/O or synchronous dispatch to the main actor is permitted under it.
final class PointerTapState: @unchecked Sendable {
  enum Mode { case close, torch, soak }
  private let lock = NSLock()
  private let clock: @Sendable () -> UInt64

  init(clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
    self.clock = clock
  }
  private var mode = Mode.close
  private var canStart = true
  private var isSuspended = false
  private var surfaces: [PointerTargetSnapshot.Region] = []
  private var targets = ResolvedPointerTargets()
  private var buffer = PointerEventBuffer(capacity: 128)
  private var routes: [UUID: PointerRoute] = [:]
  private var downDiagnostics: [PointerDownDiagnostic] = []
  private var sequence: UInt64 = 0
  private var activeTarget: UUID?
  private var isDiscardingOverflowSequence = false
  private var activeDownTimestamp: UInt64 = 0
  private var tap: CFMachPort?
  private var runLoop: CFRunLoop?
  private var stopped = false
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "interceptor")

  var latestPointerLocation: CGPoint? { lock.withLock { buffer.latestPointerEvent?.point } }

  func configure(
    mode: Mode, surfaces: [PointerTargetSnapshot.Region], canStart: Bool,
    isSuspended: Bool = false
  ) {
    lock.withLock {
      if mode != self.mode {
        routes = routes.filter { _, route in
          if case .close = route { return true }
          return false
        }
      }
      self.mode = mode
      self.surfaces = surfaces
      self.canStart = canStart
      self.isSuspended = isSuspended
    }
  }

  func publishTargets(_ targets: ResolvedPointerTargets) {
    lock.withLock { self.targets = targets }
  }

  func drain() -> (
    events: [PointerInputEvent], routes: [UUID: PointerRoute], diagnostics: [PointerDownDiagnostic]
  ) {
    lock.withLock {
      let result = (buffer.drain(), routes, downDiagnostics)
      routes.removeAll(keepingCapacity: true)
      downDiagnostics.removeAll(keepingCapacity: true)
      return result
    }
  }

  func start() throws {
    let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved]
      .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: windowControlEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else { throw WindowControlInterceptorError.eventTapUnavailable }
    self.tap = tap
    InputDiagnostics.productionTap(tap)
    let thread = Thread { [self] in runTap() }
    thread.name = "Window Burn mouse interception"
    thread.qualityOfService = .userInteractive
    thread.start()
    logger.info("Mouse interception uses a dedicated run loop and asynchronous UI delivery")
  }

  private func runTap() {
    guard let tap = lock.withLock({ self.tap }) else { return }
    let loop = CFRunLoopGetCurrent()!
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
    CFRunLoopAddSource(loop, source, .commonModes)
    let shouldRun = lock.withLock {
      runLoop = loop
      return !stopped
    }
    if shouldRun {
      CGEvent.tapEnable(tap: tap, enable: true)
      CFRunLoopRun()
    }
    CFRunLoopRemoveSource(loop, source, .commonModes)
    CFMachPortInvalidate(tap)
    lock.withLock { runLoop = nil }
  }

  func stop() {
    lock.withLock {
      stopped = true
      if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
      if let runLoop {
        CFRunLoopStop(runLoop)
        CFRunLoopWakeUp(runLoop)
      }
    }
  }

  func receive(type: CGEventType, event: CGEvent) -> Bool {
    receive(
      type: type, point: event.location, timestamp: event.timestamp,
      windowID: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
    )
  }

  func receive(type: CGEventType, point: CGPoint, timestamp time: UInt64, windowID: Int64) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      lock.withLock {
        if !stopped, let tap { CGEvent.tapEnable(tap: tap, enable: true) }
      }
      logger.notice("Mouse event tap re-enabled; timeout=\(type == .tapDisabledByTimeout)")
      return false
    }
    return lock.withLock {
      guard !stopped else { return false }
      var decision = "passed"
      var preparedWindowID: CGWindowID = 0
      let snapshotAge = ProcessInfo.processInfo.systemUptime - targets.windows.capturedAt
      defer {
        if type == .leftMouseDown, InputDiagnostics.isEnabled, downDiagnostics.count < 16 {
          downDiagnostics.append(
            .init(
              mode: String(describing: mode), reason: decision,
              eventWindowID: windowID, preparedWindowID: preparedWindowID, snapshotAge: snapshotAge)
          )
        }
      }
      let latestTime = buffer.latestPointerEvent?.timestamp ?? 0
      let nowNanoseconds = clock()
      let isRecent = nowNanoseconds <= time || nowNanoseconds - time <= 250_000_000
      let isFresh = time >= latestTime && isRecent
      switch type {
      case .leftMouseDown:
        guard isFresh else {
          decision = "stale-event"
          return false
        }
        isDiscardingOverflowSequence = false
        // A prior release can be absent after a tap interruption. Finish that gesture
        // before accepting another click, without reusing the stale drag position.
        if let activeTarget {
          _ = buffer.append(
            .init(
              kind: .up, point: point, timestamp: time,
              sequenceID: sequence, targetID: activeTarget))
          self.activeTarget = nil
        }
        guard !isSuspended else {
          decision = "menu-tracking"
          _ = buffer.append(.init(kind: .moved, point: point, timestamp: time, sequenceID: 0))
          return false
        }
        let now = ProcessInfo.processInfo.systemUptime
        let snapshot = mode == .close ? targets.controls : targets.windows
        let surface = mode == .close ? nil : surfaces.first { $0.frame.contains(point) }
        guard
          let targetID = snapshot.target(
            at: point, now: now, surfaces: mode == .close ? [] : surfaces),
          surface != nil || canStart
        else {
          decision = canStart ? "no-target" : "busy"
          _ = buffer.append(.init(kind: .moved, point: point, timestamp: time, sequenceID: 0))
          return false
        }
        let target = targets.targets[targetID]
        preparedWindowID = target?.windowID ?? 0
        if surface == nil, windowID > 0, windowID != Int64(target?.windowID ?? 0) {
          decision = "window-mismatch"
          return false
        }
        let route: PointerRoute
        switch mode {
        case .close:
          guard let control = target?.closeControl else { return false }
          route = .close(control)
        case .torch: route = .torch(surface == nil ? target?.window : nil)
        case .soak: route = .soak(surface == nil ? target?.window : nil)
        }
        sequence &+= 1
        let routeID = UUID()
        guard
          buffer.append(
            .init(
              kind: .down, point: point, timestamp: time,
              sequenceID: sequence, targetID: routeID))
        else {
          // A replacement surface must never leak clicks to the window beneath it,
          // even if the UI has stalled long enough to fill the bounded queue.
          isDiscardingOverflowSequence = surface != nil
          return isDiscardingOverflowSequence
        }
        routes[routeID] = route
        activeTarget = routeID
        activeDownTimestamp = time
        decision = "accepted"
        return true
      case .leftMouseDragged:
        if isDiscardingOverflowSequence { return true }
        if let activeTarget {
          guard isFresh else { return true }
          _ = buffer.append(
            .init(
              kind: .dragged, point: point, timestamp: time,
              sequenceID: sequence, targetID: activeTarget))
          return true
        }
      case .leftMouseUp:
        if isDiscardingOverflowSequence {
          isDiscardingOverflowSequence = false
          return true
        }
        if let activeTarget {
          guard time >= activeDownTimestamp else { return true }
          // Always finish an owned sequence, but never move artwork to an old point.
          let releasePoint = isFresh ? point : (buffer.latestPointerEvent?.point ?? point)
          _ = buffer.append(
            .init(
              kind: .up, point: releasePoint, timestamp: max(time, latestTime),
              sequenceID: sequence, targetID: activeTarget))
          self.activeTarget = nil
          return true
        }
      default: break
      }
      if isFresh {
        _ = buffer.append(.init(kind: .moved, point: point, timestamp: time, sequenceID: 0))
      }
      return false
    }
  }
}

private func windowControlEventTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
  userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userInfo else { return Unmanaged.passUnretained(event) }
  let input = Unmanaged<PointerTapState>.fromOpaque(userInfo).takeUnretainedValue()
  let startedAt = ProcessInfo.processInfo.systemUptime
  let suppressed = input.receive(type: type, event: event)
  InputDiagnostics.eventTap(
    type: type, duration: ProcessInfo.processInfo.systemUptime - startedAt,
    timestamp: event.timestamp
  )
  return suppressed ? nil : Unmanaged.passUnretained(event)
}
