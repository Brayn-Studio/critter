package local.critter.phone.onboarding

/** One seed of the onboarding's progress row: still a seed, the current step's bud, or a step done (a sprout). */
enum class SeedState { Seed, Bud, Sprout }

/** The progress row for step [current] (from 0) of [total]: sprouts behind it, its bud, seeds ahead. */
fun seeds(current: Int, total: Int = 6): List<SeedState> = List(total) { i ->
    when {
        i < current -> SeedState.Sprout
        i == current -> SeedState.Bud
        else -> SeedState.Seed
    }
}

/** The onboarding's pages, in order: the welcome page, pairing, the permissions one at a time, the brand's keep-alive steps. */
enum class Step { Welcome, Pair, LocalNetwork, Notifications, Overlay, Battery, KeepAlive }

/**
 * The pages to walk through on Android [sdk]. With [onlyKeepAlive] (the "保持后台运行" entry in the settings) just
 * that one; otherwise all of them, without the local network step before API 37 or notifications before API 33.
 */
fun onboardingSteps(onlyKeepAlive: Boolean, sdk: Int): List<Step> =
    if (onlyKeepAlive) {
        listOf(Step.KeepAlive)
    } else {
        Step.entries.filter { it != Step.LocalNetwork || sdk >= 37 }.filter { it != Step.Notifications || sdk >= 33 }
    }

/** "[number] / [total]" over a step. */
data class StepPosition(val number: Int, val total: Int)

/** Where [step] is in [steps], not counting the welcome page (which has no number); null for the welcome page. */
fun stepPosition(steps: List<Step>, step: Step): StepPosition? {
    val counted = steps.filter { it != Step.Welcome }
    val i = counted.indexOf(step)
    return if (i < 0) null else StepPosition(i + 1, counted.size)
}
