import AppKit
import OSLog
import WindowBurnCore

@MainActor
private final class TorchWindowSession {
  let accessibleWindow: AccessibleWindow
  let overlay = BurnOverlayController()
  var captureFrame: CGRect
  var pendingClicks: [CGPoint]
  var isOverlayReady = false

  init(accessibleWindow: AccessibleWindow, initialClick: CGPoint) {
    self.accessibleWindow = accessibleWindow
    captureFrame = accessibleWindow.target.frame
    pendingClicks = [initialClick]
  }
}

@MainActor
final class BurnCoordinator {
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "burn")
  private let overlay = BurnOverlayController()
  private var isBusy = false
  private var torchSessionRegistry = TorchWindowSessionRegistry()
  private var torchSessions: [UUID: TorchWindowSession] = [:]
  private var soakAndBurnSession = SoakAndBurnSession()
  private var soakedWindow: AccessibleWindow?
  private var soakCaptureFrame: CGRect?
  private var isSoakOverlayActive = false
  private var pendingSoakRelease = false
  private var pendingSoakTrail = SoakTrail()
  private var soakGeneration = 0
  private var soakCloseTask: Task<Void, Never>?
  var onSoakAndBurnPhaseChange: ((SoakAndBurnPhase) -> Void)?
  var onSoakCaptureStateChange: ((Bool) -> Void)?
  var onDestructiveCloseFailure: (() -> Void)?

  func burnFrontWindow() {
    guard !isBusy, torchSessions.isEmpty else { return }
    isBusy = true

    Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        let accessibleWindow = try AccessibilityWindowService.focusedWindow()
        let capturedWindow = try await WindowCaptureService.capture(
          target: accessibleWindow.target
        )
        let panelFrame = ScreenCoordinateConverter.appKitFrame(
          for: capturedWindow.captureFrame,
          mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
          padding: BurnOverlayController.padding
        )
        let profile = BurnProfile.random()

        try overlay.present(
          image: capturedWindow.image,
          shadowImage: capturedWindow.shadowImage,
          shadowSamplingOffset: capturedWindow.shadowSamplingOffset,
          panelFrame: panelFrame,
          profile: profile,
          startImmediately: false,
          onFirstFrame: nil,
          completion: { [weak self] in self?.isBusy = false }
        )
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(accessibleWindow)
        guard overlay.activateReplacementSurface() else {
          throw BurnOverlayError.rendererUnavailable
        }
        overlay.startBurning()
        logger.info(
          "Burning front window owned by pid \(accessibleWindow.target.ownerPID), duration \(profile.duration, format: .fixed(precision: 2))s"
        )
      } catch {
        overlay.dismiss()
        isBusy = false
        onDestructiveCloseFailure?()
        logger.error("Burn failed: \(error.localizedDescription, privacy: .public)")
        showError(error)
      }
    }
  }

  func interceptWindowControl(_ control: AccessibleWindowControl) -> Bool {
    guard !isBusy, torchSessions.isEmpty else { return false }
    isBusy = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      var didRequestClose = false

      do {
        let capturedWindow = try await WindowCaptureService.capture(
          target: control.window.target
        )
        let panelFrame = ScreenCoordinateConverter.appKitFrame(
          for: capturedWindow.captureFrame,
          mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
          padding: BurnOverlayController.padding
        )
        let profile = BurnProfile.random()

        try overlay.present(
          image: capturedWindow.image,
          shadowImage: capturedWindow.shadowImage,
          shadowSamplingOffset: capturedWindow.shadowSamplingOffset,
          panelFrame: panelFrame,
          profile: profile,
          startImmediately: false,
          onFirstFrame: nil,
          completion: { [weak self] in self?.isBusy = false }
        )
        try AccessibilityWindowService.perform(control)
        didRequestClose = true
        try await AccessibilityWindowService.finishClosingDiscardingUnsavedChanges(
          control.window
        )
        guard overlay.activateReplacementSurface() else {
          throw BurnOverlayError.rendererUnavailable
        }
        overlay.startBurning()
        logger.info(
          "Burning intercepted \(control.kind.logName, privacy: .public) action for pid \(control.window.target.ownerPID), duration \(profile.duration, format: .fixed(precision: 2))s"
        )
      } catch {
        overlay.dismiss()
        switch WindowControlInterceptionPolicy.recovery(
          didRequestClose: didRequestClose
        ) {
        case .replayNativeActionSilently:
          do {
            try AccessibilityWindowService.perform(control)
          } catch {
            logger.error(
              "Fallback \(control.kind.logName, privacy: .public) action failed: \(error.localizedDescription, privacy: .public)"
            )
          }
        case .leaveNativeCloseFlowInPlaceSilently:
          break
        }
        isBusy = false
        logger.notice(
          "Passed intercepted \(control.kind.logName, privacy: .public) action back to macOS after the burn was skipped: \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    return true
  }

  func interceptTorchClick(at screenPoint: CGPoint) -> Bool {
    if let sessionID = torchSessionRegistry.sessionID(containing: screenPoint),
      let session = torchSessions[sessionID],
      let ignition = TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: session.captureFrame
      )
    {
      if session.isOverlayReady {
        let added = session.overlay.addIgnition(ignition)
        if added {
          logger.info(
            "Added another torch ignition to session \(sessionID.uuidString, privacy: .public) at \(ignition.x, format: .fixed(precision: 2)), \(ignition.y, format: .fixed(precision: 2))"
          )
        } else {
          logger.info(
            "Ignored torch ignition because session \(sessionID.uuidString, privacy: .public) already has the maximum number of points"
          )
        }
      } else if session.pendingClicks.count < TorchIgnitionField.maximumCount {
        session.pendingClicks.append(screenPoint)
      }
      return true
    }

    if torchSessionRegistry.isAtCapacity {
      logger.info(
        "Ignored torch ignition because \(TorchWindowSessionRegistry.maximumConcurrentWindows) window sessions are already active"
      )
      return true
    }

    guard
      !isBusy,
      let accessibleWindow = AccessibilityWindowService.window(at: screenPoint),
      TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: accessibleWindow.target.frame
      ) != nil
    else {
      return false
    }

    let sessionID = UUID()
    guard
      torchSessionRegistry.register(
        id: sessionID,
        captureFrame: accessibleWindow.target.frame
      )
    else {
      return true
    }
    torchSessions[sessionID] = TorchWindowSession(
      accessibleWindow: accessibleWindow,
      initialClick: screenPoint
    )

    Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        guard let session = torchSessions[sessionID] else { return }
        let capturedWindow = try await WindowCaptureService.capture(
          target: session.accessibleWindow.target
        )
        guard let session = torchSessions[sessionID] else { return }
        let panelFrame = ScreenCoordinateConverter.appKitFrame(
          for: capturedWindow.captureFrame,
          mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
          padding: BurnOverlayController.padding
        )
        let ignitionPoints = session.pendingClicks.compactMap {
          TorchBurnGeometry.normalizedIgnition(
            screenPoint: $0,
            captureFrame: capturedWindow.captureFrame
          )
        }
        guard !ignitionPoints.isEmpty else {
          throw WindowCaptureError.noMatchingWindow
        }

        session.captureFrame = capturedWindow.captureFrame
        guard
          torchSessionRegistry.updateCaptureFrame(
            id: sessionID,
            captureFrame: capturedWindow.captureFrame
          )
        else {
          throw WindowCaptureError.noMatchingWindow
        }
        let profile = BurnProfile.randomTorch()
        try session.overlay.present(
          image: capturedWindow.image,
          shadowImage: capturedWindow.shadowImage,
          shadowSamplingOffset: capturedWindow.shadowSamplingOffset,
          panelFrame: panelFrame,
          profile: profile,
          style: .torch(initialIgnitions: ignitionPoints),
          startImmediately: false,
          onFirstFrame: nil,
          completion: { [weak self] in
            self?.finishTorchBurn(sessionID)
          }
        )
        session.isOverlayReady = true
        session.pendingClicks = []
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(
          session.accessibleWindow
        )
        guard
          torchSessions[sessionID] != nil,
          session.overlay.activateReplacementSurface()
        else {
          throw BurnOverlayError.rendererUnavailable
        }
        session.overlay.startBurning()
        logger.info(
          "Started torch session \(sessionID.uuidString, privacy: .public) for pid \(session.accessibleWindow.target.ownerPID) with \(ignitionPoints.count) ignition point(s), duration \(profile.duration, format: .fixed(precision: 2))s; \(self.torchSessionRegistry.count) concurrent window(s)"
        )
      } catch {
        torchSessions[sessionID]?.overlay.dismiss()
        finishTorchBurn(sessionID)
        onDestructiveCloseFailure?()
        logger.error(
          "Torch session \(sessionID.uuidString, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        showError(error)
      }
    }

    return true
  }

  func interceptSoakAndBurn(
    _ event: SoakAndBurnPointerEvent,
    at screenPoint: CGPoint
  ) -> Bool {
    switch event {
    case .down:
      switch soakAndBurnSession.phase {
      case .readyToSoak:
        return beginSoaking(at: screenPoint)
      case .readyToBurn:
        return igniteSoakedWindow(at: screenPoint)
      case .soaking, .burning:
        return true
      }
    case .dragged:
      guard soakAndBurnSession.phase == .soaking else {
        return soakAndBurnSession.phase != .readyToSoak
      }
      extendSoaking(to: screenPoint)
      return true
    case .up:
      if soakAndBurnSession.phase == .soaking {
        let didFinish = soakAndBurnSession.finishSoaking()
        guard didFinish else { return false }
        pendingSoakRelease = !isSoakOverlayActive
        if isSoakOverlayActive {
          _ = overlay.finishSoaking()
        }
        notifySoakAndBurnPhaseChange()
        logger.info("The window is soaked and ready for the torch")
      }
      return soakAndBurnSession.phase != .readyToSoak
    }
  }

  func cancelSoakAndBurn() {
    guard soakAndBurnSession.phase != .readyToSoak else { return }
    resetSoakAndBurn()
    overlay.dismiss()
    logger.info("Soak-and-burn mode was cancelled")
  }

  func showDemo() {
    guard !isBusy, torchSessions.isEmpty else { return }
    isBusy = true
    logger.info("Starting demo burn")

    do {
      let size = CGSize(width: 720, height: 430)
      let image = try DemoImageFactory.make(size: size)
      let visibleFrame =
        NSScreen.main?.visibleFrame
        ?? CGRect(x: 0, y: 0, width: 1_200, height: 800)
      let contentFrame = CGRect(
        x: visibleFrame.midX - size.width / 2,
        y: visibleFrame.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
      let profile = BurnProfile.random()
      try overlay.present(
        image: image,
        panelFrame: contentFrame,
        profile: profile,
        presentation: .demoWindow,
        onFirstFrame: nil,
        completion: { [weak self] in
          self?.isBusy = false
          self?.logger.info("Demo burn completed")
        }
      )
    } catch {
      isBusy = false
      logger.error("Demo burn failed: \(error.localizedDescription, privacy: .public)")
      showError(error)
    }
  }

  func showSoakDemo() {
    guard !isBusy, torchSessions.isEmpty else { return }
    isBusy = true
    logger.info("Starting soak-and-burn demo")

    do {
      let size = CGSize(width: 720, height: 430)
      let image = try DemoImageFactory.make(size: size)
      let visibleFrame =
        NSScreen.main?.visibleFrame
        ?? CGRect(x: 0, y: 0, width: 1_200, height: 800)
      let contentFrame = CGRect(
        x: visibleFrame.midX - size.width / 2,
        y: visibleFrame.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
      let profile = BurnProfile(
        duration: 3.4,
        seed: 41,
        tilt: 0,
        turbulence: 1.15,
        charWidth: 0.075
      )
      let soakPoints = [
        BurnIgnitionPoint(x: 0.42, y: 0.40),
        BurnIgnitionPoint(x: 0.47, y: 0.44),
        BurnIgnitionPoint(x: 0.52, y: 0.41),
        BurnIgnitionPoint(x: 0.56, y: 0.46),
        BurnIgnitionPoint(x: 0.50, y: 0.50),
      ]
      try overlay.present(
        image: image,
        panelFrame: contentFrame,
        profile: profile,
        style: .soakAndBurn(initialSoakPoints: [soakPoints[0]]),
        presentation: .demoWindow,
        onFirstFrame: nil,
        completion: { [weak self] in
          self?.isBusy = false
          self?.logger.info("Soak-and-burn demo completed")
        }
      )

      Task { @MainActor [weak self] in
        for point in soakPoints.dropFirst() {
          try? await Task.sleep(for: .seconds(0.18))
          guard let self, self.isBusy else { return }
          _ = self.overlay.addSoakPoint(point)
        }

        try? await Task.sleep(for: .seconds(5.0))
        guard let self, self.isBusy else { return }
        _ = self.overlay.finishSoaking()
        self.logger.info("Soak demo reached full wetness")

        try? await Task.sleep(for: .seconds(2.4))
        guard self.isBusy else { return }
        _ = self.overlay.igniteSoakedWindow(
          at: BurnIgnitionPoint(x: 0.49, y: 0.24)
        )
        self.logger.info("Soak demo ignited")
      }
    } catch {
      isBusy = false
      logger.error("Soak demo failed: \(error.localizedDescription, privacy: .public)")
      showError(error)
    }
  }

  private func finishTorchBurn(_ sessionID: UUID) {
    guard torchSessions.removeValue(forKey: sessionID) != nil else { return }
    torchSessionRegistry.remove(id: sessionID)
    logger.info(
      "Torch session \(sessionID.uuidString, privacy: .public) completed; \(self.torchSessionRegistry.count) concurrent window(s) remain"
    )
  }

  private func beginSoaking(at screenPoint: CGPoint) -> Bool {
    guard
      !isBusy,
      torchSessions.isEmpty,
      let accessibleWindow = AccessibilityWindowService.window(at: screenPoint),
      TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: accessibleWindow.target.frame
      ) != nil,
      soakAndBurnSession.beginSoaking()
    else {
      return false
    }

    isBusy = true
    soakGeneration += 1
    let generation = soakGeneration
    soakedWindow = accessibleWindow
    soakCaptureFrame = accessibleWindow.target.frame
    pendingSoakTrail = SoakTrail()
    if let point = TorchBurnGeometry.normalizedIgnition(
      screenPoint: screenPoint,
      captureFrame: accessibleWindow.target.frame
    ) {
      _ = pendingSoakTrail.add(point)
    }
    isSoakOverlayActive = false
    pendingSoakRelease = false
    notifySoakAndBurnPhaseChange()
    onSoakCaptureStateChange?(true)

    Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        // Ordering a cursor panel out is asynchronous at the WindowServer boundary.
        // Give it several display frames before ScreenCaptureKit snapshots the target.
        try await Task.sleep(for: .milliseconds(80))
        guard generation == soakGeneration, soakAndBurnSession.phase != .readyToSoak else {
          return
        }
        let capturedWindow = try await WindowCaptureService.capture(
          target: accessibleWindow.target
        )
        guard generation == soakGeneration, soakAndBurnSession.phase != .readyToSoak else {
          return
        }
        let panelFrame = ScreenCoordinateConverter.appKitFrame(
          for: capturedWindow.captureFrame,
          mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
          padding: BurnOverlayController.padding
        )
        let initialSoakPoints = pendingSoakTrail.points
        guard !initialSoakPoints.isEmpty else {
          throw WindowCaptureError.noMatchingWindow
        }

        soakCaptureFrame = capturedWindow.captureFrame
        let profile = BurnProfile.randomTorch()
        try overlay.present(
          image: capturedWindow.image,
          backdropImage: capturedWindow.backdropImage,
          shadowImage: capturedWindow.shadowImage,
          shadowSamplingOffset: capturedWindow.shadowSamplingOffset,
          panelFrame: panelFrame,
          profile: profile,
          style: .soakAndBurn(initialSoakPoints: initialSoakPoints),
          onFirstFrame: nil,
          completion: { [weak self] in
            self?.finishSoakAndBurn()
          }
        )
        isSoakOverlayActive = true
        pendingSoakTrail = SoakTrail()
        onSoakCaptureStateChange?(false)
        if pendingSoakRelease || soakAndBurnSession.phase == .readyToBurn {
          pendingSoakRelease = false
          _ = overlay.finishSoaking()
        }
        logger.info(
          "Started soaking pid \(accessibleWindow.target.ownerPID) with \(initialSoakPoints.count) sampled point(s)"
        )
      } catch {
        resetSoakAndBurn()
        logger.error("Soaking failed: \(error.localizedDescription, privacy: .public)")
        showError(error)
      }
    }

    return true
  }

  private func igniteSoakedWindow(at screenPoint: CGPoint) -> Bool {
    if soakCloseTask != nil {
      return true
    }
    guard
      isSoakOverlayActive,
      let captureFrame = soakCaptureFrame,
      let accessibleWindow = soakedWindow,
      let ignition = TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: captureFrame
      )
    else {
      return false
    }

    let generation = soakGeneration
    soakCloseTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        guard overlay.prepareForIgnitionHandoff() else {
          overlay.dismiss()
          resetSoakAndBurn()
          return
        }
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(accessibleWindow)
        guard generation == soakGeneration, !Task.isCancelled else { return }
        soakCloseTask = nil
        guard
          overlay.activateReplacementSurface(),
          soakAndBurnSession.beginBurning(),
          overlay.igniteSoakedWindow(at: ignition)
        else {
          overlay.dismiss()
          resetSoakAndBurn()
          return
        }
        notifySoakAndBurnPhaseChange()
        logger.info(
          "Ignited the soaked window for pid \(accessibleWindow.target.ownerPID) at \(ignition.x, format: .fixed(precision: 2)), \(ignition.y, format: .fixed(precision: 2))"
        )
      } catch is CancellationError {
        return
      } catch {
        soakCloseTask = nil
        overlay.dismiss()
        resetSoakAndBurn()
        onDestructiveCloseFailure?()
        logger.error(
          "Could not destructively close the soaked window: \(error.localizedDescription, privacy: .public)"
        )
        DispatchQueue.main.async { [weak self] in
          self?.showError(error)
        }
      }
    }
    return true
  }

  private func extendSoaking(to screenPoint: CGPoint) {
    guard
      let captureFrame = soakCaptureFrame,
      let point = TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: captureFrame
      )
    else {
      return
    }

    if isSoakOverlayActive {
      _ = overlay.addSoakPoint(point)
    } else {
      _ = pendingSoakTrail.add(point)
    }
  }

  private func finishSoakAndBurn() {
    resetSoakAndBurn()
    logger.info("Soak-and-burn effect completed")
  }

  private func resetSoakAndBurn() {
    soakCloseTask?.cancel()
    soakCloseTask = nil
    onSoakCaptureStateChange?(false)
    soakGeneration += 1
    isBusy = false
    soakAndBurnSession.reset()
    soakedWindow = nil
    soakCaptureFrame = nil
    isSoakOverlayActive = false
    pendingSoakRelease = false
    pendingSoakTrail = SoakTrail()
    notifySoakAndBurnPhaseChange()
  }

  private func notifySoakAndBurnPhaseChange() {
    onSoakAndBurnPhaseChange?(soakAndBurnSession.phase)
  }

  func showError(_ error: Error) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Window Burn"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "OK")
    if !PermissionService.hasAccessibilityAccess || !PermissionService.hasScreenCaptureAccess
      || !PermissionService.hasInputMonitoringAccess
    {
      alert.addButton(withTitle: "Request Permissions")
    }

    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertSecondButtonReturn {
      PermissionService.requestMissingPermissions()
    }
  }
}
