import AppKit
import OSLog
import WindowBurnCore

@MainActor
final class BurnCoordinator {
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "burn")
  private let overlay = BurnOverlayController()
  private var isBusy = false
  private var torchCaptureFrame: CGRect?
  private var pendingTorchClicks: [CGPoint] = []
  private var isTorchOverlayActive = false
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
    guard !isBusy else { return }
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

        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(accessibleWindow)
        try overlay.present(
          image: capturedWindow.image,
          panelFrame: panelFrame,
          profile: profile,
          onFirstFrame: nil,
          completion: { [weak self] in self?.isBusy = false }
        )
        logger.info(
          "Burning front window owned by pid \(accessibleWindow.target.ownerPID), duration \(profile.duration, format: .fixed(precision: 2))s"
        )
      } catch {
        isBusy = false
        onDestructiveCloseFailure?()
        logger.error("Burn failed: \(error.localizedDescription, privacy: .public)")
        showError(error)
      }
    }
  }

  func interceptWindowControl(_ control: AccessibleWindowControl) -> Bool {
    guard !isBusy else { return false }
    isBusy = true

    Task { @MainActor [weak self] in
      guard let self else { return }
      var actionPerformed = false

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

        actionPerformed = true
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(control.window)
        try overlay.present(
          image: capturedWindow.image,
          panelFrame: panelFrame,
          profile: profile,
          onFirstFrame: nil,
          completion: { [weak self] in self?.isBusy = false }
        )
        logger.info(
          "Burning intercepted \(control.kind.logName, privacy: .public) action for pid \(control.window.target.ownerPID), duration \(profile.duration, format: .fixed(precision: 2))s"
        )
      } catch {
        if !actionPerformed {
          do {
            try AccessibilityWindowService.perform(control)
          } catch {
            logger.error(
              "Fallback \(control.kind.logName, privacy: .public) action failed: \(error.localizedDescription, privacy: .public)"
            )
          }
        }
        isBusy = false
        onDestructiveCloseFailure?()
        logger.error(
          "Intercepted \(control.kind.logName, privacy: .public) burn failed: \(error.localizedDescription, privacy: .public)"
        )
        showError(error)
      }
    }

    return true
  }

  func interceptTorchClick(at screenPoint: CGPoint) -> Bool {
    if let captureFrame = torchCaptureFrame,
      let ignition = TorchBurnGeometry.normalizedIgnition(
        screenPoint: screenPoint,
        captureFrame: captureFrame
      )
    {
      if isTorchOverlayActive {
        let added = overlay.addIgnition(ignition)
        if added {
          logger.info(
            "Added another torch ignition at \(ignition.x, format: .fixed(precision: 2)), \(ignition.y, format: .fixed(precision: 2))"
          )
        } else {
          logger.info(
            "Ignored torch ignition because the active window already has the maximum number of points"
          )
        }
      } else if pendingTorchClicks.count < TorchIgnitionField.maximumCount {
        pendingTorchClicks.append(screenPoint)
      }
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

    isBusy = true
    torchCaptureFrame = accessibleWindow.target.frame
    pendingTorchClicks = [screenPoint]
    isTorchOverlayActive = false

    Task { @MainActor [weak self] in
      guard let self else { return }

      do {
        let capturedWindow = try await WindowCaptureService.capture(
          target: accessibleWindow.target
        )
        let panelFrame = ScreenCoordinateConverter.appKitFrame(
          for: capturedWindow.captureFrame,
          mainDisplayHeight: NSScreen.screens.first?.frame.maxY ?? 0,
          padding: BurnOverlayController.padding
        )
        let ignitionPoints = pendingTorchClicks.compactMap {
          TorchBurnGeometry.normalizedIgnition(
            screenPoint: $0,
            captureFrame: capturedWindow.captureFrame
          )
        }
        guard !ignitionPoints.isEmpty else {
          throw WindowCaptureError.noMatchingWindow
        }

        torchCaptureFrame = capturedWindow.captureFrame
        let profile = BurnProfile.randomTorch()
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(accessibleWindow)
        try overlay.present(
          image: capturedWindow.image,
          panelFrame: panelFrame,
          profile: profile,
          style: .torch(initialIgnitions: ignitionPoints),
          onFirstFrame: nil,
          completion: { [weak self] in
            self?.finishTorchBurn()
          }
        )
        isTorchOverlayActive = true
        logger.info(
          "Started torch burn for pid \(accessibleWindow.target.ownerPID) with \(ignitionPoints.count) ignition point(s), duration \(profile.duration, format: .fixed(precision: 2))s"
        )
      } catch {
        finishTorchBurn()
        onDestructiveCloseFailure?()
        logger.error("Torch burn failed: \(error.localizedDescription, privacy: .public)")
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
    overlay.dismiss()
    resetSoakAndBurn()
    logger.info("Soak-and-burn mode was cancelled")
  }

  func showDemo() {
    guard !isBusy else { return }
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
      let panelFrame = contentFrame.insetBy(
        dx: -BurnOverlayController.padding,
        dy: -BurnOverlayController.padding
      )
      let profile = BurnProfile.random()
      try overlay.present(
        image: image,
        panelFrame: panelFrame,
        profile: profile,
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

  private func finishTorchBurn() {
    isBusy = false
    torchCaptureFrame = nil
    pendingTorchClicks = []
    isTorchOverlayActive = false
    logger.info("Torch burn completed")
  }

  private func beginSoaking(at screenPoint: CGPoint) -> Bool {
    guard
      !isBusy,
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
        guard !pendingSoakTrail.points.isEmpty else {
          throw WindowCaptureError.noMatchingWindow
        }

        soakCaptureFrame = capturedWindow.captureFrame
        let profile = BurnProfile.randomTorch()
        try overlay.present(
          image: capturedWindow.image,
          panelFrame: panelFrame,
          profile: profile,
          style: .soakAndBurn(initialSoakPoints: pendingSoakTrail.points),
          onFirstFrame: nil,
          completion: { [weak self] in
            self?.finishSoakAndBurn()
          }
        )
        isSoakOverlayActive = true
        onSoakCaptureStateChange?(false)
        if pendingSoakRelease || soakAndBurnSession.phase == .readyToBurn {
          pendingSoakRelease = false
          _ = overlay.finishSoaking()
        }
        logger.info(
          "Started soaking pid \(accessibleWindow.target.ownerPID) with \(self.pendingSoakTrail.points.count) sampled point(s)"
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
        try await AccessibilityWindowService.closeDiscardingUnsavedChanges(accessibleWindow)
        guard generation == soakGeneration, !Task.isCancelled else { return }
        soakCloseTask = nil
        guard
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
