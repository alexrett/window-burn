import CoreGraphics
import Foundation
import OSLog
import WindowBurnCore

enum WindowServerWindowService {
  private static let logger = Logger(subsystem: "dev.malikov.WindowBurn", category: "resolver")

  static func targetWindow(at point: CGPoint) -> TargetWindow? {
    guard
      let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID
      ) as? [[String: Any]]
    else {
      return nil
    }

    let candidates = windowInfo.compactMap { info -> PointWindowCandidate? in
      guard
        let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary
      else {
        return nil
      }

      var frame = CGRect.zero
      guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) else {
        return nil
      }

      return PointWindowCandidate(
        id: id,
        ownerPID: ownerPID,
        title: info[kCGWindowName as String] as? String,
        frame: frame,
        layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
        isOnScreen: (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? true,
        alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
      )
    }

    guard
      let match = WindowAtPointMatcher.frontmost(
        at: point,
        amongFrontToBack: candidates,
        excludingPID: ProcessInfo.processInfo.processIdentifier
      )
    else {
      return nil
    }

    logger.info(
      "Resolved WindowServer fallback at click point to pid \(match.ownerPID), window \(match.id)"
    )
    return TargetWindow(ownerPID: match.ownerPID, title: match.title, frame: match.frame)
  }
}
