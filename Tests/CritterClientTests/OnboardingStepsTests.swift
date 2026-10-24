import CritterClient
import Testing

struct OnboardingStepsTests {
    @Test func theStepsComeInTheSpecsOrder() {
        #expect(OnboardingSteps.all == [.welcome, .pair, .notifications, .liveActivity, .board])
    }

    /// "n / 4": the welcome page is not counted (it has no seeds), so pairing is the first of four.
    @Test func eachStepAfterTheWelcomePageHasItsNumberOutOfFour() {
        #expect(OnboardingSteps.position(of: .welcome) == nil)
        #expect(OnboardingSteps.numbered.map { OnboardingSteps.position(of: $0) } == [
            StepPosition(number: 1, total: 4), StepPosition(number: 2, total: 4), StepPosition(number: 3, total: 4),
            StepPosition(number: 4, total: 4),
        ])
        #expect(OnboardingSteps.numbered == [.pair, .notifications, .liveActivity, .board])
        #expect(OnboardingSteps.position(of: .pair)?.text == "1 / 4")
        #expect(OnboardingSteps.position(of: .notifications)?.text == "2 / 4")
    }

    /// Sprouts behind, the bud for this step, seeds ahead: four seeds, the first a bud on the pairing step.
    @Test func theSeedsSproutBehindAndBudAtTheStep() {
        #expect(OnboardingSteps.seeds(StepPosition(number: 1, total: 4)) == [.bud, .seed, .seed, .seed])
        #expect(OnboardingSteps.seeds(StepPosition(number: 3, total: 4)) == [.sprout, .sprout, .bud, .seed])
        #expect(OnboardingSteps.seeds(StepPosition(number: 4, total: 4)) == [.sprout, .sprout, .sprout, .bud])
        #expect(OnboardingSteps.position(of: .pair).map(OnboardingSteps.seeds) == [.bud, .seed, .seed, .seed])
        #expect(OnboardingSteps.position(of: .board).map(OnboardingSteps.seeds) == [.sprout, .sprout, .sprout, .bud])
    }

    /// Skipping a step goes where its main button goes: the next one; past the last the guide is done.
    @Test func skippingGoesOnToTheNextStep() {
        #expect(OnboardingSteps.next(after: .welcome) == .pair)
        #expect(OnboardingSteps.next(after: .pair) == .notifications)
        #expect(OnboardingSteps.next(after: .notifications) == .liveActivity)
        #expect(OnboardingSteps.next(after: .liveActivity) == .board)
        #expect(OnboardingSteps.next(after: .board) == nil)
    }

    /// 「返回」 on the scanner goes back to the welcome page; there is nothing before it.
    @Test func backGoesToTheStepBefore() {
        #expect(OnboardingSteps.previous(before: .pair) == .welcome)
        #expect(OnboardingSteps.previous(before: .board) == .liveActivity)
        #expect(OnboardingSteps.previous(before: .welcome) == nil)
    }

    /// Only a phone that is not paired and has not been through the guide starts in it: one paired already (an
    /// update, the simulator's state) goes straight to the home screen.
    @Test func theGuideShowsOnlyOnAFirstRun() {
        #expect(OnboardingSteps.showsAtLaunch(paired: false, done: false))
        #expect(!OnboardingSteps.showsAtLaunch(paired: true, done: false))
        #expect(!OnboardingSteps.showsAtLaunch(paired: false, done: true))
        #expect(!OnboardingSteps.showsAtLaunch(paired: true, done: true))
    }

    /// `-critterOnboarding <step>` names the steps by these.
    @Test func stepsGoByTheirNames() {
        #expect(OnboardingStep(rawValue: "liveActivity") == .liveActivity)
        #expect(OnboardingStep.allCases.map(\.rawValue) == ["welcome", "pair", "notifications", "liveActivity", "board"])
    }
}
