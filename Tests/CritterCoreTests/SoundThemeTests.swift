import Foundation
import Testing
@testable import CritterCore

@Test func storedThemeFallsBackToVoice() {
    #expect(SoundTheme(storedValue: nil) == .voice)
    #expect(SoundTheme(storedValue: "kazoo") == .voice)
    #expect(SoundTheme(storedValue: "marimba") == .marimba)
    #expect(SoundTheme(storedValue: "system") == .system)
}

@Test func bundledThemesNameOneFilePerAlertState() {
    #expect(SoundTheme.voice.resourcePath(for: .waiting) == "voice/waiting.wav")
    #expect(SoundTheme.pixel.resourcePath(for: .done) == "pixel/done.wav")
    #expect(SoundTheme.marimba.resourcePath(for: .error) == "marimba/error.wav")
    #expect(SoundTheme.voice.resourcePath(for: .idle) == nil)
    #expect(SoundTheme.pixel.resourcePath(for: .running) == nil)
    #expect(SoundTheme.system.resourcePath(for: .done) == nil)
}

@Test func systemSoundsAreDistinctAndInstalled() throws {
    var names: Set<String> = []
    for state in [PetState.waiting, .done, .error] {
        let name = try #require(SoundTheme.systemSoundName(for: state))
        #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(name).aiff"))
        names.insert(name)
    }
    #expect(names.count == 3)
    #expect(SoundTheme.systemSoundName(for: .idle) == nil)
    #expect(SoundTheme.systemSoundName(for: .running) == nil)
}

/// Every file a theme names is in `Sounds/` (which `build-app.sh` copies into the app),
/// and is a PCM WAV with audio in it that lasts well under the 1.5 s an alert may take.
@Test func everyBundledSoundIsAShortPCMWAV() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "../../Sounds").standardized
    var checked = 0
    for theme in SoundTheme.allCases {
        for state in PetState.allCases {
            guard let path = theme.resourcePath(for: state) else { continue }
            let wav = try #require(WAVInfo(Data(contentsOf: root.appending(path: path))), "\(path) is not a WAV")
            #expect(wav.format == 1, "\(path) is not PCM")
            #expect(wav.dataBytes > 0, "\(path) is empty")
            #expect(Double(wav.dataBytes) / Double(wav.byteRate) < 1.5, "\(path) is too long")
            checked += 1
        }
    }
    #expect(checked == 9)
}

/// The few RIFF fields the bundled-sound check needs.
private struct WAVInfo {
    var format = 0
    var byteRate = 0
    var dataBytes = 0

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func tag(_ at: Int) -> String { String(decoding: bytes[at..<at + 4], as: UTF8.self) }
        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }
        var at = 12
        while at + 8 <= bytes.count {
            let size = u32(at + 4)
            switch tag(at) {
            case "fmt " where at + 20 <= bytes.count:
                format = Int(bytes[at + 8]) | Int(bytes[at + 9]) << 8
                byteRate = u32(at + 16)
            case "data":
                dataBytes = size
            default:
                break
            }
            at += 8 + size + size % 2
        }
        guard byteRate > 0 else { return nil }
    }
}
