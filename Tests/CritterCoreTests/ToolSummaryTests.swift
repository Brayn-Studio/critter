import Testing
@testable import CritterCore

@Test func truncationCollapsesWhitespaceAndCountsCharacters() {
    #expect(ToolSummary.truncate("a\n\n  b\tc", max: 40) == "a b c")
    let long = String(repeating: "测", count: 100)
    #expect(ToolSummary.truncate(long, max: 40).count == 40)
    #expect(ToolSummary.truncate(long, max: 40).hasSuffix("…"))
    #expect(ToolSummary.truncate("🦀🦀🦀🦀", max: 3) == "🦀🦀…")
}

@Test func activitySummaries() {
    #expect(ToolSummary.activity(toolName: "Bash", input: .object(["command": .string("npm test\nnpm run lint")])) == "Bash: npm test")
    #expect(ToolSummary.activity(toolName: "Edit", input: .object(["file_path": .string("/a/b/App.swift")])) == "编辑 App.swift")
    #expect(ToolSummary.activity(toolName: "mcp__github__create_issue", input: nil) == "MCP: create_issue")
    #expect(ToolSummary.activity(toolName: "Bash", input: .object(["command": .string(String(repeating: "x", count: 500))])).count == 40)
}

@Test func permissionSummary() {
    #expect(ToolSummary.permission(toolName: "Bash", input: .object(["command": .string("npm test")])) == "需要你确认：Bash(npm test)")
}
