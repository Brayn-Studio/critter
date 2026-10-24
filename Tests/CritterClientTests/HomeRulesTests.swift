import CritterKit
import Testing
@testable import CritterClient

private func card(_ kind: PendingKind, more: Int = 0) -> CardRequest {
    CardRequest(request: fixturePending("r1", "a", kind: kind), what: "想 运行 ls", detail: nil, more: more)
}

/// Offline, the buttons are there but grey: a tap sends nothing (review focus 5).
@Test func inlineAnswerNeedsConnection() {
    #expect(HomeRules.inlineAnswer(request: card(.permission), canAct: true) == .allowDeny)
    #expect(HomeRules.inlineAnswer(request: card(.permission), canAct: false) == .allowDenyDisabled)
}

@Test func questionsAndPlansOpenTheCard() {
    #expect(HomeRules.inlineAnswer(request: card(.question), canAct: true) == .open)
    #expect(HomeRules.inlineAnswer(request: card(.plan), canAct: true) == .open)
    // Two permission requests: the buttons would act on one the card does not show.
    #expect(HomeRules.inlineAnswer(request: card(.permission, more: 1), canAct: true) == .open)
    #expect(HomeRules.inlineAnswer(request: card(.question), canAct: false) == .open)
    #expect(HomeRules.inlineAnswer(request: nil, canAct: true) == .none)
    #expect(HomeRules.inlineAnswer(request: nil, canAct: false) == .none)
}

@Test func openingOncePerDay() {
    #expect(HomeRules.shouldPlayOpening(lastShownDay: nil, today: 100))
    #expect(!HomeRules.shouldPlayOpening(lastShownDay: 100, today: 100))
    #expect(HomeRules.shouldPlayOpening(lastShownDay: 99, today: 100))
}

/// The settings keep the opening's day as "yyyy-MM-dd"; the rule compares days since 1970-01-01.
@Test func aDayIsCountedFrom1970() {
    #expect(HomeRules.dayNumber("1970-01-01") == 0)
    #expect(HomeRules.dayNumber("1970-01-02") == 1)
    #expect(HomeRules.dayNumber("2026-10-24") == 20_750)
    #expect(HomeRules.dayNumber("2024-02-29") == 19_782)
    #expect(HomeRules.dayNumber(nil) == nil)
    #expect(HomeRules.dayNumber("") == nil)
    #expect(HomeRules.dayNumber("2026-10") == nil)
    #expect(HomeRules.dayNumber("tomorrow") == nil)
}
