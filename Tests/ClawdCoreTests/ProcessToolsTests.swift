import Foundation
import Testing
@testable import ClawdCore

@Test func ownProcessFacts() {
    let me = getpid()
    #expect(ProcessTools.isAlive(me))
    #expect(ProcessTools.startTime(of: me) != nil)
    #expect(ProcessTools.parentPid(of: me) == getppid())
    #expect(!ProcessTools.ancestors(of: me, maxDepth: 10).isEmpty)
}

@Test func deadProcessIsNotAlive() throws {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
    try p.run(); let pid = p.processIdentifier
    #expect(ProcessTools.isAlive(pid))
    p.terminate(); p.waitUntilExit()
    #expect(!ProcessTools.isAlive(pid))
}

@Test func claudeExecutableDetection() {
    #expect(ProcessTools.isClaudeExecutable(path: "/Users/u/.local/share/claude/versions/2.1.301"))
    #expect(ProcessTools.isClaudeExecutable(path: "/x/anthropic.claude-code-2.1.300-darwin-arm64/resources/native-binary/claude"))
    #expect(ProcessTools.isClaudeExecutable(path: "/Users/u/Library/Application Support/Claude/claude-code/2.1.295/9d/claude.app/Contents/MacOS/claude"))
    #expect(!ProcessTools.isClaudeExecutable(path: "/bin/zsh"))
}
