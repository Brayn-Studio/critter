import Foundation
import Testing
@testable import CritterCore

// `critter-hook ask`'s gate with push (spec 6.7): a phone seen in the last 10 minutes, or an iPhone the Mac can
// push to. Waiting goes on as before: only the app's liveness and the bridge switch matter.

@Suite("AskGate")
struct AskGateTests {
    private let now: Int64 = 10_000_000

    private func status(lastClientSeen: Int64? = nil, pushReachable: Bool? = nil) -> AppStatus {
        AppStatus(
            pid: 1, visible: true, heartbeat: now - 1000, version: "t", bridgeEnabled: true,
            lastClientSeen: lastClientSeen, pushReachable: pushReachable
        )
    }

    @Test func startsWhenPushIsReachableEvenWithoutARecentPhone() {
        #expect(AskGate.shouldStart(status: status(pushReachable: true), now: now))
        // A phone last seen long ago does not matter either.
        #expect(AskGate.shouldStart(status: status(lastClientSeen: now - 3_600_000, pushReachable: true), now: now))
    }

    @Test func doesNotStartWhenPushIsNotReachableAndNoRecentPhone() {
        #expect(!AskGate.shouldStart(status: status(pushReachable: false), now: now))
        #expect(!AskGate.shouldStart(status: status(pushReachable: nil), now: now))
        #expect(!AskGate.shouldStart(status: status(lastClientSeen: now - AskGate.clientRecentMs - 1, pushReachable: false), now: now))
        // The recent phone rule is unchanged.
        #expect(AskGate.shouldStart(status: status(lastClientSeen: now - AskGate.clientRecentMs, pushReachable: false), now: now))
    }

    @Test func pushDoesNotOpenTheGateWhenTheAppOrTheBridgeIsNotThere() {
        var off = status(pushReachable: true)
        off.bridgeEnabled = false
        #expect(!AskGate.shouldStart(status: off, now: now))
        var stale = status(pushReachable: true)
        stale.heartbeat = now - AskGate.heartbeatFreshMs - 1
        #expect(!AskGate.shouldStart(status: stale, now: now))
        #expect(!AskGate.shouldStart(status: nil, now: now))
    }

    @Test func waitingIsUnchangedByPush() {
        // Whether push is reachable does not change how long a request waits.
        #expect(AskGate.shouldKeepWaiting(status: status(pushReachable: false), now: now))
        #expect(AskGate.shouldKeepWaiting(status: status(pushReachable: true), now: now))
        var off = status(pushReachable: true)
        off.bridgeEnabled = false
        #expect(!AskGate.shouldKeepWaiting(status: off, now: now))
    }

    @Test func oldAppJsonWithoutTheFieldStillDecodes() throws {
        let old = #"{"pid":7,"visible":true,"heartbeat":5,"version":"1.0","bridgeEnabled":true,"lastClientSeen":4}"#
        let status = try JSONDecoder().decode(AppStatus.self, from: Data(old.utf8))
        #expect(status.pushReachable == nil)
        #expect(status.lastClientSeen == 4)
        let new = try JSONDecoder().decode(AppStatus.self, from: JSONEncoder().encode(self.status(pushReachable: true)))
        #expect(new.pushReachable == true)
    }

    @Test func aTerminalHookStartsOnPushAloneButNotOutsideTheCli() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("critter-askgate-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = CritterPaths(critterHome: base.appendingPathComponent(".critter"), claudeHome: base.appendingPathComponent(".claude"))
        let clock: Int64 = 1_000_000
        try? AppStatusStore(paths: paths).write(AppStatus(
            pid: 1, visible: true, heartbeat: clock, version: "t", bridgeEnabled: true, lastClientSeen: nil, pushReachable: true
        ))
        let input: [String: Any] = [
            "session_id": "s1", "hook_event_name": "PermissionRequest", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "cwd": "/x",
        ]
        let stdin = try! JSONSerialization.data(withJSONObject: input)
        let sleeps = Counter()
        let env = AskEnvironment(
            now: { clock + Int64(sleeps.value) * 200 },
            sleep: { _ in
                sleeps.value += 1
                // Plays the app: the request was published, so take it back.
                if sleeps.value == 1 { PendingStore(paths: paths).remove(requestId: "req-1") }
            },
            ownPid: 4242, newRequestId: { "req-1" }
        )
        // Outside the terminal the gate stays shut, push or not.
        _ = AskCommand.run(stdin: stdin, paths: paths, environment: [:], env: env)
        #expect(sleeps.value == 0)
        // In the terminal it opens on push alone: the request is written and waited on.
        _ = AskCommand.run(stdin: stdin, paths: paths, environment: ["CLAUDE_CODE_ENTRYPOINT": "cli"], env: env)
        #expect(sleeps.value == 1)
    }
}

private final class Counter: @unchecked Sendable {
    var value = 0
}
