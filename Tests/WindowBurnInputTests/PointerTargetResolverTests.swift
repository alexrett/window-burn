import CoreGraphics
import Foundation
import Testing
import WindowBurnCore

@testable import WindowBurn

@Suite struct PointerTargetResolverTests {
  @Test(arguments: [false, true])
  func cursorCannotHideNativeTargetWithOrWithoutScreenRecording(isRecording: Bool) {
    let screen = CGRect(x: 0, y: 0, width: 1710, height: 1107)
    let finder = CGRect(x: 29, y: 64, width: 855, height: 536)
    var raw = [
      candidate(id: 4, layer: 2_147_483_630, frame: CGRect(x: 50, y: 100, width: 28, height: 40))
    ]
    if isRecording { raw.append(candidate(id: 955, layer: 24, frame: screen)) }
    raw.append(candidate(id: 785, layer: 0, frame: finder))
    let native = PointerTargetResolver.nativeInputCandidates(from: raw)
    #expect(native.map(\.id) == [785])
    #expect(
      WindowAtPointMatcher.frontmost(
        at: CGPoint(x: 55, y: 110), amongFrontToBack: native, excludingPID: 0)?.id == 785)
  }

  @Test func normalWindowsRetainOcclusionOrder() {
    let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    let native = PointerTargetResolver.nativeInputCandidates(from: [
      candidate(id: 2, layer: 0, frame: frame),
      candidate(id: 1, layer: 0, frame: frame),
    ])
    #expect(native.map(\.id) == [2, 1])
  }

  private func candidate(id: UInt32, layer: Int, frame: CGRect) -> PointWindowCandidate {
    .init(id: id, ownerPID: 1, title: nil, frame: frame, layer: layer, isOnScreen: true, alpha: 1)
  }
}
