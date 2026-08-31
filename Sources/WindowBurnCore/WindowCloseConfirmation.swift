import CoreGraphics

public enum WindowCloseConfirmationResult: Equatable, Sendable {
  case pending
  case closed
  case discardRequired
}

public enum WindowCloseConfirmation {
  public static func evaluate(
    isWindowPresent: Bool,
    hasSheet: Bool
  ) -> WindowCloseConfirmationResult {
    if hasSheet { return .discardRequired }
    if !isWindowPresent { return .closed }
    return .pending
  }

  /// A standard document close alert has exactly three actions: the default
  /// save action, the cancel action, and one destructive alternative. Selecting
  /// structurally keeps this independent from the current UI language.
  public static func discardButtonIndex(
    buttonFrames: [CGRect],
    defaultButtonIndex: Int?,
    cancelButtonIndex: Int?
  ) -> Int? {
    if let defaultButtonIndex,
      let cancelButtonIndex,
      defaultButtonIndex != cancelButtonIndex,
      buttonFrames.indices.contains(defaultButtonIndex),
      buttonFrames.indices.contains(cancelButtonIndex)
    {
      let defaultFrame = buttonFrames[defaultButtonIndex]
      let cancelFrame = buttonFrames[cancelButtonIndex]
      let actionHeight = min(defaultFrame.height, cancelFrame.height)
      let baselineTolerance = max(6, actionHeight * 0.45)
      if actionHeight > 0,
        abs(defaultFrame.midY - cancelFrame.midY) <= baselineTolerance
      {
        let actionBaseline = (defaultFrame.midY + cancelFrame.midY) / 2
        let candidates = buttonFrames.indices.filter { index in
          guard index != defaultButtonIndex, index != cancelButtonIndex else { return false }
          return isActionButton(
            buttonFrames[index],
            baseline: actionBaseline,
            height: actionHeight
          )
        }
        if candidates.count == 1 {
          return candidates[0]
        }
      }
    }

    guard
      let bottomIndex = buttonFrames.indices.max(by: {
        buttonFrames[$0].midY < buttonFrames[$1].midY
      })
    else {
      return nil
    }
    let bottomFrame = buttonFrames[bottomIndex]
    let bottomRow = buttonFrames.indices.filter {
      isActionButton(
        buttonFrames[$0],
        baseline: bottomFrame.midY,
        height: bottomFrame.height
      )
    }
    guard bottomRow.count == 3 else { return nil }
    return bottomRow.min(by: { buttonFrames[$0].minX < buttonFrames[$1].minX })
  }

  private static func isActionButton(
    _ frame: CGRect,
    baseline: CGFloat,
    height: CGFloat
  ) -> Bool {
    guard height > 0 else { return false }
    let baselineTolerance = max(6, height * 0.45)
    return abs(frame.midY - baseline) <= baselineTolerance
      && frame.height >= height * 0.7
      && frame.height <= height * 1.3
  }
}
