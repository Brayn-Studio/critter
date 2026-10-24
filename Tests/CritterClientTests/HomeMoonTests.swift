import CoreGraphics
import Testing
@testable import CritterClient

private let width: CGFloat = 360
private let ground: CGFloat = 200

/// The mockup's "MacBook Pro" ends well short of the moon: the mockup's spot, 0.58 across and 0.3 down.
@Test func aShortNameLeavesTheMockupsMoon() {
    #expect(HomeMoon.position(width: width, ground: ground, nameRight: 148, nameBottom: 66) == CGPoint(x: 0.58, y: 0.3))
}

/// "文博的MacBook Pro" on a 360 pt screen (measured 18..219 wide and down to 69.7) reached into the moon at 210:
/// it drops just under the name, in the same column.
@Test func aLongNameSendsTheMoonUnderIt() {
    let p = HomeMoon.position(width: width, ground: ground, nameRight: 219, nameBottom: 69.7)
    #expect(p.x == 0.58)
    #expect(p.y * ground >= 69.7 + 4 - 0.001, "the moon's top \(p.y * ground) must clear the name")
    // Still well above the Critters' heads (21 cells of 3 pt under the ground line) and their bubbles.
    #expect(p.y * ground + 21 < ground - 63 - 30)
}

/// A long name whose line ends above the moon's top already (a short status bar) leaves the moon where it is.
@Test func aLongNameAboveTheMoonLeavesIt() {
    #expect(HomeMoon.position(width: width, ground: ground, nameRight: 240, nameBottom: 50) == CGPoint(x: 0.58, y: 0.3))
}

/// A wider screen moves the moon right with it, so a name that fits short of it there leaves it alone.
@Test func theMoonFollowsTheWidth() {
    #expect(HomeMoon.position(width: 412, ground: ground, nameRight: 230, nameBottom: 70) == CGPoint(x: 0.58, y: 0.3))
}

@Test func theMoonNeverLeavesTheMeadow() {
    #expect(HomeMoon.position(width: width, ground: ground, nameRight: 300, nameBottom: 500).y == 1)
}
