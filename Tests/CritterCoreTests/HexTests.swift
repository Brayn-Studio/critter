import Foundation
import Testing
@testable import CritterCore

@Test func sha256OfABC() {
    #expect(Hex.sha256(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(Hex.sha256(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
}

/// The digests that already sit on disk (match keys, device token hashes) are unchanged by the move.
@Test func matchKeyAndTokenHashUseTheSameDigest() {
    #expect(MatchKey.compute(toolName: "Bash", toolInput: ["command": "ls"]) == Hex.sha256(Data("Bash\n{\"command\":\"ls\"}".utf8)))
    #expect(MatchKey.compute(toolName: "Bash", toolInput: nil) == Hex.sha256(Data("Bash\n".utf8)))
}
