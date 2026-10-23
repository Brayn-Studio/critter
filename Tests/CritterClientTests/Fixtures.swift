import CritterKit

// Snapshot pieces for the presentation and store tests (Android `Fixtures.kt`).

func fixtureSession(_ id: String, state: PetState = .idle) -> BridgeSession {
    BridgeSession(
        id: id, name: id, source: .terminal, state: state, cwd: "~", skin: "sprig",
        eventTime: 1, startedAt: 1, tracked: true
    )
}

func fixturePending(
    _ requestId: String, _ sessionId: String, kind: PendingKind = .permission, createdAt: Int64 = 1,
    toolName: String = "Bash", summary: String = "", input: JSONValue = .null
) -> BridgePending {
    BridgePending(
        requestId: requestId, sessionId: sessionId, kind: kind, toolName: toolName, summary: summary,
        input: input, createdAt: createdAt, expiresAt: nil
    )
}

func fixtureBody(_ sessions: [BridgeSession], pending: [BridgePending] = []) -> SnapshotBody {
    SnapshotBody(
        sessions: sessions, pending: pending,
        prefs: BridgePrefs(skin: "sprig", randomSkins: false, idleDim: 1.0, mergeThreshold: 4, soundTheme: "pixel")
    )
}

/// An `AskUserQuestion` input; each pair is the question text and whether it is multi-select.
func questionsInput(_ qs: [(String, Bool)]) -> JSONValue {
    .object(["questions": .array(qs.map { .object(["question": .string($0.0), "multiSelect": .bool($0.1)]) })])
}
