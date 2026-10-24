import CritterClient
import CritterKit
import SwiftUI

/// "proj · main · 终端" as three pieces, each with its pixel icon (Android `PlaceRow`, the mockups' `.meta`): on the
/// home cards and in the sheets' headers. The branch is cut short first; a very long folder stops at 104 pt, so the
/// source stays in view.
struct PlaceRow: View {
    let session: BridgeSession

    /// The widest the folder gets, icon included.
    private static let folderMax: CGFloat = 104

    var body: some View {
        HStack(spacing: 10) {
            CappedWidth(max: Self.folderMax) {
                PlacePiece(icon: .folder, text: SessionText.folderName(session.cwd))
            }
            .layoutPriority(1)
            if let branch = session.branch, !branch.trimmingCharacters(in: .whitespaces).isEmpty {
                PlacePiece(icon: .branch, text: branch)
            }
            let source = SessionText.visibleSource(session)
            PlacePiece(icon: Self.icon(source), text: SessionText.source(source))
                .fixedSize()
                .layoutPriority(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Where a session runs, as an icon: a terminal, the editor, or the computer.
    static func icon(_ source: SessionSource) -> PixelIcon {
        switch source {
        case .terminal, .codexTerminal, .kimiTerminal: .term
        case .vscode, .codexVSCode: .editor
        case .desktop, .other, .codex, .codexDesktop, .kimiDesktop, .deepseekDesktop: .laptop
        }
    }
}

private struct PlacePiece: View {
    let icon: PixelIcon
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            PixelIconView(icon)
            Text(verbatim: text)
                .font(.nunito(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(Theme.ink2)
    }
}

/// Its child at its own width, but never wider than `max` (it is then cut short): `frame(maxWidth:)` would take all of
/// `max` even for a short child.
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = Swift.min(proposal.width ?? max, max)
        return subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: proposal.height)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
