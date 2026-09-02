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

  @Test("Leaves close buttons without a window-level close action to macOS")
  func requiresSupportedWindowCloseAction() {
    #expect(
      WindowControlInterceptionPolicy.shouldIntercept(
        kind: .close,
        windowExposesCloseButton: true
      )
    )
    #expect(
      !WindowControlInterceptionPolicy.shouldIntercept(
        kind: .close,
        windowExposesCloseButton: false
      )
    )
  }

  @Test("Replays the native action silently when the effect fails before closing")
  func replaysNativeCloseBeforeCloseRequest() {
    #expect(
      WindowControlInterceptionPolicy.recovery(didRequestClose: false)
        == .replayNativeActionSilently
    )
  }

  @Test("Leaves an existing native close flow in place without showing an error")
  func preservesNativeCloseFlowAfterCloseRequest() {
    #expect(
      WindowControlInterceptionPolicy.recovery(didRequestClose: true)
        == .leaveNativeCloseFlowInPlaceSilently
    )
  }
}
