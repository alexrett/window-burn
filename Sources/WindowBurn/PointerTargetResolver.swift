import ApplicationServices
import Foundation
import OSLog
import WindowBurnCore

struct ResolvedPointerTarget: Sendable {
  let windowID: CGWindowID
  let window: AccessibleWindow
  let closeControl: AccessibleWindowControl?
}

struct ResolvedPointerTargets: Sendable {
  var windows = PointerTargetSnapshot(regions: [], capturedAt: 0)
  var controls = PointerTargetSnapshot(regions: [], capturedAt: 0)
  var targets: [UUID: ResolvedPointerTarget] = [:]
}

/// AX and WindowServer queries run here, never on the mouse tap or the UI thread.
final class PointerTargetResolver: Sendable {
  private let timer: DispatchSourceTimer

  init(publish: @escaping @Sendable (ResolvedPointerTargets) -> Void) {
    let queue = DispatchQueue(label: "dev.malikov.WindowBurn.input-targets", qos: .userInitiated)
    let diagnostics = PointerResolverDiagnostics()
    timer = DispatchSource.makeTimerSource(queue: queue)
    timer.setEventHandler { publish(Self.resolve(diagnostics: diagnostics)) }
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
    timer.resume()
  }

  func stop() { timer.cancel() }

  static func nativeInputCandidates(from candidates: [PointWindowCandidate])
    -> [PointWindowCandidate]
  {
    // WindowServer lists visual surfaces, including click-through screen-recording
    // and cursor overlays. Only normal application windows define native targets
    // and occlusion; our effect panels have explicit interaction surfaces.
    candidates.filter { $0.layer == 0 && $0.isOnScreen && $0.alpha > 0.01 }
  }

  private static func resolve(diagnostics: PointerResolverDiagnostics) -> ResolvedPointerTargets {
    let startedAt = ProcessInfo.processInfo.systemUptime
    let deadline = startedAt + 0.2
    let ownPID = ProcessInfo.processInfo.processIdentifier
    var windowRegions: [PointerTargetSnapshot.Region] = []
    var controlRegions: [PointerTargetSnapshot.Region] = []
    var targets: [UUID: ResolvedPointerTarget] = [:]
    var windowsByPID: [pid_t: [AccessibleWindow]] = [:]
    let candidates = WindowServerWindowService.onScreenWindows()
    for candidate in Self.nativeInputCandidates(from: candidates) {
      let blocked = PointerTargetSnapshot.Region(id: nil, frame: candidate.frame)
      guard candidate.ownerPID != ownPID,
        ProcessInfo.processInfo.systemUptime < deadline
      else {
        windowRegions.append(blocked)
        controlRegions.append(blocked)
        continue
      }
      if windowsByPID[candidate.ownerPID] == nil {
        windowsByPID[candidate.ownerPID] = AccessibilityWindowService.preflightWindows(
          ownerPID: candidate.ownerPID, deadline: deadline)
      }
      guard
        let window = AccessibilityWindowService.window(
          matching: TargetWindow(
            ownerPID: candidate.ownerPID, title: candidate.title, frame: candidate.frame),
          among: windowsByPID[candidate.ownerPID] ?? []),
        window.target.frame.equalTo(candidate.frame)
      else {
        windowRegions.append(blocked)
        controlRegions.append(blocked)
        continue
      }
      let id = UUID()
      let control = AccessibilityWindowService.closeControl(in: window, deadline: deadline)
      // Both interactive tools eventually close the window. Unsupported windows pass through.
      targets[id] = ResolvedPointerTarget(
        windowID: candidate.id, window: window, closeControl: control?.0)
      windowRegions.append(.init(id: control == nil ? nil : id, frame: candidate.frame))
      if let control { controlRegions.append(.init(id: id, frame: control.1)) }
      controlRegions.append(blocked)
    }
    diagnostics.record(
      duration: ProcessInfo.processInfo.systemUptime - startedAt,
      windowCount: candidates.count, applicationCount: windowsByPID.count,
      targetCount: windowRegions.filter { $0.id != nil }.count)
    return ResolvedPointerTargets(
      windows: .init(regions: windowRegions, capturedAt: startedAt),
      controls: .init(regions: controlRegions, capturedAt: startedAt), targets: targets
    )
  }
}

/// Accessed exclusively by the resolver's serial queue.
private final class PointerResolverDiagnostics: @unchecked Sendable {
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "input-diagnostics")
  private var lastReportAt = ProcessInfo.processInfo.systemUptime
  private var passes = 0
  private var maximumDuration: TimeInterval = 0
  private var budgetExhaustions = 0

  func record(duration: TimeInterval, windowCount: Int, applicationCount: Int, targetCount: Int) {
    guard InputDiagnostics.isEnabled else { return }
    passes += 1
    maximumDuration = max(maximumDuration, duration)
    if duration >= 0.2 { budgetExhaustions += 1 }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastReportAt >= 1 else { return }
    let message =
      "resolver[passes=\(passes),maxMs=\(String(format: "%.2f", maximumDuration * 1_000)),"
      + "budgetExhaustions=\(budgetExhaustions),windows=\(windowCount),"
      + "applications=\(applicationCount),targets=\(targetCount)]"
    logger.notice("\(message, privacy: .public)")
    lastReportAt = now
    passes = 0
    maximumDuration = 0
    budgetExhaustions = 0
  }
}
