import CritterCore
import Foundation

// MARK: - BridgeServices (called by `BridgeConnection`, on the bridge queue)

extension BridgeController: BridgeServices {
    var macName: String { computerName }

    func verify(deviceId: String, token: String) -> DeviceRecord? {
        registry.verify(deviceId: deviceId, token: token)
    }

    func consumePairingCode(_ code: String) -> Bool {
        let now = Self.nowMs()
        let consumed: Pairing? = lock.withLock {
            guard let current = pairing, now <= current.code.expiresAt else {
                pairing = nil
                return nil
            }
            guard current.code.code == code.uppercased() else { return nil }
            pairing = nil
            return current
        }
        guard let consumed else { return false }
        approveNextPairing = consumed.autoApprove
        return true
    }

    func pendingRequest(_ requestId: String) -> PendingRequest? {
        pendingStore.read(requestId: requestId)
    }

    /// The request's input as published; question texts are never truncated in it.
    func originalToolInput(_ requestId: String) -> [String: Any]? {
        guard let input = pendingStore.read(requestId: requestId)?.input,
              let data = try? JSONEncoder().encode(input) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func submitAnswer(_ payload: AnswerPayload, requestId: String) -> AnswerOutcome {
        do {
            return try pendingStore.writeAnswer(payload, requestId: requestId) ? .accepted : .alreadyAnswered
        } catch {
            return .failed
        }
    }

    func markSeen(sessionId: String) {
        DispatchQueue.main.async { [weak monitor] in
            // Safe: `DispatchQueue.main` always runs on the main thread/actor.
            MainActor.assumeIsolated { monitor?.markSeen(sessionId) }
        }
    }

    func say(text: String, sessionId: String) -> SayOutcome {
        guard let record = inboxStore.read(sessionId: sessionId) else { return .unavailable }
        do {
            try InboxSender.send(text: text.trimmingCharacters(in: .whitespacesAndNewlines), to: record)
            return .sent
        } catch {
            return .failed
        }
    }

    /// Only plain skin folder names: the name comes off the network, so nothing that could
    /// walk out of the skin directories.
    func skinManifest(name: String) -> JSONValue? {
        guard (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") })
        else { return nil }
        for dir in skinSearchDirs where SkinLoader.find(name: name, searchDirs: [dir]) != nil {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name).appendingPathComponent("manifest.json")),
               let manifest = try? JSONDecoder().decode(JSONValue.self, from: data) {
                return manifest
            }
        }
        guard name.caseInsensitiveCompare(SkinLoader.builtin().name) == .orderedSame else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(SkinLoader.builtinJSON.utf8))
    }

    /// `seq` is a placeholder: `BridgeServer` numbers snapshots per connection.
    func snapshotMessage() -> ServerMessage {
        .snapshot(seq: 0, sentAt: Self.nowMs(), body: buildSnapshot())
    }
}
