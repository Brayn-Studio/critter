import Testing
@testable import CritterKit

@Test func builtinSkinLoadsFromCritterKit() {
    #expect(SkinLoader.builtin().name == "sprig")
}

@Test func multiSelectSeparatorIsCommaSpace() {
    #expect(BridgeProtocol.multiSelectSeparator == ", ")
}
