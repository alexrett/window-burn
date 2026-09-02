public enum WindowControlKind: Equatable, Sendable {
  case close
}

public enum WindowControlClassifier {
  public static func classify(role: String?, subrole: String?) -> WindowControlKind? {
    guard role == "AXButton" else { return nil }

    switch subrole {
    case "AXCloseButton":
      return .close
    default:
      return nil
    }
  }
}

public enum WindowControlInterceptionRecovery: Equatable, Sendable {
  case replayNativeActionSilently
  case leaveNativeCloseFlowInPlaceSilently
}

public enum WindowControlInterceptionPolicy {
  public static func shouldIntercept(
    kind: WindowControlKind,
    windowExposesCloseButton: Bool
  ) -> Bool {
    switch kind {
    case .close:
      windowExposesCloseButton
    }
  }

  public static func recovery(didRequestClose: Bool) -> WindowControlInterceptionRecovery {
    didRequestClose
      ? .leaveNativeCloseFlowInPlaceSilently
      : .replayNativeActionSilently
  }
}

extension WindowControlKind {
  public var logName: String {
    switch self {
    case .close: "close"
    }
  }
}
