import Foundation
import Testing
@testable import CritterCore

private let prefs = BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 0.5, mergeThreshold: 5, soundTheme: "pixel")
private let home = "/Users/me"

private func session(_ id: String, cwd: String, transcript: String? = nil) -> PetSession {
    PetSession(id: id, name: id, source: .terminal, state: .idle, detail: nil, cwd: cwd, pid: nil,
               transcriptPath: transcript, tracked: true, eventTime: 1, sortKey: 2)
}

private func usageLine(_ tokens: Int, model: String = "claude-opus-5-5") -> String {
    #"{"type":"assistant","message":{"model":"\#(model)","usage":{"input_tokens":\#(tokens)}}}"#
}

/// A made-up file system: what each lookup returns, and how often each was made.
private final class FakeFiles: @unchecked Sendable {
    var heads: [String: URL] = [:]                 // cwd -> HEAD file
    var modified: [URL: Date] = [:]                // HEAD file -> modification time
    var branches: [String: String] = [:]           // cwd -> branch
    var transcripts: [String: (size: UInt64, modified: Date, text: String)] = [:]
    var branchReads: [String] = []
    var tailReads: [String] = []

    var dependencies: SnapshotAssembler.Dependencies {
        SnapshotAssembler.Dependencies(
            headFile: { cwd, stop in
                #expect(stop == home)
                return self.heads[cwd]
            },
            modificationDate: { self.modified[$0] },
            readBranch: { cwd, _ in
                self.branchReads.append(cwd)
                return self.branches[cwd]
            },
            attributes: { path in self.transcripts[path].map { ($0.size, $0.modified) } },
            readTail: { path, size in
                self.tailReads.append(path)
                #expect(self.transcripts[path]?.size == size)
                return self.transcripts[path].map { Data(("\n" + $0.text + "\n").utf8) }
            }
        )
    }
}

/// The assembler gives exactly what `SnapshotBuilder` makes of the same inputs, with each cwd's
/// branch and each transcript's estimate filled in -- the estimate only where the status line
/// reported no context.
@Test func assembledSnapshotIsTheBuildersWithBranchesAndEstimates() {
    let files = FakeFiles()
    files.heads = ["/Users/me/a": URL(fileURLWithPath: "/Users/me/a/.git/HEAD")]
    files.modified = [URL(fileURLWithPath: "/Users/me/a/.git/HEAD"): Date(timeIntervalSince1970: 1)]
    files.branches = ["/Users/me/a": "main"]
    files.transcripts = [
        "/t/a.jsonl": (100, Date(timeIntervalSince1970: 5), usageLine(5210)),
        "/t/b.jsonl": (200, Date(timeIntervalSince1970: 6), usageLine(77)),
    ]
    let sessions = [
        session("a", cwd: "/Users/me/a", transcript: "/t/a.jsonl"),
        session("b", cwd: "/Users/me/b", transcript: "/t/b.jsonl"),
        session("c", cwd: "", transcript: nil),
    ]
    let reported = StatusLineRecord(sessionId: "b", updatedAt: 1, contextWindowSize: 200_000, contextUsedPercentage: 12)
    let request = PendingRequest(requestId: "r", sessionId: "a", kind: .permission, toolName: "Bash", summary: "s",
                                 input: .null, matchKey: "k", createdAt: 1, expiresAt: 2, hookPid: 1)
    let assembler = SnapshotAssembler(home: home, dependencies: files.dependencies)

    let body = assembler.build(sessions: sessions, skins: ["a": "sprig"], statuses: [reported], pending: [request], prefs: prefs)

    #expect(body == SnapshotBuilder.build(SnapshotInputs(
        sessions: sessions, skins: ["a": "sprig"], statuses: [reported], pending: [request],
        branches: ["/Users/me/a": "main"], estimates: ["a": ContextEstimate(usedTokens: 5210, model: "claude-opus-5-5")],
        prefs: prefs, home: home
    )))
    #expect(files.branchReads.sorted() == ["/Users/me/a", "/Users/me/b"])
    #expect(files.tailReads == ["/t/a.jsonl"]) // b's context came from its status line
}

/// A branch is read again only when its HEAD file's modification time changes; a transcript only
/// when its size or modification time does. Entries for cwds and transcripts no longer shown go.
@Test func unchangedFilesAreNotReadAgain() {
    let files = FakeFiles()
    let head = URL(fileURLWithPath: "/Users/me/a/.git/HEAD")
    files.heads = ["/Users/me/a": head]
    files.modified = [head: Date(timeIntervalSince1970: 1)]
    files.branches = ["/Users/me/a": "main"]
    files.transcripts = ["/t/a.jsonl": (100, Date(timeIntervalSince1970: 5), usageLine(1000))]
    let assembler = SnapshotAssembler(home: home, dependencies: files.dependencies)
    let a = [session("a", cwd: "/Users/me/a", transcript: "/t/a.jsonl")]
    func build(_ sessions: [PetSession]) -> SnapshotBody {
        assembler.build(sessions: sessions, skins: [:], statuses: [], pending: [], prefs: prefs)
    }

    _ = build(a)
    _ = build(a)
    #expect(files.branchReads == ["/Users/me/a"])
    #expect(files.tailReads == ["/t/a.jsonl"])

    files.modified[head] = Date(timeIntervalSince1970: 2)
    files.branches["/Users/me/a"] = "feature"
    #expect(build(a).sessions.first?.branch == "feature")
    #expect(files.branchReads.count == 2)

    files.transcripts["/t/a.jsonl"] = (150, Date(timeIntervalSince1970: 5), usageLine(2000))
    _ = build(a)
    #expect(files.tailReads.count == 2)
    files.transcripts["/t/a.jsonl"] = (150, Date(timeIntervalSince1970: 9), usageLine(3000))
    _ = build(a)
    #expect(files.tailReads.count == 3)

    // Gone from the snapshot, gone from the caches: shown again, read again.
    _ = build([])
    _ = build(a)
    #expect(files.branchReads.count == 3)
    #expect(files.tailReads.count == 4)

    // Switched off and on: everything is read afresh.
    assembler.reset()
    _ = build(a)
    #expect(files.branchReads.count == 4)
    #expect(files.tailReads.count == 5)
}

/// A repository without a HEAD file to watch caches "no branch" until one appears.
@Test func noHeadFileIsCachedToo() {
    let files = FakeFiles()
    let assembler = SnapshotAssembler(home: home, dependencies: files.dependencies)
    let a = [session("a", cwd: "/Users/me/a")]
    _ = assembler.build(sessions: a, skins: [:], statuses: [], pending: [], prefs: prefs)
    _ = assembler.build(sessions: a, skins: [:], statuses: [], pending: [], prefs: prefs)
    #expect(files.branchReads == ["/Users/me/a"])
}

/// The live tail reader: the last `transcriptTailBytes` of the file, with a newline in front when
/// the whole file fits (`ContextUsage` drops the first line as possibly cut off).
@Test func tailReadsTheEndOfTheFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assembler-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let small = dir.appendingPathComponent("small.jsonl")
    try Data("a\nb\n".utf8).write(to: small)
    #expect(SnapshotAssembler.tail(of: small.path, size: 4) == Data("\na\nb\n".utf8))

    let big = dir.appendingPathComponent("big.jsonl")
    let content = Data(repeating: UInt8(ascii: "x"), count: SnapshotAssembler.transcriptTailBytes + 10)
    try content.write(to: big)
    #expect(SnapshotAssembler.tail(of: big.path, size: UInt64(content.count)) == content.suffix(SnapshotAssembler.transcriptTailBytes))
    #expect(SnapshotAssembler.tail(of: dir.appendingPathComponent("missing").path, size: 1) == nil)
}

@Test func codexPhoneAssemblerUsesSessionTelemetryWithoutReadingClaudeUsage() {
    let files = FakeFiles()
    files.transcripts = ["/codex.jsonl": (100, Date(timeIntervalSince1970: 1), usageLine(999_000))]
    var codex = session("codex-a", cwd: "", transcript: "/codex.jsonl")
    codex.source = .codexDesktop
    codex.telemetry = CodexTelemetry(model: "gpt-6-sol", usedTokens: 12_800, contextWindow: 128_000)
    let capabilities = BridgeCapabilities(canSay: true, canInterrupt: true)
    let assembler = SnapshotAssembler(home: home, dependencies: files.dependencies)
    let body = assembler.build(
        sessions: [codex], skins: [:], statuses: [], pending: [], prefs: prefs,
        capabilities: ["codex-a": capabilities]
    )
    #expect(body.sessions.first?.model == "gpt-6-sol")
    #expect(body.sessions.first?.context == BridgeContext(usedPercent: 10, windowSize: 128_000, estimated: false))
    #expect(body.sessions.first?.capabilities == capabilities)
    #expect(files.tailReads.isEmpty)
}
