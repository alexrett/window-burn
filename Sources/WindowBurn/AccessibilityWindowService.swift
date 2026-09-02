import AppKit
import ApplicationServices
import WindowBurnCore

struct AccessibleWindow {
  let target: TargetWindow
  let element: AXUIElement
}

struct AccessibleWindowControl {
  let window: AccessibleWindow
  let kind: WindowControlKind
  let button: AXUIElement
}

enum AccessibilityWindowError: LocalizedError {
  case permissionMissing
  case noFrontmostApplication
  case ownApplicationIsFrontmost
  case noFocusedWindow
  case unreadableFrame
  case notClosable
  case unsupportedCloseConfirmation
  case destructiveCloseTimedOut
  case actionFailed(WindowControlKind, AXError)

  var errorDescription: String? {
    switch self {
    case .permissionMissing:
      "Accessibility permission is missing. Grant it in System Settings and retry."
    case .noFrontmostApplication:
      "No frontmost application was found."
    case .ownApplicationIsFrontmost:
      "Choose another app window before triggering Window Burn."
    case .noFocusedWindow:
      "The frontmost app does not expose a focused window."
    case .unreadableFrame:
      "The focused window did not expose a usable frame."
    case .notClosable:
      "The focused window does not expose a close button."
    case .unsupportedCloseConfirmation:
      "The close confirmation is not a standard Save / Cancel / Don't Save dialog, so Window Burn refused to guess."
    case .destructiveCloseTimedOut:
      "The window remained open after Window Burn requested closing without saving."
    case .actionFailed(let kind, let error):
      "The window refused the Accessibility \(kind.logName) action (\(error.rawValue))."
    }
  }
}

enum AccessibilityWindowService {
  @MainActor
  static func focusedWindow() throws -> AccessibleWindow {
    guard PermissionService.hasAccessibilityAccess else {
      throw AccessibilityWindowError.permissionMissing
    }
    guard let application = NSWorkspace.shared.frontmostApplication else {
      throw AccessibilityWindowError.noFrontmostApplication
    }
    guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
      throw AccessibilityWindowError.ownApplicationIsFrontmost
    }

    let appElement = AXUIElementCreateApplication(application.processIdentifier)
    guard let windowValue = copyAttribute(kAXFocusedWindowAttribute, from: appElement) else {
      throw AccessibilityWindowError.noFocusedWindow
    }
    let window = unsafeDowncast(windowValue, to: AXUIElement.self)

    guard
      let position = pointAttribute(kAXPositionAttribute, from: window),
      let size = sizeAttribute(kAXSizeAttribute, from: window),
      size.width > 1,
      size.height > 1
    else {
      throw AccessibilityWindowError.unreadableFrame
    }

    return makeAccessibleWindow(
      element: window,
      ownerPID: application.processIdentifier,
      position: position,
      size: size
    )
  }

  static func close(_ window: AccessibleWindow) throws {
    guard let closeValue = copyAttribute(kAXCloseButtonAttribute, from: window.element) else {
      throw AccessibilityWindowError.notClosable
    }
    let closeButton = unsafeDowncast(closeValue, to: AXUIElement.self)
    try perform(kind: .close, button: closeButton)
  }

  @MainActor
  static func closeDiscardingUnsavedChanges(
    _ window: AccessibleWindow
  ) async throws {
    try close(window)
    try await finishClosingDiscardingUnsavedChanges(window)
  }

  @MainActor
  static func finishClosingDiscardingUnsavedChanges(
    _ window: AccessibleWindow
  ) async throws {
    var didRequestDiscard = false
    var sawUnsupportedSheet = false

    for _ in 0..<24 {
      try await Task.sleep(for: .milliseconds(50))
      let sheets = sheets(in: window)
      let result = WindowCloseConfirmation.evaluate(
        isWindowPresent: isWindowPresent(window),
        hasSheet: !sheets.isEmpty
      )

      switch result {
      case .closed:
        return
      case .pending:
        continue
      case .discardRequired:
        guard !didRequestDiscard else { continue }
        guard
          let sheet = sheets.first,
          let discardButton = discardButton(in: sheet)
        else {
          sawUnsupportedSheet = true
          continue
        }
        try perform(kind: .close, button: discardButton)
        didRequestDiscard = true
      }
    }

    if sawUnsupportedSheet, !didRequestDiscard {
      throw AccessibilityWindowError.unsupportedCloseConfirmation
    }
    throw AccessibilityWindowError.destructiveCloseTimedOut
  }

  static func windowControl(at point: CGPoint) -> AccessibleWindowControl? {
    guard
      let hitElement = hitElement(at: point),
      let role = copyAttribute(kAXRoleAttribute, from: hitElement) as? String,
      let kind = WindowControlClassifier.classify(
        role: role,
        subrole: copyAttribute(kAXSubroleAttribute, from: hitElement) as? String
      ),
      (copyAttribute(kAXEnabledAttribute, from: hitElement) as? Bool) != false,
      let window = accessibleWindow(containing: hitElement)
    else {
      return nil
    }
    let closeButtonValue = copyAttribute(kAXCloseButtonAttribute, from: window.element)
    guard
      WindowControlInterceptionPolicy.shouldIntercept(
        kind: kind,
        windowExposesCloseButton: closeButtonValue != nil
      ),
      let closeButtonValue
    else {
      return nil
    }
    let closeButton = unsafeDowncast(closeButtonValue, to: AXUIElement.self)

    return AccessibleWindowControl(
      window: window,
      kind: kind,
      button: closeButton
    )
  }

  static func window(at point: CGPoint) -> AccessibleWindow? {
    if let hitElement = hitElement(at: point),
      let window = accessibleWindow(containing: hitElement)
    {
      return window
    }

    guard let target = WindowServerWindowService.targetWindow(at: point) else { return nil }
    return window(matching: target)
  }

  static func perform(_ control: AccessibleWindowControl) throws {
    try perform(kind: control.kind, button: control.button)
  }

  private static func perform(kind: WindowControlKind, button: AXUIElement) throws {
    let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard result == .success else {
      throw AccessibilityWindowError.actionFailed(kind, result)
    }
  }

  private static func isWindowPresent(_ window: AccessibleWindow) -> Bool {
    let application = AXUIElementCreateApplication(window.target.ownerPID)
    guard
      let windows = copyAttribute(kAXWindowsAttribute, from: application) as? [AXUIElement]
    else {
      return copyAttribute(kAXRoleAttribute, from: window.element) != nil
    }
    return windows.contains { CFEqual($0, window.element) }
  }

  private static func sheets(in window: AccessibleWindow) -> [AXUIElement] {
    descendants(withRole: kAXSheetRole as String, in: window.element)
  }

  private static func discardButton(in sheet: AXUIElement) -> AXUIElement? {
    let buttonEntries = enabledButtons(in: sheet).compactMap {
      button -> (element: AXUIElement, frame: CGRect)? in
      guard
        let position = pointAttribute(kAXPositionAttribute, from: button),
        let size = sizeAttribute(kAXSizeAttribute, from: button)
      else {
        return nil
      }
      return (button, CGRect(origin: position, size: size))
    }
    let buttons = buttonEntries.map(\.element)
    let buttonFrames = buttonEntries.map(\.frame)
    let defaultIndex: Int?
    if let defaultValue = copyAttribute(kAXDefaultButtonAttribute, from: sheet) {
      let defaultButton = unsafeDowncast(defaultValue, to: AXUIElement.self)
      defaultIndex = buttons.firstIndex(where: { CFEqual($0, defaultButton) })
    } else {
      defaultIndex = nil
    }
    let cancelIndex: Int?
    if let cancelValue = copyAttribute(kAXCancelButtonAttribute, from: sheet) {
      let cancelButton = unsafeDowncast(cancelValue, to: AXUIElement.self)
      cancelIndex = buttons.firstIndex(where: { CFEqual($0, cancelButton) })
    } else {
      cancelIndex = nil
    }
    guard
      let discardIndex = WindowCloseConfirmation.discardButtonIndex(
        buttonFrames: buttonFrames,
        defaultButtonIndex: defaultIndex,
        cancelButtonIndex: cancelIndex
      )
    else {
      return nil
    }
    return buttons[discardIndex]
  }

  private static func descendants(
    withRole requestedRole: String,
    in element: AXUIElement,
    depth: Int = 0
  ) -> [AXUIElement] {
    guard depth < 6 else { return [] }
    let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] ?? []
    return children.flatMap { child in
      let role = copyAttribute(kAXRoleAttribute, from: child) as? String
      if role == requestedRole {
        return [child]
      }
      return descendants(withRole: requestedRole, in: child, depth: depth + 1)
    }
  }

  private static func enabledButtons(in element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 6 else { return [] }
    let children = copyAttribute(kAXChildrenAttribute, from: element) as? [AXUIElement] ?? []
    return children.flatMap { child in
      let role = copyAttribute(kAXRoleAttribute, from: child) as? String
      if role == (kAXButtonRole as String),
        (copyAttribute(kAXEnabledAttribute, from: child) as? Bool) != false
      {
        return [child]
      }
      return enabledButtons(in: child, depth: depth + 1)
    }
  }

  private static func makeAccessibleWindow(
    element: AXUIElement,
    ownerPID: pid_t,
    position: CGPoint,
    size: CGSize
  ) -> AccessibleWindow {
    AccessibleWindow(
      target: TargetWindow(
        ownerPID: ownerPID,
        title: copyAttribute(kAXTitleAttribute, from: element) as? String,
        frame: CGRect(origin: position, size: size)
      ),
      element: element
    )
  }

  private static func hitElement(at point: CGPoint) -> AXUIElement? {
    guard PermissionService.hasAccessibilityAccess else { return nil }

    let systemWideElement = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(
      systemWideElement,
      Float(point.x),
      Float(point.y),
      &element
    )
    return result == .success ? element : nil
  }

  private static func accessibleWindow(containing element: AXUIElement) -> AccessibleWindow? {
    let role = copyAttribute(kAXRoleAttribute, from: element) as? String
    let windowElement: AXUIElement
    if role == (kAXWindowRole as String) {
      windowElement = element
    } else {
      guard let windowValue = copyAttribute(kAXWindowAttribute, from: element) else {
        return nil
      }
      windowElement = unsafeDowncast(windowValue, to: AXUIElement.self)
    }

    var ownerPID: pid_t = 0
    guard
      AXUIElementGetPid(windowElement, &ownerPID) == .success,
      ownerPID != ProcessInfo.processInfo.processIdentifier,
      let position = pointAttribute(kAXPositionAttribute, from: windowElement),
      let size = sizeAttribute(kAXSizeAttribute, from: windowElement),
      size.width > 1,
      size.height > 1
    else {
      return nil
    }

    return makeAccessibleWindow(
      element: windowElement,
      ownerPID: ownerPID,
      position: position,
      size: size
    )
  }

  private static func window(matching target: TargetWindow) -> AccessibleWindow? {
    let application = AXUIElementCreateApplication(target.ownerPID)
    guard
      let windowValues = copyAttribute(kAXWindowsAttribute, from: application)
        as? [AXUIElement]
    else {
      return nil
    }

    let windows = windowValues.compactMap { element -> AccessibleWindow? in
      guard
        let position = pointAttribute(kAXPositionAttribute, from: element),
        let size = sizeAttribute(kAXSizeAttribute, from: element),
        size.width > 1,
        size.height > 1
      else {
        return nil
      }
      return makeAccessibleWindow(
        element: element,
        ownerPID: target.ownerPID,
        position: position,
        size: size
      )
    }
    let candidates = windows.enumerated().map { index, window in
      WindowCandidate(
        id: UInt32(index),
        ownerPID: window.target.ownerPID,
        title: window.target.title,
        frame: window.target.frame,
        isOnScreen: true
      )
    }
    guard
      let match = WindowMatcher.bestMatch(for: target, among: candidates),
      windows.indices.contains(Int(match.id))
    else {
      return nil
    }
    return windows[Int(match.id)]
  }

  private static func copyAttribute(
    _ attribute: String,
    from element: AXUIElement
  ) -> CFTypeRef? {
    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    return result == .success ? value : nil
  }

  private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
    guard let value = copyAttribute(attribute, from: element) else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgPoint else { return nil }

    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
  }

  private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
    guard let value = copyAttribute(attribute, from: element) else { return nil }
    let axValue = unsafeDowncast(value, to: AXValue.self)
    guard AXValueGetType(axValue) == .cgSize else { return nil }

    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
  }
}
