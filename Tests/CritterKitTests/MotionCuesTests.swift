import Testing
@testable import CritterKit

@Test func lookAtYouIsNoticeThenAHeldLookUp() {
    let clip = MotionCues.lookAtYou(SkinLoader.builtin())
    #expect(clip.map(\.pose) == ["attn", "base", "look_up", "shut", "look_up", "base"])
    #expect(clip.map(\.ticks).reduce(0, +) == 29)
}

@Test func hopLandsWithDust() {
    let skin = SkinLoader.builtin()
    let clip = MotionCues.hop(skin)
    #expect(clip.count == 5)
    #expect(clip.map(\.dy) == [2, 4, 3, 1, 0])
    #expect(clip.last?.effect == skin.interactions.landDust)
    #expect(clip.map(\.ticks).reduce(0, +) == 6)
}

/// How long the hop lasts on screen: its ticks at the skin's tick (the floating shelf waits for it).
@Test func hopMsIsItsTicksAtTheSkinsTick() {
    let skin = SkinLoader.builtin()
    #expect(MotionCues.hopMs(skin) == 6 * skin.tickMs)
}
