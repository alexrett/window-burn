import Testing

@testable import WindowBurnCore

@Suite("Window control interception")
struct WindowControlIntentTests {
  @Test("Recognizes close and leaves minimize to macOS")
  func recognizesSupportedButtons() {
    #expect(
      WindowControlClassifier.classify(role: "AXButton", subrole: "AXCloseButton") == .close
    )
    #expect(
      WindowControlClassifier.classify(role: "AXButton", subrole: "AXMinimizeButton")
        == nil
    )
  }

  @Test("Passes through unrelated controls")
  func rejectsUnsupportedControls() {
    #expect(WindowControlClassifier.classify(role: "AXButton", subrole: nil) == nil)
    #expect(
      WindowControlClassifier.classify(role: "AXButton", subrole: "AXZoomButton") == nil
    )
    #expect(
      WindowControlClassifier.classify(role: "AXGroup", subrole: "AXCloseButton") == nil
    )
  }
}
