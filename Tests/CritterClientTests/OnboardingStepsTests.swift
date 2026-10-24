import CritterClient
import Testing

struct OnboardingStepsTests {
    @Test func theStepsComeInTheSpecsOrder() {
        #expect(OnboardingSteps.all == [.welcome, .pair, .notifications, .liveActivity, .board])
    }

    /// "n / 5": the welcome page is the first of the five (it shows no seeds), so pairing is the second.
    @Test func eachStepHasItsNumberOutOfFive() {
        #expect(OnboardingSteps.all.map { OnboardingSteps.position(of: $0) } == [
            StepPosition(number: 1, total: 5), StepPosition(number: 2, total: 5), StepPosition(number: 3, total: 5),
            StepPosition(number: 4, total: 5), StepPosition(number: 5, total: 5),
        ])
        #expect(OnboardingSteps.position(of: .notifications).text == "3 / 5")
    }

    /// Sprouts behind, the bud for this step, seeds ahead.
    @Test func theSeedsSproutBehindAndBudAtTheStep() {
        #expect(OnboardingSteps.seeds(StepPosition(number: 1, total: 5)) == [.bud, .seed, .seed, .seed, .seed])
        #expect(OnboardingSteps.seeds(StepPosition(number: 3, total: 5)) == [.sprout, .sprout, .bud, .seed, .seed])
        #expect(OnboardingSteps.seeds(StepPosition(number: 5, total: 5)) == [.sprout, .sprout, .sprout, .sprout, .bud])
        #expect(OnboardingSteps.seeds(OnboardingSteps.position(of: .pair)) == [.sprout, .bud, .seed, .seed, .seed])
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
