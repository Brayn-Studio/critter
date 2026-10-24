import Testing
@testable import CritterClient

/// Nothing is decided at touch-down or within 6 pt: a lift there is a tap.
@Test func aTouchIsUndecidedWithinTheSlop() {
    #expect(SliderTouch.read(dx: 0, dy: 0) == .undecided)
    #expect(SliderTouch.read(dx: 4, dy: 3) == .undecided)
    #expect(SliderTouch.read(dx: -5.9, dy: 0) == .undecided)
}

/// Past 6 pt, mostly sideways drags the thumb; mostly up or down is the page's scroll.
@Test func pastTheSlopTheDirectionDecides() {
    #expect(SliderTouch.read(dx: 6, dy: 0) == .drag)
    #expect(SliderTouch.read(dx: -8, dy: 5) == .drag)
    #expect(SliderTouch.read(dx: 0, dy: 6) == .scroll)
    #expect(SliderTouch.read(dx: 3, dy: -12) == .scroll)
    // Exactly diagonal is not mostly sideways: the page keeps it.
    #expect(SliderTouch.read(dx: 5, dy: 5) == .scroll)
}

/// The thumb stands on cell edges: a touch lights up to the nearest one, clamped to the slider.
@Test func aTouchLightsUpToTheNearestCellEdge() {
    #expect(SliderTouch.lit(x: 0, width: 300, segments: 10) == 0)
    #expect(SliderTouch.lit(x: 14, width: 300, segments: 10) == 0)
    #expect(SliderTouch.lit(x: 16, width: 300, segments: 10) == 1)
    #expect(SliderTouch.lit(x: 105, width: 300, segments: 10) == 4)
    #expect(SliderTouch.lit(x: 300, width: 300, segments: 10) == 10)
    #expect(SliderTouch.lit(x: -20, width: 300, segments: 10) == 0)
    #expect(SliderTouch.lit(x: 340, width: 300, segments: 10) == 10)
    #expect(SliderTouch.lit(x: 10, width: 0, segments: 10) == nil)
}
