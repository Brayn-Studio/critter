package local.critter.phone

import kotlinx.serialization.json.JsonObject
import local.critter.core.protocol.BridgeJson
import local.critter.phone.ui.answer.acceptsDenyMessage
import org.junit.jupiter.api.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class CodexApprovalUiTest {
    private fun input(text: String) = BridgeJson.parseToJsonElement(text) as JsonObject

    @Test fun codexApprovalsDoNotOfferAReasonThatCannotBeDelivered() {
        assertFalse(acceptsDenyMessage(input("""{"command":"swift test","acceptsDenyMessage":false}""")))
    }

    @Test fun existingClaudePermissionsKeepTheOptionalReason() {
        assertTrue(acceptsDenyMessage(null))
        assertTrue(acceptsDenyMessage(input("""{"command":"swift test"}""")))
        assertTrue(acceptsDenyMessage(input("""{"acceptsDenyMessage":true}""")))
    }
}
