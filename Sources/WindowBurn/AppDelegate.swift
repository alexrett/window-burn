import AppKit
import Carbon.HIToolbox
import OSLog
import WindowBurnCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "app")
  private let coordinator = BurnCoordinator()
  private let torchCursor = TorchCursorController()
  private var burnHotKey: GlobalHotKey?
  private var torchHotKey: GlobalHotKey?
  private var soakAndBurnHotKey: GlobalHotKey?
  private var windowControlInterceptor: WindowControlInterceptor?
  private var statusItem: NSStatusItem?
  private var torchMenuItem: NSMenuItem?
  private var soakAndBurnMenuItem: NSMenuItem?
  private var isTorchModeEnabled = false
  private var isSoakAndBurnModeEnabled = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    installStatusItem()
    installHotKeys()
    coordinator.onSoakAndBurnPhaseChange = { [weak self] phase in
      self?.updateSoakAndBurnCursor(for: phase)
    }
    coordinator.onSoakCaptureStateChange = { [weak self] isCapturing in
      self?.torchCursor.setTemporarilyHidden(isCapturing)
    }
    coordinator.onDestructiveCloseFailure = { [weak self] in
      self?.disableInteractiveModesAfterCloseFailure()
    }
    let isDemoLaunch = CommandLine.arguments.contains("--demo")
    let isTorchLaunch = CommandLine.arguments.contains("--torch")
    let isSoakAndBurnLaunch = CommandLine.arguments.contains("--soak-and-burn")
    if !isDemoLaunch {
      PermissionService.requestMissingPermissions()
      installWindowControlInterceptor()
    }
    logger.info(
      "Window Burn is ready; accessibility=\(PermissionService.hasAccessibilityAccess), screenCapture=\(PermissionService.hasScreenCaptureAccess), inputMonitoring=\(PermissionService.hasInputMonitoringAccess)"
    )
    if isDemoLaunch {
      DispatchQueue.main.async { [weak self] in
        self?.coordinator.showDemo()
      }
    } else if isTorchLaunch {
      DispatchQueue.main.async { [weak self] in
        self?.enableTorchMode()
      }
    } else if isSoakAndBurnLaunch {
      DispatchQueue.main.async { [weak self] in
        self?.setSoakAndBurnModeEnabled(true)
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    torchCursor.setEnabled(false)
    burnHotKey = nil
    torchHotKey = nil
    soakAndBurnHotKey = nil
    windowControlInterceptor?.stop()
    windowControlInterceptor = nil
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "flame.fill",
      accessibilityDescription: "Window Burn"
    )
    item.button?.toolTip = "Window Burn — burn ⌃⌥⌘B, torch ⌃⌥⌘F, soak & burn ⌃⌥⌘U"

    let menu = NSMenu()
    let burnItem = NSMenuItem(
      title: "Burn & Close Front Window",
      action: #selector(burnFrontWindow),
      keyEquivalent: ""
    )
    burnItem.target = self
    burnItem.image = NSImage(systemSymbolName: "flame", accessibilityDescription: nil)
    menu.addItem(burnItem)

    let torchItem = NSMenuItem(
      title: "Enable Torch Mode",
      action: #selector(toggleTorchMode),
      keyEquivalent: ""
    )
    torchItem.target = self
    torchItem.image = NSImage(systemSymbolName: "flame.circle", accessibilityDescription: nil)
    menu.addItem(torchItem)
    torchMenuItem = torchItem

    let soakAndBurnItem = NSMenuItem(
      title: "Enable Soak & Burn Mode",
      action: #selector(toggleSoakAndBurnMode),
      keyEquivalent: ""
    )
    soakAndBurnItem.target = self
    soakAndBurnItem.image = NSImage(
      systemSymbolName: "drop.triangle",
      accessibilityDescription: nil
    )
    menu.addItem(soakAndBurnItem)
    soakAndBurnMenuItem = soakAndBurnItem

    let demoItem = NSMenuItem(
      title: "Test Effect",
      action: #selector(showDemo),
      keyEquivalent: ""
    )
    demoItem.target = self
    demoItem.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    menu.addItem(demoItem)

    menu.addItem(.separator())
    let permissionsItem = NSMenuItem(
      title: "Request Permissions…",
      action: #selector(requestPermissions),
      keyEquivalent: ""
    )
    permissionsItem.target = self
    permissionsItem.image = NSImage(systemSymbolName: "lock.open", accessibilityDescription: nil)
    menu.addItem(permissionsItem)

    menu.addItem(.separator())
    let shortcutItem = NSMenuItem(title: "Hotkey: ⌃⌥⌘B", action: nil, keyEquivalent: "")
    shortcutItem.isEnabled = false
    menu.addItem(shortcutItem)

    let torchShortcutItem = NSMenuItem(title: "Torch: ⌃⌥⌘F", action: nil, keyEquivalent: "")
    torchShortcutItem.isEnabled = false
    menu.addItem(torchShortcutItem)

    let soakShortcutItem = NSMenuItem(title: "Soak & Burn: ⌃⌥⌘U", action: nil, keyEquivalent: "")
    soakShortcutItem.isEnabled = false
    menu.addItem(soakShortcutItem)

    let quitItem = NSMenuItem(
      title: "Quit Window Burn",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    menu.addItem(quitItem)

    item.menu = menu
    statusItem = item
  }

  private func installHotKeys() {
    do {
      burnHotKey = try GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_B),
        identifierID: 1,
        shortcut: "⌃⌥⌘B"
      ) { [weak self] in
        self?.coordinator.burnFrontWindow()
      }
      torchHotKey = try GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_F),
        identifierID: 2,
        shortcut: "⌃⌥⌘F"
      ) { [weak self] in
        self?.toggleTorchMode()
      }
      soakAndBurnHotKey = try GlobalHotKey(
        keyCode: UInt32(kVK_ANSI_U),
        identifierID: 3,
        shortcut: "⌃⌥⌘U"
      ) { [weak self] in
        self?.toggleSoakAndBurnMode()
      }
    } catch {
      logger.error(
        "Global hotkey registration failed: \(error.localizedDescription, privacy: .public)")
      coordinator.showError(error)
    }
  }

  private func installWindowControlInterceptor() {
    do {
      windowControlInterceptor = try WindowControlInterceptor(
        closeHandler: { [weak self] control in
          self?.coordinator.interceptWindowControl(control) ?? false
        },
        torchHandler: { [weak self] location in
          guard let self else { return false }
          return torchCursor.withoutOverlay {
            coordinator.interceptTorchClick(at: location)
          }
        },
        soakAndBurnHandler: { [weak self] event, location in
          guard let self else { return false }
          switch event {
          case .down:
            torchCursor.beginPointerDrag(atQuartzPoint: location)
          case .dragged:
            torchCursor.move(toQuartzPoint: location)
          case .up:
            torchCursor.endPointerDrag(atQuartzPoint: location)
          }
          if case .down = event {
            return torchCursor.withoutOverlay {
              coordinator.interceptSoakAndBurn(event, at: location)
            }
          }
          return coordinator.interceptSoakAndBurn(event, at: location)
        }
      )
    } catch {
      logger.error(
        "Mouse interception is unavailable: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  @objc private func burnFrontWindow() {
    coordinator.burnFrontWindow()
  }

  @objc private func showDemo() {
    coordinator.showDemo()
  }

  @objc private func toggleTorchMode() {
    setTorchModeEnabled(TorchModeTransition.toggled(from: isTorchModeEnabled))
  }

  private func enableTorchMode() {
    setTorchModeEnabled(true)
  }

  private func setTorchModeEnabled(_ enabled: Bool) {
    guard windowControlInterceptor != nil else {
      coordinator.showError(WindowControlInterceptorError.eventTapUnavailable)
      return
    }
    guard enabled != isTorchModeEnabled else { return }

    if enabled, isSoakAndBurnModeEnabled {
      setSoakAndBurnModeEnabled(false)
    }

    isTorchModeEnabled = enabled
    windowControlInterceptor?.isTorchModeEnabled = isTorchModeEnabled
    torchCursor.setStyle(isTorchModeEnabled ? .torch : nil)
    torchMenuItem?.title = isTorchModeEnabled ? "Disable Torch Mode" : "Enable Torch Mode"
    torchMenuItem?.state = isTorchModeEnabled ? .on : .off
    statusItem?.button?.image = NSImage(
      systemSymbolName: isTorchModeEnabled ? "flame.circle.fill" : "flame.fill",
      accessibilityDescription: "Window Burn"
    )
    logger.info("Torch mode \(self.isTorchModeEnabled ? "enabled" : "disabled", privacy: .public)")
  }

  @objc private func toggleSoakAndBurnMode() {
    setSoakAndBurnModeEnabled(!isSoakAndBurnModeEnabled)
  }

  private func setSoakAndBurnModeEnabled(_ enabled: Bool) {
    guard windowControlInterceptor != nil else {
      coordinator.showError(WindowControlInterceptorError.eventTapUnavailable)
      return
    }
    guard enabled != isSoakAndBurnModeEnabled else { return }

    if enabled, isTorchModeEnabled {
      setTorchModeEnabled(false)
    }

    isSoakAndBurnModeEnabled = enabled
    windowControlInterceptor?.isSoakAndBurnModeEnabled = enabled
    if enabled {
      updateSoakAndBurnCursor(for: .readyToSoak)
    } else {
      coordinator.cancelSoakAndBurn()
      torchCursor.setStyle(nil)
    }
    soakAndBurnMenuItem?.title =
      enabled ? "Disable Soak & Burn Mode" : "Enable Soak & Burn Mode"
    soakAndBurnMenuItem?.state = enabled ? .on : .off
    statusItem?.button?.image = NSImage(
      systemSymbolName: enabled ? "drop.triangle.fill" : "flame.fill",
      accessibilityDescription: "Window Burn"
    )
    logger.info("Soak-and-burn mode \(enabled ? "enabled" : "disabled", privacy: .public)")
  }

  private func updateSoakAndBurnCursor(for phase: SoakAndBurnPhase) {
    guard isSoakAndBurnModeEnabled else { return }
    guard SoakAndBurnModePolicy.shouldRemainEnabled(after: phase) else {
      deactivateSoakAndBurnModePreservingEffect()
      return
    }
    switch phase {
    case .readyToSoak:
      torchCursor.setStyle(.dog(isSoaking: false))
    case .soaking:
      torchCursor.setStyle(.dog(isSoaking: true))
    case .readyToBurn:
      torchCursor.setStyle(.torch)
    case .burning:
      break
    }
  }

  private func deactivateSoakAndBurnModePreservingEffect() {
    isSoakAndBurnModeEnabled = false
    windowControlInterceptor?.isSoakAndBurnModeEnabled = false
    torchCursor.setStyle(nil)
    soakAndBurnMenuItem?.title = "Enable Soak & Burn Mode"
    soakAndBurnMenuItem?.state = .off
    statusItem?.button?.image = NSImage(
      systemSymbolName: "flame.fill",
      accessibilityDescription: "Window Burn"
    )
    logger.info("Soak-and-burn mode disabled automatically after ignition")
  }

  private func disableInteractiveModesAfterCloseFailure() {
    if isTorchModeEnabled {
      setTorchModeEnabled(false)
    }
    if isSoakAndBurnModeEnabled {
      setSoakAndBurnModeEnabled(false)
    }
  }

  @objc private func requestPermissions() {
    PermissionService.requestMissingPermissions()
  }
}
