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

extension WindowControlKind {
  public var logName: String {
    switch self {
    case .close: "close"
    }
  }
}
