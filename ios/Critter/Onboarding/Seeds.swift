import CritterClient
import SwiftUI

/// The five seeds over a step (visual design §8.2, Android `SeedRow`): sprouted (green) for the steps behind, a bud
/// (brand) for this one, seeds (grey) for the steps ahead, 3 pt a cell, and "n / 5" beside them in Silkscreen. Read
/// out as one line, "第 n 步，共 5 步". On the dark scanner page the colours come from its dark theme.
struct SeedRow: View {
    let position: StepPosition

    var body: some View {
        HStack {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(OnboardingSteps.seeds(position).enumerated()), id: \.offset) { _, seed in
                    switch seed {
                    case .sprout: PixelIconView(.sprout, cell: 3).foregroundStyle(Theme.doneGlyph)
                    case .bud: PixelIconView(.bud, cell: 3).foregroundStyle(Theme.brand)
                    case .seed: PixelIconView(.seed, cell: 3).foregroundStyle(Theme.ink3)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: position.text)
                .font(.silkscreen(size: 13))
                .foregroundStyle(Theme.ink2)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "第 \(position.number) 步，共 \(position.total) 步"))
    }
}
