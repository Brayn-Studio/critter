import Foundation
import Testing
@testable import CritterCore

nonisolated(unsafe) private let bashInput: [String: Any] = ["command": "touch reject-me.txt", "description": "Create empty file reject-me.txt"]
nonisolated(unsafe) private let questionInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick a number","header":"Number","options":[{"label":"One","description":"Choose option One"},{"label":"Two","description":"Choose option Two"}],"multiSelect":false}]}
"""#.utf8)) as! [String: Any]
nonisolated(unsafe) private let planInput: [String: Any] = ["plan": "# Plan: create plan-marker-2.txt\n\n## Steps\n1. Run `touch plan-marker-2.txt`.\n", "planFilePath": "/Users/u/.claude/plans/x.md"]

private func json(_ data: Data) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: data) }
private func json(_ text: String) -> JSONValue { json(Data(text.utf8)) }
private func decision(_ data: Data) -> JSONValue { json(data)["hookSpecificOutput"]!["decision"]! }

@Test func permissionAllowOutput() {
    let out = AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "allow"))!
    #expect(json(out) == json(#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#))
}

@Test func permissionDenyUsesDefaultMessageWhenBlank() {
    let out = AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "deny", message: "  "))!
    #expect(decision(out)["behavior"] == .string("deny"))
    #expect(decision(out)["message"] == .string("用户在手机上拒绝了"))
}

@Test func questionOutputEchoesInputPlusAnswers() {
    let out = AskDecision.output(kind: .question, toolInput: questionInput, answer: AnswerPayload(answers: ["Pick a number": "Two"]))!
    let d = decision(out)
    #expect(d["behavior"] == .string("allow"))
    #expect(d["updatedInput"]?["questions"] == JSONValue(any: questionInput["questions"]))
    #expect(d["updatedInput"]?["answers"] == .object(["Pick a number": .string("Two")]))
}

@Test func questionFreeTextIsAccepted() {
    let answer = AnswerPayload(answers: ["Pick a number": "Mango"])
    #expect(AskDecision.validate(answer, kind: .question, toolInput: questionInput))
}

nonisolated(unsafe) private let multiInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick letters","header":"Letters","options":[{"label":"A","description":"Option A"},{"label":"B","description":"Option B"},{"label":"C","description":"Option C"}],"multiSelect":true}]}
"""#.utf8)) as! [String: Any]

/// Spec section 13 item 1, measured in a real session: a multi-select answer is the chosen
/// labels joined with ", " in one string, and it reaches Claude as exactly that.
@Test func questionMultiSelectFormat() {
    #expect(AskDecision.multiSelectSeparator == ", ")
    let value = ["A", "B"].joined(separator: AskDecision.multiSelectSeparator)
    #expect(value == "A, B")
    let answer = AnswerPayload(answers: ["Pick letters": value])
    #expect(AskDecision.validate(answer, kind: .question, toolInput: multiInput))
    let out = AskDecision.output(kind: .question, toolInput: multiInput, answer: answer)!
    #expect(decision(out)["updatedInput"]?["answers"] == .object(["Pick letters": .string("A, B")]))
    #expect(decision(out)["updatedInput"]?["questions"] == JSONValue(any: multiInput["questions"]))
}

@Test func answerWithUnknownQuestionIsRejected() {
    let answer = AnswerPayload(answers: ["Other?": "x"])
    #expect(!AskDecision.validate(answer, kind: .question, toolInput: questionInput))
    #expect(AskDecision.output(kind: .question, toolInput: questionInput, answer: answer) == nil)
}

@Test func planApproveEchoesInput() {
    let out = AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "approve"))!
    #expect(decision(out)["behavior"] == .string("allow"))
    #expect(decision(out)["updatedInput"] == JSONValue(any: planInput))
}

@Test func planReviseNeedsMessage() {
    #expect(AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "revise", message: " ")) == nil)
    let out = AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "revise", message: "改名为 x"))!
    #expect(decision(out)["behavior"] == .string("deny"))
    #expect(decision(out)["message"] == .string("改名为 x"))
}

@Test func wrongDecisionForKindIsRejected() {
    #expect(AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "approve")) == nil)
    #expect(AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "allow")) == nil)
}

@Test func matchKeyIgnoresKeyOrder() {
    let a = MatchKey.compute(toolName: "Bash", toolInput: ["a": 1, "b": 2])
    let b = MatchKey.compute(toolName: "Bash", toolInput: ["b": 2, "a": 1])
    #expect(a == b)
    #expect(a != MatchKey.compute(toolName: "Edit", toolInput: ["a": 1, "b": 2]))
    #expect(a.count == 64)
}

@Test func displayInputTruncatesLongContentButNotCommand() {
    let long = String(repeating: "x", count: 5000)
    let shown = AskDecision.displayInput(["content": long, "command": long])
    #expect(shown["content"] == .string(String(repeating: "x", count: 4096) + "…"))
    #expect(shown["command"] == .string(long))
}

@Test func jsonValueKeepsBooleansApartFromNumbers() {
    let value = JSONValue(any: try! JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":null}"#.utf8)))
    #expect(value["a"] == .bool(true))
    #expect(value["b"] == .number(1))
    #expect(value["c"] == .null)
}
