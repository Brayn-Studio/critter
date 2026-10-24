import CritterClient
import CritterKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

// What both board modes share (Android `BoardChrome.kt`, `BoardLook.kt`): the board's line height, the dim meters,
// the board's buttons, and everything about the screen rather than the content: the brightness, staying on, the
// idle dimming and the touches it counts from (spec §9).

/// What the board shows: the latest data and how fresh it is (Android `BoardData`; the time is read where it is
/// shown, once a minute).
struct BoardData {
    var snapshot: SnapshotBody?
    /// Connected to the Mac right now.
    var connected: Bool
    /// When `snapshot` came.
    var updatedAt: Date?

    /// The orange line under the clock while the Mac is out of reach: "未连接 · 5 分钟前".
    func offlineText(now: Date) -> String {
        "未连接" + (updatedAt.map { " · \(SessionText.ago($0, now: now))" } ?? "")
    }
}

// MARK: - Lines

/// The board's type: its lines are 1.7 times their text (the mockups' board sits outside `.app` and keeps the page's
/// 15px/1.7), and the clock's Silkscreen digits stand on lines exactly as tall as they are (`line-height: 1`).
enum BoardType {
    static let line: CGFloat = 1.7
    /// How tall a line of Nunito and of Silkscreen is, in multiples of the size (what SwiftUI gives a `Text`).
    static let nunitoLine = UIFont.nunito(size: 100).lineHeight / 100
    static let silkscreenLine = UIFont.silkscreen(size: 100).lineHeight / 100

    /// `size` as the reader's text size makes it (the fonts follow Dynamic Type relative to the body style).
    static func scaled(_ size: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
    }
}

extension View {
    /// Nunito text on the board's 1.7 lines.
    func boardLines() -> some View {
        CSSLine(factor: BoardType.line / BoardType.nunitoLine) { self }
    }

    /// Silkscreen digits on lines as tall as their size (CSS `line-height: 1`): they stick out evenly above and below.
    func pixelDigitLine() -> some View {
        CSSLine(factor: 1 / BoardType.silkscreenLine) { self }
    }
}

/// Its child's lines `factor` times as tall as the font makes them, the text centred in that room as CSS's
/// half-leading does (Android `cssLine`): the board's clock would otherwise stand low and push the date into the
/// first bubble. Keeps following the text size, since it scales what the text measures.
struct CSSLine: Layout {
    var factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: (size.height * factor).rounded())
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        child.place(
            at: CGPoint(x: bounds.minX, y: (bounds.midY - size.height / 2).rounded()),
            proposal: ProposedViewSize(width: bounds.width, height: size.height)
        )
    }
}

// MARK: - Meters and buttons

/// A flat, dim meter in the board's colours (Android `BoardMeter`): `percent` of 100 in `segments` cells.
struct BoardMeter: View {
    let percent: Double?
    let segments: Int
    let height: CGFloat

    var body: some View {
        SegmentMeter(fraction: percent.map { $0 / 100 }, segments: segments, height: height, board: true)
    }
}

/// The board's 40 pt square buttons at the top right (Android `BoardModeButton`, the mockups' `.bmode`): the mode
/// switch and, on iOS, the way out. A dim icon on the bubbles' dark face; pressed, it sinks 3 pt in one step.
struct BoardIconButton: View {
    let icon: PixelIcon
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PixelIconView(icon)
                .frame(width: 40, height: 40)
        }
        .buttonStyle(BoardIconButtonStyle())
        .accessibilityLabel(Text(verbatim: label))
    }
}

private struct BoardIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressedLook(pressed: configuration.isPressed) { down in
            configuration.label
                .foregroundStyle(Theme.Board.dim)
                .background(Theme.Board.card2, in: PixelShape(step: 3))
                .offset(y: down ? 3 : 0)
        }
        .frame(width: minTouch, height: minTouch)
        .contentShape(Rectangle())
    }
}

// MARK: - The screen

/// What the board does to the screen while it is up (spec §8.6, §9; Android `BoardLook.kt`): the brightness is set to
/// the setting's, and lowered once nothing has happened for 15 minutes (`BoardScreen.brightness`, counted from the
/// last touch and the last change on the Mac); the screen is kept from locking. Every way out (`BoardScreen.Exit`)
/// brings back the brightness saved on the way in and lets the screen lock again (`BoardScreen.restore`). Leaving the
/// front (inactive, or the background) is one of them; coming back to the front saves the screen again and sets it
/// again.
///
/// One for the home screen's life: the board view enters and leaves it, and so does whoever closes the board.
@MainActor
final class BoardScreenKeeper {
    /// The screen as the board found it; nil while the board does not hold the screen.
    private var saved: ScreenState?
    /// The setting's brightness.
    private var base = 0.3
    private var lastTouch: Date?
    /// When what the board shows last changed.
    private var idleSince: Date?
    /// The brightness last set.
    private var shown: Double?
    /// Wakes up when the board is due to dim.
    private var dimTask: Task<Void, Never>?
    /// How long without a touch or a change before the board dims (`-critterBoardDimAfter` shortens it).
    private let idleAfter: TimeInterval

    init() {
        #if DEBUG
        idleAfter = DebugLaunch.current.boardDimAfter ?? BoardScreen.idleDimAfter
        #else
        idleAfter = BoardScreen.idleDimAfter
        #endif
    }

    /// Whether the board holds the screen now.
    var holdsScreen: Bool { saved != nil }

    /// Saves the screen as it is and makes it the board's: `base` brightness, kept on. Nothing if it already is.
    func enter(base: Double) {
        self.base = base
        guard saved == nil else { return }
        let screen = Self.screen
        let before = ScreenState(
            brightness: screen.map { Double($0.brightness) } ?? 1,
            idleTimerDisabled: UIApplication.shared.isIdleTimerDisabled
        )
        saved = before
        let now = Date()
        idleSince = now
        lastTouch = nil
        shown = nil
        UIApplication.shared.isIdleTimerDisabled = true
        boardLog(
            "enter: saved brightness \(Self.text(before.brightness)), isIdleTimerDisabled \(before.idleTimerDisabled)"
                + " → isIdleTimerDisabled true"
        )
        refresh(now: now)
    }

    /// The setting's brightness changed while the board is up.
    func setBase(_ base: Double) {
        self.base = base
        guard saved != nil else { return }
        refresh(now: Date())
    }

    /// A finger touched the screen: the board is bright again.
    func touched() {
        guard saved != nil else { return }
        lastTouch = Date()
        refresh(now: Date())
    }

    /// What the board shows changed (a session's state, a request): that counts as activity too.
    func changed() {
        guard saved != nil else { return }
        idleSince = Date()
        refresh(now: Date())
    }

    /// Gives the screen back as it was saved, left by `exit`. Nothing if the board does not hold it.
    func leave(_ exit: BoardScreen.Exit) {
        guard let before = saved else { return }
        saved = nil
        shown = nil
        dimTask?.cancel()
        dimTask = nil
        let after = BoardScreen.restore(saved: before, on: exit)
        Self.screen?.brightness = CGFloat(after.brightness)
        UIApplication.shared.isIdleTimerDisabled = after.idleTimerDisabled
        boardLog(
            "leave \(exit): brightness \(Self.text(after.brightness)) (saved \(Self.text(before.brightness))),"
                + " isIdleTimerDisabled \(after.idleTimerDisabled) (idle timer off)"
        )
    }

    /// Sets the brightness due now and wakes up again when it is due to dim.
    private func refresh(now: Date) {
        let skew = BoardScreen.idleDimAfter - idleAfter
        let brightness = BoardScreen.brightness(
            base: base, idleSince: idleSince, lastTouch: lastTouch, now: now.addingTimeInterval(skew)
        )
        if brightness != shown {
            shown = brightness
            Self.screen?.brightness = CGFloat(brightness)
            let read = Self.screen.map { Self.text(Double($0.brightness)) } ?? "-"
            boardLog("brightness \(Self.text(brightness))\(brightness < base ? " (idle)" : "") (reads back \(read))")
        }
        dimTask?.cancel()
        dimTask = nil
        // Not idle yet: wake up once it is (a touch or a change before then puts the wake-up off).
        guard let last = [idleSince, lastTouch].compactMap({ $0 }).max() else { return }
        let wait = last.addingTimeInterval(idleAfter).timeIntervalSince(now)
        guard wait > 0 else { return }
        dimTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            self?.refresh(now: Date())
        }
    }

    /// The screen the app is on.
    private static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    private static func text(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

/// Every touch that starts anywhere in the window, told without taking part in it: a recognizer on the window that
/// fails at once, so the board, its Critters and its buttons get their touches as before. The board dims 15 minutes
/// after the last one.
struct TouchWatch: UIViewRepresentable {
    let onTouch: () -> Void

    func makeUIView(context: Context) -> WatchView {
        let view = WatchView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WatchView, context: Context) {
        view.onTouch = onTouch
    }

    final class WatchView: UIView {
        var onTouch: () -> Void = {}
        private lazy var recognizer = Recognizer { [weak self] in self?.onTouch() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }
    }

    private final class Recognizer: UIGestureRecognizer {
        private let onTouch: () -> Void

        init(onTouch: @escaping () -> Void) {
            self.onTouch = onTouch
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            onTouch()
            state = .failed
        }

        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    }
}

/// The window's safe area, told whenever it changes (a SwiftUI view that ignores the safe area reads none of it).
struct SafeAreaReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: UIView {
        var onChange: (UIEdgeInsets) -> Void = { _ in }
        private var told: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tell()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            tell()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            tell()
        }

        /// Outside SwiftUI's update: the new insets change its state.
        private func tell() {
            guard let insets = window?.safeAreaInsets, insets != told else { return }
            told = insets
            DispatchQueue.main.async { [weak self] in self?.onChange(insets) }
        }
    }
}

/// `-critterBoardLog` (DEBUG builds): one line on standard output for each thing the board does to the screen, each
/// sound it plays and each step of the automatic opening (`BoardLog`). Nothing in a release build.
func boardLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    BoardLog.write(message())
    #endif
}
