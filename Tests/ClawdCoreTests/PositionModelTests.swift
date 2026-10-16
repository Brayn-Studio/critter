import CoreGraphics
import Foundation
import Testing
@testable import ClawdCore

@Test func anchorSideFollowsCenter() {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
    #expect(PositionModel.anchor(for: CGRect(x: 100, y: 50, width: 200, height: 80), in: screen) == Anchor(side: .left, x: 100, y: 50))
    #expect(PositionModel.anchor(for: CGRect(x: 700, y: 50, width: 200, height: 80), in: screen) == Anchor(side: .right, x: 900, y: 50))
}

@Test func rightAnchorGrowsLeftward() {
    let f = PositionModel.frame(size: CGSize(width: 300, height: 80), anchor: Anchor(side: .right, x: 900, y: 50), visible: CGRect(x: 0, y: 0, width: 1000, height: 800))
    #expect(f.maxX == 900 && f.minY == 50)
}

@Test func leftAnchorGrowsRightward() {
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let small = PositionModel.frame(size: CGSize(width: 100, height: 80), anchor: Anchor(side: .left, x: 100, y: 50), visible: visible)
    let large = PositionModel.frame(size: CGSize(width: 400, height: 80), anchor: Anchor(side: .left, x: 100, y: 50), visible: visible)
    #expect(small.minX == 100 && large.minX == 100)
    #expect(small.minY == 50 && large.minY == 50)
}

@Test func offscreenAnchorIsPulledBack() {
    // 外接屏拔掉后锚点落在 x=2500
    let f = PositionModel.frame(size: CGSize(width: 300, height: 80), anchor: Anchor(side: .right, x: 2500, y: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
    #expect(CGRect(x: 0, y: 0, width: 1440, height: 875).insetBy(dx: 4, dy: 4).contains(f))
}

@Test func offscreenToTheLeftAndBelowIsPulledBack() {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    let f = PositionModel.frame(size: CGSize(width: 300, height: 80), anchor: Anchor(side: .left, x: -900, y: -300), visible: visible)
    #expect(visible.insetBy(dx: 4, dy: 4).contains(f))
    #expect(f.minX == 4 && f.minY == 29)
}

@Test func oversizedFlockPinsBottomLeft() {
    let visible = CGRect(x: 100, y: 30, width: 600, height: 400)
    let wide = PositionModel.frame(size: CGSize(width: 900, height: 80), anchor: Anchor(side: .right, x: 650, y: 200), visible: visible)
    #expect(wide.minX == visible.minX + 4)
    #expect(wide.minY == 200) // height still fits: only x is pinned
    let huge = PositionModel.frame(size: CGSize(width: 900, height: 700), anchor: Anchor(side: .left, x: 300, y: 200), visible: visible)
    #expect(huge.minX == visible.minX + 4 && huge.minY == visible.minY + 4)
}

@Test func defaultAnchorIsBottomRightInset24() {
    let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    #expect(PositionModel.defaultAnchor(visible: visible) == Anchor(side: .right, x: 1416, y: 49))
}

@Test func anchorRoundTripsThroughFrame() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    for frame in [CGRect(x: 40, y: 60, width: 300, height: 140), CGRect(x: 1000, y: 500, width: 300, height: 140)] {
        let anchor = PositionModel.anchor(for: frame, in: screen)
        #expect(PositionModel.frame(size: frame.size, anchor: anchor, visible: screen) == frame)
    }
}

@Test func anchorIsCodable() throws {
    let anchor = Anchor(side: .left, x: 12.5, y: 40)
    let decoded = try JSONDecoder().decode(Anchor.self, from: JSONEncoder().encode(anchor))
    #expect(decoded == anchor)
}

@Test func screenForAnchorFallsBackToNil() {
    let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    // A right anchor sits on its screen's right edge: x == maxX still belongs to that screen.
    #expect(PositionModel.screenIndex(for: Anchor(side: .right, x: 1440, y: 50), screens: [main, external]) == 0)
    #expect(PositionModel.screenIndex(for: Anchor(side: .left, x: 1440, y: 50), screens: [main, external]) == 1)
    #expect(PositionModel.screenIndex(for: Anchor(side: .right, x: 3000, y: 50), screens: [main, external]) == 1)
    #expect(PositionModel.screenIndex(for: Anchor(side: .right, x: 3000, y: 50), screens: [main]) == nil)
}
