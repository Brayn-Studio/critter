import Foundation
import Testing
@testable import CritterCore

@Test func hotKeyDisplay() {
    #expect(HotKeyFormat.display(.default) == "⌃⌥C")
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 35 /* P */, modifiers: HotKeySpec.command | HotKeySpec.shift | HotKeySpec.control)) == "⌃⇧⌘P")
}

@Test func hotKeyDisplayCoversLettersDigitsAndOtherKeys() {
    let letters = Set((0..<128).map { HotKeyFormat.display(HotKeySpec(keyCode: UInt32($0), modifiers: 0)) }.filter { $0.count == 1 })
    #expect(letters == Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".map(String.init)))
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 29, modifiers: HotKeySpec.option)) == "⌥0")
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 25, modifiers: HotKeySpec.command)) == "⌘9")
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 49 /* space */, modifiers: HotKeySpec.option)) == "⌥Key49")
    let all = HotKeySpec.command | HotKeySpec.shift | HotKeySpec.option | HotKeySpec.control
    #expect(HotKeyFormat.display(HotKeySpec(keyCode: 0, modifiers: all)) == "⌃⌥⇧⌘A")
}

@Test func hotKeySpecRoundTripsThroughJSON() throws {
    let spec = HotKeySpec(keyCode: 35, modifiers: HotKeySpec.control | HotKeySpec.option | HotKeySpec.shift)
    #expect(try JSONDecoder().decode(HotKeySpec.self, from: JSONEncoder().encode(spec)) == spec)
    #expect(HotKeySpec.default == HotKeySpec(keyCode: 8, modifiers: 0x1800))
}

@Test func cocoaModifierFlagsMapToTheCarbonMask() {
    // NSEvent.ModifierFlags: shift 1<<17, control 1<<18, option 1<<19, command 1<<20.
    #expect(HotKeySpec.carbonModifiers(cocoaFlags: (1 << 18) | (1 << 19)) == HotKeySpec.control | HotKeySpec.option)
    #expect(HotKeySpec.carbonModifiers(cocoaFlags: (1 << 17) | (1 << 20)) == HotKeySpec.shift | HotKeySpec.command)
    // Caps Lock, numeric pad and fn are not part of a hot key.
    #expect(HotKeySpec.carbonModifiers(cocoaFlags: (1 << 16) | (1 << 21) | (1 << 23)) == 0)
}

@Test func onlyCombosWithControlOptionOrCommandCanBeRecorded() {
    #expect(!HotKeySpec(keyCode: 35, modifiers: 0).isRecordable)
    // Shift alone would steal a capital letter from every app.
    #expect(!HotKeySpec(keyCode: 35, modifiers: HotKeySpec.shift).isRecordable)
    #expect(HotKeySpec(keyCode: 35, modifiers: HotKeySpec.control | HotKeySpec.option | HotKeySpec.shift).isRecordable)
    #expect(HotKeySpec(keyCode: 35, modifiers: HotKeySpec.command).isRecordable)
}
