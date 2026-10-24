import Foundation

/// What a session card offers for its request (Android `InlineAnswer`).
public enum InlineAnswer: Equatable, Sendable {
    /// No request.
    case none
    /// One permission request: 「拒绝」「允许」 right on the card.
    case allowDeny
    /// The same while the phone cannot act: grey, and a tap sends nothing ("连上后才能作答").
    case allowDenyDisabled
    /// A question, a plan, or more than one request: 「打开回答」 opens the answer card.
    case open
}

/// The home list's rules, apart from the screen (Android `HomeList.kt`).
public enum HomeRules {
    /// The card answers only a lone permission request in place, and only while the phone can act (`canAct`:
    /// connected); anything else opens the answer card, so a button never acts on a request the card does not
    /// show (as on the pro board).
    public static func inlineAnswer(request: CardRequest?, canAct: Bool) -> InlineAnswer {
        guard let request else { return .none }
        if !request.isInline { return .open }
        return canAct ? .allowDeny : .allowDenyDisabled
    }

    /// The opening (Critters popping up) plays once a day: not yet `today`, days as days since 1970-01-01.
    public static func shouldPlayOpening(lastShownDay: Int?, today: Int) -> Bool {
        lastShownDay != today
    }
}
