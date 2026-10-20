import Foundation
import Testing
@testable import CritterCore

private let ipcThread = "11111111-2222-4333-8444-555555555555"
private func j(_ object: Any) -> JSONValue { JSONValue(any: object) }

@Test func codexIPCFramesHandleSplitHeaderAndUnicode() throws {
    let value = j(["type": "response", "result": ["message": "你好🌱"]])
    let frame = try CodexIPCFraming.encode(value)
    var decoder = CodexIPCFraming()
    let first = try decoder.append(frame.prefix(2))
    #expect(first.isEmpty)
    let second = try decoder.append(frame.dropFirst(2).dropLast(1))
    #expect(second.isEmpty)
    let last = try decoder.append(frame.suffix(1))
    #expect(last == [value])
    #expect(throws: CodexIPCFraming.Failure.self) { try decoder.append(Data([255,255,255,127])) }
}

@Test func codexIPCStateChecksOwnerAndRevisionBeforeApplyingPatches() throws {
    var state = CodexIPCConversation(threadID: ipcThread, ownerID: "owner", canReceiveInput: true)
    let snapshot = j(["type": "snapshot", "revision": 4, "conversationState": ["requests": [], "threadRuntimeStatus": ["type": "active"],
        "turnHistory": ["history": ["entitiesByKey": ["turn-key": ["turnId": "turn-1", "status": "inProgress", "turnStartedAtMs": 42]]]]]])
    let applied1 = state.apply(change: snapshot, source: "stranger")
    #expect(!applied1)
    #expect(state.revision == nil)
    let applied2 = state.apply(change: snapshot, source: "owner")
    #expect(applied2)
    #expect(state.activeTurnID == "turn-1")
    let question: [String:Any] = ["id": 9, "method": "item/tool/requestUserInput", "params": ["threadId": ipcThread, "questions": [["id":"q1","header":"方向","question":"选择方向","options":[["label":"继续","description":"继续工作"]]]]]]
    let applied3 = state.apply(change: j(["type":"patches","baseRevision":4,"revision":5,"patches":[["op":"add","path":["requests",0],"value":question]]]), source: "owner")
    #expect(applied3)
    #expect(state.phoneRequests(now: 100).count == 1)
    let applied4 = state.apply(change: j(["type":"patches","baseRevision":3,"revision":6,"patches":[]]), source:"owner")
    #expect(!applied4)
    #expect(state.phoneRequests(now: 100).isEmpty)
    #expect(!state.capabilities.canSay)
}

@Test func codexIPCAnswersPreserveQuestionIDsAndOriginalRequestIDType() throws {
    let raw = j(["id":17,"method":"item/tool/requestUserInput","params":["threadId":ipcThread,"questions":[["id":"choice","header":"选择","question":"先做哪项？","options":[["label":"手机","description":"完善手机"]]]]]])
    let prompt = try #require(CodexIPCPhoneRequest(threadID: ipcThread, raw: raw, now: 100))
    #expect(prompt.pending.kind == .question)
    let response = try #require(prompt.response(to: AnswerPayload(answers:["先做哪项？":"手机"])))
    #expect(response.method == "thread-follower-submit-user-input")
    #expect(response.params["requestId"] == .number(17))
    #expect(response.params["response"] == j(["answers":["choice":["answers":["手机"]]]]))
    #expect(prompt.response(to: AnswerPayload(answers:["wrong":"手机"])) == nil)
}

@Test func codexIPCApprovalOnlyGrantsThisRequestAndRejectsUnavailableDecision() throws {
    let raw = j(["id":"approval","method":"item/commandExecution/requestApproval","params":["threadId":ipcThread,"command":"swift test","availableDecisions":["accept","decline"]]])
    let prompt = try #require(CodexIPCPhoneRequest(threadID: ipcThread, raw:raw, now:100))
    #expect(prompt.pending.input["command"] == .string("swift test"))
    #expect(prompt.response(to:AnswerPayload(decision:"allow"))?.params["decision"] == .string("accept"))
    #expect(prompt.response(to:AnswerPayload(decision:"deny"))?.params["decision"] == .string("decline"))
    #expect(CodexIPCPhoneRequest(threadID: ipcThread, raw:j(["id":1,"method":"openai/userVerification","params":[:]]),now:100) == nil)
    let secret = j(["id":1,"method":"item/tool/requestUserInput","params":["questions":[["id":"password","question":"密码","isSecret":true]]]])
    #expect(CodexIPCPhoneRequest(threadID: ipcThread,raw:secret,now:100) == nil)
}

@Test func codexActiveMessageIncludesTheOwnersRequiredRestoreContext() throws {
    var state = CodexIPCConversation(threadID: ipcThread, ownerID:"owner", canReceiveInput:true)
    _ = state.apply(change:j(["type":"snapshot","revision":1,"conversationState":["cwd":"/work/project","requests":[],"threadRuntimeStatus":["type":"active"]]]),source:"owner")
    let operation = try #require(state.message("继续完善手机"))
    #expect(operation.method == "thread-follower-steer-turn")
    #expect(operation.params["restoreMessage"]?["cwd"] == .string("/work/project"))
    #expect(operation.params["restoreMessage"]?["context"]?["workspaceRoots"] == .array([.string("/work/project")]))
    #expect(operation.params["restoreMessage"]?["id"] == operation.params["clientUserMessageId"])
}

@Test func codexIPCApprovalIdentityIncludesTheExactParameters() throws {
    func prompt(_ command: String) throws -> CodexIPCPhoneRequest {
        try #require(CodexIPCPhoneRequest(threadID:ipcThread,raw:j(["id":1,"method":"item/commandExecution/requestApproval","params":["threadId":ipcThread,"command":command]]),now:100))
    }
    #expect(try prompt("swift test").pending.requestId != prompt("swift build").pending.requestId)
}
@Test func codexIPCUsesTheRealOwnersTokenUsageShape() {
    var state = CodexIPCConversation(threadID:ipcThread,ownerID:"owner",canReceiveInput:true)
    _ = state.apply(change:j(["type":"snapshot","revision":1,"conversationState":["cwd":"/work","requests":[],"latestModel":"gpt-test",
        "latestTokenUsageInfo":["total":["totalTokens":999999],"last":["totalTokens":25000],"modelContextWindow":100000]]]),source:"owner")
    #expect(state.telemetry?.usedTokens == 25000)
    #expect(state.telemetry?.contextWindow == 100000)
}
