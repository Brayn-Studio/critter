package local.critter.phone.ui.home

import local.critter.phone.ui.board.CardRequest

// The home list's rules, apart from the screen.

/** What a session card offers for its request. */
enum class InlineAnswer {
    /** No request. */
    None,

    /** One permission request: 「拒绝」「允许」 right on the card. */
    AllowDeny,

    /** The same while offline: grey, and a tap sends nothing ("连上后才能作答"). */
    AllowDenyDisabled,

    /** A question, a plan, or more than one request: 「打开回答」 opens the answer card. */
    Open,
}

/**
 * The card answers only a lone permission request in place, and only while [online]; anything else opens the
 * answer card, so a button never acts on a request the card does not show (as on the pro board).
 */
fun inlineAnswer(request: CardRequest?, online: Boolean): InlineAnswer = when {
    request == null -> InlineAnswer.None
    !request.inline -> InlineAnswer.Open
    online -> InlineAnswer.AllowDeny
    else -> InlineAnswer.AllowDenyDisabled
}

/** The opening (Critters popping up) plays once a day: not yet [today], days as `LocalDate.toEpochDay()`. */
fun openingDue(lastShownOn: Long?, today: Long): Boolean = lastShownOn != today
