import Testing
@testable import ClawdCore

@Test func toolCategories() {
    for t in ["Edit", "MultiEdit", "Write", "NotebookEdit"] { #expect(WorkActivity.forTool(t) == .laptop) }
    for t in ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"] { #expect(WorkActivity.forTool(t) == .read) }
    for t in ["Bash", "BashOutput", "KillShell"] { #expect(WorkActivity.forTool(t) == .bash) }
    for t in ["Agent", "Task"] { #expect(WorkActivity.forTool(t) == .juggle) }
    #expect(WorkActivity.forTool("mcp__github__create_issue") == .laptop)
    #expect(WorkActivity.forTool("SomethingNew") == .laptop)
}
