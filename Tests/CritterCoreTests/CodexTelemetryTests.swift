import Foundation
import Testing
@testable import CritterCore

@Test func codexTelemetryUsesLastResponseRatherThanCumulativeUsage() {
    let context: [String: Any] = [
        "type": "turn_context", "payload": ["model": "gpt-6-sol", "model_context_window": 258_400],
    ]
    let initial = CodexTelemetry.updated(from: context, previous: nil)
    let event: [String: Any] = [
        "type": "event_msg", "payload": ["type": "token_count", "info": [
            "total_token_usage": ["total_tokens": 1_000_000],
            "last_token_usage": ["input_tokens": 20_000, "cached_input_tokens": 10_000,
                                 "output_tokens": 5_840, "reasoning_output_tokens": 2_000, "total_tokens": 25_840],
            "model_context_window": 258_400,
        ]],
    ]
    let result = CodexTelemetry.updated(from: event, previous: initial)
    #expect(result?.model == "gpt-6-sol")
    #expect(result?.usedTokens == 25_840)
    #expect(result?.contextWindow == 258_400)
}

@Test func codexTelemetryReadsCurrentResponseRecordAndThreadSettings() {
    let usage: [String: Any] = [
        "type": "token_usage_record", "payload": [
            "usage": ["input_tokens": 11_000, "output_tokens": 1_000, "total_tokens": 12_000],
            "turn_token_usage": ["total_tokens": 90_000], "thread_token_usage": ["total_tokens": 900_000],
        ],
    ]
    let initial = CodexTelemetry.updated(from: usage, previous: nil)
    let settings: [String: Any] = [
        "type": "event_msg", "payload": ["type": "thread_settings_applied", "thread_settings": ["model": "gpt-6-astra"]],
    ]
    let result = CodexTelemetry.updated(from: settings, previous: initial)
    #expect(result?.model == "gpt-6-astra")
    #expect(result?.usedTokens == 12_000)
    #expect(result?.contextWindow == nil)
}

@Test func codexTelemetryDoesNotTreatContextIdentityAsSizeOrInventUsage() {
    let metadata: [String: Any] = [
        "type": "session_meta", "payload": ["context_window": ["window_id": "identity-only"]],
    ]
    #expect(CodexTelemetry.updated(from: metadata, previous: nil) == nil)
    let started: [String: Any] = [
        "type": "event_msg", "payload": ["type": "turn_started", "model_context_window": 128_000],
    ]
    let result = CodexTelemetry.updated(from: started, previous: nil)
    #expect(result?.contextWindow == 128_000)
    #expect(result?.usedTokens == nil)
    let cumulativeOnly: [String: Any] = [
        "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": 999_000]]],
    ]
    #expect(CodexTelemetry.updated(from: cumulativeOnly, previous: result) == result)
}

@Test func codexTelemetryPreservesKnownValuesAcrossUnknownAndInvalidEvents() {
    let previous = CodexTelemetry(model: "gpt-6-sol", usedTokens: 12, contextWindow: 100)
    #expect(CodexTelemetry.updated(from: ["type": "future_event", "payload": ["model": "wrong"]], previous: previous) == previous)
    let invalid: [String: Any] = [
        "type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["total_tokens": -1], "model_context_window": 0,
        ]],
    ]
    #expect(CodexTelemetry.updated(from: invalid, previous: previous) == previous)
    let zero: [String: Any] = [
        "type": "event_msg", "payload": ["type": "token_count", "info": ["last_token_usage": ["total_tokens": 0]]],
    ]
    #expect(CodexTelemetry.updated(from: zero, previous: previous)?.usedTokens == 0)
}

@Test func codexTelemetryMapsOnlyKnownRateWindowDurationsAndConvertsResetSeconds() {
    let event: [String: Any] = [
        "type": "event_msg", "timestamp": "2026-10-20T00:00:00Z",
        "payload": ["type": "token_count", "rate_limits": [
            "normal_model_slug": "quota-alias-not-the-request-model",
            "primary": ["used_percent": 31.5, "window_minutes": 300, "resets_at": 1_800_000_000],
            "secondary": ["used_percent": 42, "window_minutes": 10_080, "resets_at": 1_800_010_000],
        ]],
    ]
    let result = CodexTelemetry.updated(from: event, previous: nil)
    #expect(result?.model == nil)
    #expect(result?.fiveHour == RateWindow(usedPercentage: 31.5, resetsAt: 1_800_000_000_000))
    #expect(result?.sevenDay == RateWindow(usedPercentage: 42, resetsAt: 1_800_010_000_000))
    #expect(result?.limitsUpdatedAt == 1_792_454_400_000)
    let other: [String: Any] = [
        "type": "event_msg", "payload": ["type": "token_count", "rate_limits": [
            "primary": ["used_percent": 20, "window_minutes": 60, "resets_at": 1_800_000_000],
        ]],
    ]
    let changed = CodexTelemetry.updated(from: other, previous: result)
    #expect(changed?.fiveHour == nil)
    #expect(changed?.sevenDay == nil)
    #expect(changed?.limitsUpdatedAt == nil)
}

@Test func codexTelemetryRecordRoundTripsAndLegacyRecordStillDecodes() throws {
    let record = SessionRecord(
        schema: 1, sessionId: "codex-test", cwd: "/project", transcriptPath: nil, state: .idle,
        detail: nil, lastEvent: "Codex:token_count", eventTime: 1, createdAt: 1,
        claudePid: nil, claudeStartTime: nil,
        telemetry: CodexTelemetry(model: "gpt-6-sol", usedTokens: 20, contextWindow: 100)
    )
    let encoded = try JSONEncoder().encode(record)
    #expect(try JSONDecoder().decode(SessionRecord.self, from: encoded) == record)
    var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    legacy.removeValue(forKey: "telemetry")
    let decoded = try JSONDecoder().decode(SessionRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.telemetry == nil)
    #expect(decoded.sessionId == "codex-test")
}
