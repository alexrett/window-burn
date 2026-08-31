import CoreGraphics
import Testing

@testable import WindowBurnCore

@Suite("Protected window close confirmation")
struct WindowCloseConfirmationTests {
  @Test("A save sheet requests discarding the unsaved changes")
  func sheetRequestsDiscard() {
    #expect(
      WindowCloseConfirmation.evaluate(isWindowPresent: true, hasSheet: true)
        == .discardRequired
    )
  }

  @Test("A vanished window confirms that burning is safe")
  func vanishedWindowConfirmsClose() {
    #expect(
      WindowCloseConfirmation.evaluate(isWindowPresent: false, hasSheet: false) == .closed
    )
  }

  @Test("A window that is still present without a sheet needs another poll")
  func liveWindowRemainsPending() {
    #expect(
      WindowCloseConfirmation.evaluate(isWindowPresent: true, hasSheet: false) == .pending
    )
  }

  @Test("The non-default non-cancel button is the discard action")
  func selectsDiscardButton() {
    #expect(
      WindowCloseConfirmation.discardButtonIndex(
        buttonFrames: [
          CGRect(x: 0, y: 100, width: 110, height: 32),
          CGRect(x: 320, y: 25, width: 32, height: 32),
          CGRect(x: 220, y: 100, width: 100, height: 32),
          CGRect(x: 330, y: 100, width: 100, height: 32),
        ],
        defaultButtonIndex: 3,
        cancelButtonIndex: 2
      ) == 0
    )
  }

  @Test("An ambiguous modal is not accepted as destructive confirmation")
  func rejectsAmbiguousButtons() {
    #expect(
      WindowCloseConfirmation.discardButtonIndex(
        buttonFrames: [
          CGRect(x: 0, y: 100, width: 100, height: 32),
          CGRect(x: 110, y: 100, width: 100, height: 32),
          CGRect(x: 220, y: 100, width: 100, height: 32),
          CGRect(x: 330, y: 100, width: 100, height: 32),
        ],
        defaultButtonIndex: 3,
        cancelButtonIndex: 2
      ) == nil
    )
  }

  @Test("The leftmost button in the bottom three-action row is the fallback discard action")
  func selectsBottomRowFallback() {
    #expect(
      WindowCloseConfirmation.discardButtonIndex(
        buttonFrames: [
          CGRect(x: 320, y: 25, width: 32, height: 32),
          CGRect(x: 0, y: 100, width: 100, height: 32),
          CGRect(x: 220, y: 100, width: 100, height: 32),
          CGRect(x: 330, y: 100, width: 100, height: 32),
        ],
        defaultButtonIndex: nil,
        cancelButtonIndex: nil
      ) == 1
    )
  }
}
