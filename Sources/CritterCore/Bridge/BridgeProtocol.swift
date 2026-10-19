import Foundation

/// Constants of the LAN bridge between Critter and the Android companion app.
/// `docs/critter-bridge-protocol.md` is the authority for the wire format.
public enum BridgeProtocol {
    public static let version = 1
    public static let maxFrameBytes = 1_048_576
    /// How long `say` text may be once trimmed, in UTF-16 code units (as phones count it).
    public static let maxSayUTF16Units = 4000
    public static let defaultPort: UInt16 = 47823
    public static let portRange: ClosedRange<UInt16> = 47823...47832
    public static let bonjourType = "_critter._tcp"
    /// A phone's name, as the Mac shows and keeps it, has at most this many characters.
    public static let maxDeviceNameChars = 64

    /// `pair.deviceName` as the Mac uses it: it comes off the network, so it is made one line
    /// (control characters become spaces), trimmed and cut to `maxDeviceNameChars`; "手机" if
    /// nothing is left.
    public static func deviceName(_ raw: String) -> String {
        let oneLine = String(String.UnicodeScalarView(raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        }))
        let name = String(oneLine.trimmingCharacters(in: .whitespaces).prefix(maxDeviceNameChars))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "手机" : name
    }
}

public enum DenyReason: String, Codable, Sendable {
    case badToken, badCode, rejected
    /// Wire value is "protocol" (a Swift keyword, hence the case name).
    case protocolMismatch = "protocol"
}

public enum ResultReason: String, Codable, Sendable {
    case resolved, invalid, expired, unavailable, failed
}

public struct BridgeContext: Codable, Equatable, Sendable {
    /// 0...100.
    public var usedPercent: Double
    public var windowSize: Int
    public var estimated: Bool

    public init(usedPercent: Double, windowSize: Int, estimated: Bool) {
        self.usedPercent = usedPercent
        self.windowSize = windowSize
        self.estimated = estimated
    }
}

public struct BridgeSession: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var source: SessionSource
    public var state: PetState
    public var detail: String?
    public var activity: String?
    public var cwd: String
    public var branch: String?
    public var model: String?
    public var context: BridgeContext?
    public var skin: String
    public var eventTime: Int64
    public var startedAt: Int64
    public var tracked: Bool

    public init(
        id: String, name: String, source: SessionSource, state: PetState,
        detail: String? = nil, activity: String? = nil, cwd: String,
        branch: String? = nil, model: String? = nil, context: BridgeContext? = nil,
        skin: String, eventTime: Int64, startedAt: Int64, tracked: Bool
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.state = state
        self.detail = detail
        self.activity = activity
        self.cwd = cwd
        self.branch = branch
        self.model = model
        self.context = context
        self.skin = skin
        self.eventTime = eventTime
        self.startedAt = startedAt
        self.tracked = tracked
    }
}

public struct BridgeLimits: Codable, Equatable, Sendable {
    public var fiveHour: RateWindow?
    public var sevenDay: RateWindow?
    public var updatedAt: Int64

    public init(fiveHour: RateWindow? = nil, sevenDay: RateWindow? = nil, updatedAt: Int64) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.updatedAt = updatedAt
    }
}

public struct BridgePending: Codable, Equatable, Sendable {
    public var requestId: String
    public var sessionId: String
    public var kind: PendingKind
    public var toolName: String
    public var summary: String
    public var input: JSONValue
    public var createdAt: Int64
    public var expiresAt: Int64

    public init(
        requestId: String, sessionId: String, kind: PendingKind, toolName: String,
        summary: String, input: JSONValue, createdAt: Int64, expiresAt: Int64
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.kind = kind
        self.toolName = toolName
        self.summary = summary
        self.input = input
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

public struct BridgePrefs: Codable, Equatable, Sendable {
    public var skin: String
    public var randomSkins: Bool
    public var idleDim: Double
    public var mergeThreshold: Int
    /// A `SoundTheme` raw value.
    public var soundTheme: String

    public init(skin: String, randomSkins: Bool, idleDim: Double, mergeThreshold: Int, soundTheme: String) {
        self.skin = skin
        self.randomSkins = randomSkins
        self.idleDim = idleDim
        self.mergeThreshold = mergeThreshold
        self.soundTheme = soundTheme
    }
}

public struct SnapshotBody: Codable, Equatable, Sendable {
    public var sessions: [BridgeSession]
    public var limits: BridgeLimits?
    public var pending: [BridgePending]
    public var prefs: BridgePrefs

    public init(sessions: [BridgeSession], limits: BridgeLimits? = nil, pending: [BridgePending], prefs: BridgePrefs) {
        self.sessions = sessions
        self.limits = limits
        self.pending = pending
        self.prefs = prefs
    }
}

/// Phone -> Mac. A frame is one WebSocket text message holding a JSON object with a `type`.
public enum ClientMessage: Equatable, Sendable {
    case hello(protocolVersion: Int, deviceId: String, token: String, app: String)
    case pair(code: String, deviceName: String)
    case answer(id: String?, requestId: String, payload: AnswerPayload)
    case seen(id: String?, sessionId: String)
    case say(id: String?, sessionId: String, text: String)
    case skin(id: String?, name: String)

    private struct Wire: Codable {
        var type: String
        var `protocol`: Int?
        var deviceId: String?
        var token: String?
        var app: String?
        var code: String?
        var deviceName: String?
        var id: String?
        var requestId: String?
        var payload: AnswerPayload?
        var sessionId: String?
        var text: String?
        var name: String?
    }

    public static func decode(_ frame: Data) -> ClientMessage? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: frame) else { return nil }
        switch w.type {
        case "hello":
            guard let v = w.protocol, let d = w.deviceId, let t = w.token, let a = w.app else { return nil }
            return .hello(protocolVersion: v, deviceId: d, token: t, app: a)
        case "pair":
            guard let c = w.code, let n = w.deviceName else { return nil }
            return .pair(code: c, deviceName: n)
        case "answer":
            guard let r = w.requestId, let p = w.payload else { return nil }
            return .answer(id: w.id, requestId: r, payload: p)
        case "seen":
            guard let s = w.sessionId else { return nil }
            return .seen(id: w.id, sessionId: s)
        case "say":
            guard let s = w.sessionId, let t = w.text else { return nil }
            return .say(id: w.id, sessionId: s, text: t)
        case "skin":
            guard let n = w.name else { return nil }
            return .skin(id: w.id, name: n)
        default:
            return nil
        }
    }

    public func encode() -> Data {
        var w: Wire
        switch self {
        case .hello(let v, let d, let t, let a):
            w = Wire(type: "hello"); w.protocol = v; w.deviceId = d; w.token = t; w.app = a
        case .pair(let c, let n):
            w = Wire(type: "pair"); w.code = c; w.deviceName = n
        case .answer(let id, let r, let p):
            w = Wire(type: "answer"); w.id = id; w.requestId = r; w.payload = p
        case .seen(let id, let s):
            w = Wire(type: "seen"); w.id = id; w.sessionId = s
        case .say(let id, let s, let t):
            w = Wire(type: "say"); w.id = id; w.sessionId = s; w.text = t
        case .skin(let id, let n):
            w = Wire(type: "skin"); w.id = id; w.name = n
        }
        return encodeWire(w)
    }
}

/// Mac -> phone.
public enum ServerMessage: Equatable, Sendable {
    case welcome(macName: String, version: String)
    case paired(deviceId: String, token: String, macName: String)
    case denied(reason: DenyReason)
    case snapshot(seq: Int, sentAt: Int64, body: SnapshotBody)
    case skin(id: String?, name: String, manifest: JSONValue?)
    case result(id: String?, ok: Bool, reason: ResultReason?, message: String?)

    private struct Wire: Codable {
        var type: String
        var macName: String?
        var version: String?
        var deviceId: String?
        var token: String?
        var reason: String?
        var seq: Int?
        var sentAt: Int64?
        var sessions: [BridgeSession]?
        var limits: BridgeLimits?
        var pending: [BridgePending]?
        var prefs: BridgePrefs?
        var id: String?
        var name: String?
        var manifest: JSONValue?
        var ok: Bool?
        var message: String?
    }

    public func encode() -> Data {
        var w: Wire
        switch self {
        case .welcome(let m, let v):
            w = Wire(type: "welcome"); w.macName = m; w.version = v
        case .paired(let d, let t, let m):
            w = Wire(type: "paired"); w.deviceId = d; w.token = t; w.macName = m
        case .denied(let r):
            w = Wire(type: "denied"); w.reason = r.rawValue
        case .snapshot(let seq, let sentAt, let b):
            w = Wire(type: "snapshot"); w.seq = seq; w.sentAt = sentAt
            w.sessions = b.sessions; w.limits = b.limits; w.pending = b.pending; w.prefs = b.prefs
        case .skin(let id, let n, let manifest):
            w = Wire(type: "skin"); w.id = id; w.name = n; w.manifest = manifest
        case .result(let id, let ok, let r, let m):
            w = Wire(type: "result"); w.id = id; w.ok = ok; w.reason = r?.rawValue; w.message = m
        }
        return encodeWire(w)
    }

    public static func decode(_ frame: Data) -> ServerMessage? {
        guard let w = try? JSONDecoder().decode(Wire.self, from: frame) else { return nil }
        switch w.type {
        case "welcome":
            guard let m = w.macName, let v = w.version else { return nil }
            return .welcome(macName: m, version: v)
        case "paired":
            guard let d = w.deviceId, let t = w.token, let m = w.macName else { return nil }
            return .paired(deviceId: d, token: t, macName: m)
        case "denied":
            guard let r = w.reason.flatMap(DenyReason.init(rawValue:)) else { return nil }
            return .denied(reason: r)
        case "snapshot":
            guard let seq = w.seq, let at = w.sentAt, let s = w.sessions, let p = w.pending, let pr = w.prefs else { return nil }
            return .snapshot(seq: seq, sentAt: at, body: SnapshotBody(sessions: s, limits: w.limits, pending: p, prefs: pr))
        case "skin":
            guard let n = w.name else { return nil }
            return .skin(id: w.id, name: n, manifest: w.manifest)
        case "result":
            guard let ok = w.ok else { return nil }
            return .result(id: w.id, ok: ok, reason: w.reason.flatMap(ResultReason.init(rawValue:)), message: w.message)
        default:
            return nil
        }
    }
}

private func encodeWire<T: Encodable>(_ wire: T) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(wire)) ?? Data()
}
