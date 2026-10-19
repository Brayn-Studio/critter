package local.critter.phone

import local.critter.phone.onboarding.SeedState.Bud
import local.critter.phone.onboarding.SeedState.Seed
import local.critter.phone.onboarding.SeedState.Sprout
import local.critter.phone.onboarding.Step
import local.critter.phone.onboarding.onboardingSteps
import local.critter.phone.onboarding.seeds
import local.critter.phone.onboarding.stepPosition
import org.junit.jupiter.api.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class OnboardingStepsTest {
    @Test fun seedsSproutBehindTheCurrentOne() {
        assertEquals(listOf(Sprout, Sprout, Bud, Seed, Seed, Seed), seeds(2))
        assertEquals(listOf(Bud, Seed, Seed, Seed, Seed, Seed), seeds(0))
        assertEquals(listOf(Sprout, Sprout, Sprout, Sprout, Bud), seeds(4, total = 5))
    }

    @Test fun welcomeComesFirst() {
        assertEquals(Step.Welcome, onboardingSteps(false, 37).first())
        assertEquals(
            listOf(Step.Welcome, Step.Pair, Step.LocalNetwork, Step.Notifications, Step.Overlay, Step.Battery, Step.KeepAlive),
            onboardingSteps(false, 37),
        )
        assertEquals(listOf(Step.KeepAlive), onboardingSteps(true, 37))
        assertFalse(Step.LocalNetwork in onboardingSteps(false, 33))
        assertTrue(Step.Notifications in onboardingSteps(false, 33))
        assertFalse(Step.Notifications in onboardingSteps(false, 32))
    }

    /** "n / 6" counts the steps after the welcome page only. */
    @Test fun progressLeavesOutTheWelcomePage() {
        val steps = onboardingSteps(false, 37)
        assertNull(stepPosition(steps, Step.Welcome))
        assertEquals(1, stepPosition(steps, Step.Pair)?.number)
        assertEquals(6, stepPosition(steps, Step.KeepAlive)?.number)
        assertEquals(6, stepPosition(steps, Step.Pair)?.total)
        // Android 13: no local network step, so five seeds.
        val older = onboardingSteps(false, 33)
        assertEquals(5, stepPosition(older, Step.KeepAlive)?.total)
        assertEquals(2, stepPosition(older, Step.Notifications)?.number)
    }
}
