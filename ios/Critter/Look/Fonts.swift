import SwiftUI
import UIKit

// The two bundled typefaces (visual design §6). The files are android/app/src/main/res/font/*.ttf, copied into the app
// as they are and listed under UIAppFonts. Chinese falls back to the system font; commands and paths use the
// system's monospaced font.
//
// - Silkscreen (Regular, Bold): numbers — the clock, percentages, counts, the pairing code. Its "%" reads as a z when
//   small: a percentage puts its "%" in Nunito (`Text.percent`).
// - Nunito (a variable font, weights 200–1000, with named instances): English and numbers in body text and titles.
//
// Sizes are the design's dp as points. Like Android's sp they follow the reader's text size (Dynamic Type), relative
// to the body style.

enum Fonts {
    static let silkscreenRegular = "Silkscreen-Regular"
    static let silkscreenBold = "Silkscreen-Bold"

    /// The named instance of Nunito nearest to `weight` (its PostScript name).
    static func nunitoName(_ weight: Int) -> String {
        switch weight {
        case ..<250: "Nunito-ExtraLight"
        case ..<350: "Nunito-Light"
        case ..<450: "Nunito-Regular"
        case ..<550: "Nunito-Medium"
        case ..<650: "Nunito-SemiBold"
        case ..<750: "Nunito-Bold"
        case ..<850: "Nunito-ExtraBold"
        default: "Nunito-Black"
        }
    }

    /// CSS's numeric weight for a SwiftUI weight (Android's `FontWeight.W800` is `.heavy`).
    static func numeric(_ weight: Font.Weight) -> Int {
        switch weight {
        case .ultraLight: 200
        case .thin: 250
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }

    static func numeric(_ weight: UIFont.Weight) -> Int {
        switch weight {
        case .ultraLight: 200
        case .thin: 250
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}

extension Font {
    /// Silkscreen at `size` pt: numbers.
    static func silkscreen(size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? Fonts.silkscreenBold : Fonts.silkscreenRegular, size: size)
    }

    /// Nunito at `size` pt: body text and titles. The design's weights are 600 (`.semibold`), 700 (`.bold`), 800
    /// (`.heavy`) and 900 (`.black`).
    static func nunito(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.nunitoName(Fonts.numeric(weight)), size: size)
    }
}

extension UIFont {
    /// Silkscreen at `size` pt, not scaled with the text size (UIKit drawing).
    static func silkscreen(size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? Fonts.silkscreenBold : Fonts.silkscreenRegular, size: size)
            ?? .monospacedDigitSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    /// Nunito at `size` pt, not scaled with the text size (UIKit drawing).
    static func nunito(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont(name: Fonts.nunitoName(Fonts.numeric(weight)), size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension Text {
    /// A percentage for Silkscreen (`"≈42%"`): its digits stay in `digits`, its other signs ("%", "≈") are in
    /// Nunito at `signSize` (Android `percentText`; Silkscreen's % reads as a z when small).
    static func percent(_ text: String, digits: Font, signSize: CGFloat) -> Text {
        var out = Text(verbatim: "")
        var run = ""
        var runIsDigits = true
        func flush() {
            guard !run.isEmpty else { return }
            out = out + Text(verbatim: run).font(runIsDigits ? digits : .nunito(size: signSize, weight: .heavy))
            run = ""
        }
        for ch in text {
            let isDigit = ch.isASCII && ch.isNumber
            if isDigit != runIsDigits { flush() }
            runIsDigits = isDigit
            run.append(ch)
        }
        flush()
        return out
    }
}
