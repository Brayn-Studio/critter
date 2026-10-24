import Foundation

/// One page of the first-run guide (spec §8.8, visual design §8.2; Android `Step`), by the name
/// `-critterOnboarding` takes.
public enum OnboardingStep: String, CaseIterable, Sendable {
    /// What the app is for, and the way in.
    case welcome
    /// The pairing screens inside the step's frame. The system's local network prompt comes with the first
    /// connection, so it has no page of its own.
    case pair
    /// The system's permission to show notifications.
    case notifications
    /// What the Live Activity is (the lock screen and the Dynamic Island), and that it can be switched off.
    case liveActivity
    /// The Shortcuts automation that opens the app on the charger, so the board comes up by itself (spec §8.6).
    case board
}

/// One seed of the guide's progress row (Android `SeedState`): still a seed, the current step's bud, or a step done
/// (a sprout).
public enum SeedState: Equatable, Sendable {
    case seed, bud, sprout
}

/// "n / total" over a step.
public struct StepPosition: Equatable, Sendable {
    public var number: Int
    public var total: Int

    public init(number: Int, total: Int) {
        self.number = number
        self.total = total
    }

    /// "3 / 5".
    public var text: String { "\(number) / \(total)" }
}

/// The guide's order and progress (Android `onboardingSteps`, `seeds`, `stepPosition`), apart from the screens.
public enum OnboardingSteps {
    /// The pages in order: every one of them, on every phone (iOS asks for nothing else up front).
    public static let all: [OnboardingStep] = OnboardingStep.allCases

    /// Where `step` is, "n / 5" (spec §8.8): the welcome page is the first of the five, though it shows no seeds (the
    /// mockups' welcome page has none), so the pairing step reads "2 / 5" with the welcome page's seed sprouted.
    public static func position(of step: OnboardingStep) -> StepPosition {
        StepPosition(number: (all.firstIndex(of: step) ?? 0) + 1, total: all.count)
    }

    /// The row for `position`: sprouts for the steps behind it, the bud for it, seeds for the steps ahead.
    public static func seeds(_ position: StepPosition) -> [SeedState] {
        (1...max(position.total, 1)).map { n in
            if n < position.number { return .sprout }
            return n == position.number ? .bud : .seed
        }
    }

    /// The page after `step`: where its main button and its 「跳过」 both go (skipping only leaves out what the step
    /// would have set up). Nil after the last: the guide is done.
    public static func next(after step: OnboardingStep) -> OnboardingStep? {
        guard let i = all.firstIndex(of: step), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    /// The page before `step` (「返回」 on the scanner); nil for the welcome page.
    public static func previous(before step: OnboardingStep) -> OnboardingStep? {
        guard let i = all.firstIndex(of: step), i > 0 else { return nil }
        return all[i - 1]
    }

    /// Whether the app starts in the guide: not paired, and not through it yet (`onboardingDone`). A phone paired
    /// already goes straight to the home screen; the settings' 「重新走一遍引导」 opens it again by hand.
    public static func showsAtLaunch(paired: Bool, done: Bool) -> Bool {
        !paired && !done
    }
}
