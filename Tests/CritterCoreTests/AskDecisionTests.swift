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

/// Measured on an iPhone: with the reason alone as the message ("等会"), Claude took it for the command's own error and
/// retried. The message says it is the user's refusal, that nothing ran, and gives the reason as theirs.
@Test func permissionDenyGivesTheReasonAsTheUsers() {
    let out = AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "deny", message: "  等会 \n"))!
    #expect(decision(out)["behavior"] == .string("deny"))
    #expect(decision(out)["message"] == .string("用户在手机上拒绝了，没有执行。用户的理由：等会"))
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

nonisolated(unsafe) private let twoQuestionInput: [String: Any] = try! JSONSerialization.jsonObject(with: Data(#"""
{"questions":[{"question":"Pick a number","header":"Number","options":[{"label":"One","description":"1"},{"label":"Two","description":"2"}],"multiSelect":false},{"question":"Pick a color","header":"Color","options":[{"label":"Red","description":"r"},{"label":"Blue","description":"b"}],"multiSelect":false}]}
"""#.utf8)) as! [String: Any]

/// Every question of the request needs an answer; none may be left out or added.
@Test func questionAnswerMustCoverEveryQuestion() {
    let partial = AnswerPayload(answers: ["Pick a number": "One"])
    #expect(!AskDecision.validate(partial, kind: .question, toolInput: twoQuestionInput))
    #expect(AskDecision.output(kind: .question, toolInput: twoQuestionInput, answer: partial) == nil)

    let full = AnswerPayload(answers: ["Pick a number": "One", "Pick a color": "Blue"])
    #expect(AskDecision.validate(full, kind: .question, toolInput: twoQuestionInput))
    let out = AskDecision.output(kind: .question, toolInput: twoQuestionInput, answer: full)!
    #expect(decision(out)["updatedInput"]?["answers"] == .object(["Pick a number": .string("One"), "Pick a color": .string("Blue")]))

    let extra = AnswerPayload(answers: ["Pick a number": "One", "Pick a color": "Blue", "Other?": "x"])
    #expect(!AskDecision.validate(extra, kind: .question, toolInput: twoQuestionInput))
    let blank = AnswerPayload(answers: ["Pick a number": "One", "Pick a color": "  "])
    #expect(!AskDecision.validate(blank, kind: .question, toolInput: twoQuestionInput))
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
    #expect(decision(out)["message"] == .string("用户在手机上没有批准这个计划，要求修改：改名为 x"))
}

/// What is checked is what goes out: answers are trimmed in the output too, so padding can't
/// carry an answer past the 4000-character limit.
@Test func answersAreTrimmedInTheOutput() throws {
    let out = try #require(AskDecision.output(kind: .question, toolInput: questionInput, answer: AnswerPayload(answers: ["Pick a number": "  好  "])))
    #expect(decision(out)["updatedInput"]?["answers"] == .object(["Pick a number": .string("好")]))

    let pad = String(repeating: " ", count: 10)
    let longest = String(repeating: "好", count: 4000)
    let padded = try #require(AskDecision.output(kind: .question, toolInput: questionInput, answer: AnswerPayload(answers: ["Pick a number": pad + longest + pad])))
    #expect(decision(padded)["updatedInput"]?["answers"] == .object(["Pick a number": .string(longest)]))
    #expect(AskDecision.output(kind: .question, toolInput: questionInput, answer: AnswerPayload(answers: ["Pick a number": pad + longest + "好" + pad])) == nil)
}

@Test func planReviseMessageIsTrimmed() throws {
    let out = try #require(AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "revise", message: "  改一下  \n")))
    #expect(decision(out)["message"] == .string("用户在手机上没有批准这个计划，要求修改：改一下"))
}

@Test func wrongDecisionForKindIsRejected() {
    #expect(AskDecision.output(kind: .permission, toolInput: bashInput, answer: AnswerPayload(decision: "approve")) == nil)
    #expect(AskDecision.output(kind: .plan, toolInput: planInput, answer: AnswerPayload(decision: "allow")) == nil)
}

/// The key doesn't depend on the order of the tool input's keys, at any depth. Both orders come
/// from JSON text, as the hooks get them (two dictionary literals in one process could simply
/// iterate alike); array order and every value still count.
@Test func matchKeyIgnoresKeyOrder() throws {
    let forward = #"{"command":"ls -la","description":"List","timeout":120000,"run_in_background":false,"sandbox":true,"ratio":0.25,"nested":{"z":1,"a":[{"y":2,"b":"3"}],"m":null},"list":[3,1,2],"text":"中文/é \"q\"","zeta":"last"}"#
    let backward = #"{"zeta":"last","text":"中文/é \"q\"","list":[3,1,2],"nested":{"m":null,"a":[{"b":"3","y":2}],"z":1},"ratio":0.25,"sandbox":true,"run_in_background":false,"timeout":120000,"description":"List","command":"ls -la"}"#
    func key(_ text: String, tool: String = "Bash") throws -> String {
        MatchKey.compute(toolName: tool, toolInput: try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }
    let a = try key(forward)
    #expect(a == (try key(backward)))
    #expect(a.count == 64)
    #expect(a != (try key(forward, tool: "Edit")))
    #expect(a != (try key(forward.replacingOccurrences(of: "[3,1,2]", with: "[1,2,3]"))))
    #expect(a != (try key(forward.replacingOccurrences(of: #""y":2"#, with: #""y":3"#))))
}

@Test func displayInputTruncatesLongContentButNotCommand() {
    let long = String(repeating: "x", count: 5000)
    let shown = AskDecision.displayInput(["content": long, "command": long])
    #expect(shown["content"] == .string(String(repeating: "x", count: 4096) + "…"))
    #expect(shown["command"] == .string(long))
}

/// 4096 characters stay as they are; 4097 are cut to 4096 plus "…".
@Test func displayInputTruncationBoundary() {
    let limit = String(repeating: "x", count: 4096)
    let shown = AskDecision.displayInput(["content": limit, "other": limit + "y"])
    #expect(shown["content"] == .string(limit))
    #expect(shown["other"] == .string(limit + "…"))
}

/// Long strings are cut wherever they sit -- in nested objects and arrays -- by the key they are
/// under; an array under a key that is shown in full is shown in full too.
@Test func displayInputTruncatesNestedStrings() {
    let long = String(repeating: "y", count: 5000)
    let cut = JSONValue.string(String(repeating: "y", count: 4096) + "…")
    let shown = AskDecision.displayInput([
        "edits": [["old_string": long, "new_string": "n"]],
        "meta": ["deep": ["text": long]],
        "questions": [["question": long, "options": [["label": long]]]],
    ])
    #expect(shown["edits"] == .array([.object(["old_string": cut, "new_string": .string("n")])]))
    #expect(shown["meta"]?["deep"]?["text"] == cut)
    #expect(shown["questions"] == .array([.object(["question": .string(long), "options": .array([.object(["label": cut])])])]))
}

/// The cut falls between characters: one made of several Unicode scalars (a skin-toned
/// emoji, a ZWJ sequence) is kept whole or left out whole.
@Test func displayInputNeverSplitsACharacter() {
    for character in ["👍🏽", "👩🏽‍💻", "🇨🇳", "é"] {
        let text = String(repeating: "x", count: 4095) + character + character
        let shown = AskDecision.displayInput(["content": text])
        #expect(shown["content"] == .string(String(repeating: "x", count: 4095) + character + "…"), Comment(rawValue: character))
    }
}

@Test func jsonValueKeepsBooleansApartFromNumbers() {
    let value = JSONValue(any: try! JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":null}"#.utf8)))
    #expect(value["a"] == .bool(true))
    #expect(value["b"] == .number(1))
    #expect(value["c"] == .null)
}
