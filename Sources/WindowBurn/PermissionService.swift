import ApplicationServices
import CoreGraphics

enum PermissionService {
  static var hasAccessibilityAccess: Bool {
    AXIsProcessTrusted()
  }

  static var hasScreenCaptureAccess: Bool {
    CGPreflightScreenCaptureAccess()
  }

  static var hasInputMonitoringAccess: Bool {
    CGPreflightListenEventAccess()
  }

  static func requestMissingPermissions() {
    if !hasAccessibilityAccess {
      AXIsProcessTrustedWithOptions(
        ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      )
    }

    if !hasScreenCaptureAccess {
      CGRequestScreenCaptureAccess()
    }

    if !hasInputMonitoringAccess {
      CGRequestListenEventAccess()
    }
  }
}
