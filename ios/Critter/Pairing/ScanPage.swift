import CritterClient
import CritterKit
import SwiftUI

/// The scanner page (mockup "扫码", Android `ScanPane`): dark in either theme, the camera showing through a 248 pt
/// viewfinder with pixel corners (or, where there is no camera, why not), the rest of the page dimmed around it, and
/// Sprig under the frame looking up at it. When a pairing code is read the frame turns green and Sprig hops (`flash`,
/// for six beats); the pairing screen starts pairing after that. Under the instructions, the line about a Mac left
/// without being told (`LeftMacNotice`), while there is one: in the guide's pairing step too, and on the pairing
/// screen's other pages.
struct ScanPage: View {
    /// Why a code or a link could not be used.
    let note: String?
    let flash: Bool
    /// A QR code the camera read; returns whether to keep scanning.
    let onCode: @MainActor (String) -> Bool
    let onManual: () -> Void
    /// 「返回」, when there is a home screen to go back to.
    let onClose: (() -> Void)?
    /// Sprig's stage (`LonePet.petId`), for the hop.
    let control: CritterStageControl
    /// In the first-run guide: the seeds on top, 「跳过」 beside 「返回」, and what skipping costs under them.
    var position: StepPosition?
    var onSkip: (() -> Void)?
    var skipNote: String?

    /// Where the viewfinder is on screen (global), for the dimming around it.
    @State private var window: CGRect?

    static let side: CGFloat = 248
    /// The words on the dark page under the title (the mockup's #C9C2E0, 11:1 on it).
    static let mutedInk = Color(rgb: 0xC9C2E0)

    var body: some View {
        VStack(spacing: 0) {
            if let position {
                SeedRow(position: position)
                    .padding(.top, 8)
            }
            ScrollView {
                VStack(spacing: 0) {
                    StepTitle(text: "扫 Mac 上的二维码")
                    // Sprig stands 24 pt below the frame, its head reaching up into the frame's bottom edge.
                    ZStack(alignment: .top) {
                        Viewfinder(flash: flash, onCode: onCode)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { window = $0 }
                        LookingUp(control: control)
                            .frame(width: Self.side, height: LookingUp.height)
                            .offset(y: Self.side + 24 - LookingUp.height)
                    }
                    .frame(width: Self.side, height: Self.side + 24, alignment: .top)
                    .padding(.top, 28)
                    StepBody(
                        text: "在 Mac 上打开 Critter 的「设置…」，打开「允许手机连接」，点「添加手机…」，把出现的二维码放进框里。",
                        color: Self.mutedInk, alignment: .center
                    )
                    .padding(.horizontal, 4)
                    .padding(.top, 18)
                    // A Mac left without being told may still push here: said here too, where an unpaired phone
                    // stays (the settings are out of reach).
                    LeftMacNotice(inset: 0, above: 8)
                    if let note {
                        ErrorNote(text: note)
                            .padding(.top, 14)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 8) {
                PixelButton(title: "手动输入", style: .secondary, icon: .keys, wide: true, action: onManual)
                if onClose != nil || onSkip != nil {
                    HStack(spacing: 0) {
                        if let onClose { ghost("返回", action: onClose) }
                        if let onSkip { ghost("跳过", action: onSkip) }
                    }
                }
                if onSkip != nil, let skipNote {
                    SkipNote(text: skipNote, color: Self.mutedInk)
                }
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, stepGutter)
        .background { ScanBackdrop(window: window) }
        .environment(\.colorScheme, .dark)
        // Light status bar icons over the dark page; the other pages follow the system again.
        .preferredColorScheme(.dark)
    }
}

extension ScanPage {
    /// A text button in the page's muted ink (the mockup's 「返回」), sharing the row with the other evenly.
    private func ghost(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: title).foregroundStyle(Self.mutedInk)
        }
        .buttonStyle(PixelButtonStyle(style: .text))
        .frame(maxWidth: .infinity)
    }
}

/// The page behind the viewfinder (the mockup's `#scan-cam`): a dark glow centred on the frame, dimmed everywhere
/// but inside it, where the camera shows through.
private struct ScanBackdrop: View {
    let window: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let page = proxy.frame(in: .global)
            let size = proxy.size
            let hole = window?.offsetBy(dx: -page.minX, dy: -page.minY)
            let center = hole.map { CGPoint(x: $0.midX, y: $0.midY) }
                ?? CGPoint(x: size.width / 2, y: size.height * 0.375)
            let reach = 300 * max(size.width, 1) / 360
            ZStack(alignment: .topLeading) {
                RadialGradient(
                    stops: [
                        .init(color: Color(rgb: 0x3A3552), location: 0),
                        .init(color: Color(rgb: 0x1C1928), location: 0.6),
                        .init(color: Color(rgb: 0x0F0D16), location: 1),
                    ],
                    center: UnitPoint(x: center.x / max(size.width, 1), y: center.y / max(size.height, 1)),
                    startRadius: 20, endRadius: reach
                )
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    if let hole { path.addRect(hole) }
                }
                .fill(Color.black.opacity(0.35), style: FillStyle(eoFill: true))
                if let hole {
                    Color(rgb: 0x1E1A2C, opacity: 0.4)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// The square the camera shows through, with pixel corners (`flash`: green), or why there is no camera here.
private struct Viewfinder: View {
    let flash: Bool
    let onCode: @MainActor (String) -> Bool
    /// nil while it is being found out (and the camera asked for).
    @State private var canScan: Bool?

    var body: some View {
        ZStack {
            switch canScan {
            case true?:
                QRScannerView(onCode: onCode)
            case false?:
                StepBody(text: "这台设备不能扫码，可以用系统相机扫，或者手动输入", color: Theme.ink, alignment: .center)
                    .padding(24)
            case nil:
                Color.clear
            }
            ViewfinderCorners()
                .fill(flash ? Theme.doneGlyph : Theme.ink)
                .accessibilityHidden(true)
        }
        .frame(width: ScanPage.side, height: ScanPage.side)
        .task { canScan = await QRScannerView.canScan() }
    }
}

/// The frame's four pixel corners: 34 pt arms, 6 pt thick (Android `PixelViewfinder`).
private struct ViewfinderCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let t: CGFloat = 6
        let arm: CGFloat = 34
        let (x0, y0, x1, y1) = (rect.minX, rect.minY, rect.maxX, rect.maxY)
        var path = Path()
        for (x, y) in [(x0, y0), (x1 - arm, y0), (x0, y1 - t), (x1 - arm, y1 - t)] {
            path.addRect(CGRect(x: x, y: y, width: arm, height: t))
        }
        for (x, y) in [(x0, y0), (x1 - t, y0), (x0, y1 - arm), (x1 - t, y1 - arm)] {
            path.addRect(CGRect(x: x, y: y, width: t, height: arm))
        }
        return path
    }
}

/// Sprig under the viewfinder, 4 pt a cell, looking up at it with a blink now and then for half a minute or so
/// before it goes about its day (Android `lookingUp`); it hops when a code is read. Under reduce motion it stands in
/// its still pose.
private struct LookingUp: View {
    let control: CritterStageControl

    @Environment(SkinStore.self) private var skins

    private static let cell: CGFloat = 4
    /// 16 cells: the base box and the room over it.
    static let height: CGFloat = 16 * cell
    /// How many times Sprig looks up, blinks and looks up again.
    private static let rounds = 5

    var body: some View {
        let sprig = skins.previewLibrary.manifest(PhoneSkinLibrary.fallback)
        CritterStage(
            slots: [
                CritterSlot(
                    sessionId: LonePet.petId, manifest: sprig, state: .idle, activity: nil, dimStrength: 0,
                    origin: CGPoint(x: ((ScanPage.side - 18 * Self.cell) / 2).rounded(), y: Self.height),
                    scale: Self.cell
                ),
            ],
            control: control
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            // Once the stage is in place.
            await Task.yield()
            control.playClip(LonePet.petId, clip: Self.lookingUp(sprig))
        }
    }

    private static func lookingUp(_ skin: SkinManifest) -> MotionClip {
        let n = skin.interactions
        let round = [
            ClipKey(pose: n.lookUp, ticks: 40),
            ClipKey(pose: n.blinkPose, ticks: 2),
            ClipKey(pose: n.lookUp, ticks: 60),
        ]
        return Array(repeating: round, count: rounds).flatMap { $0 } + [ClipKey(pose: n.lookCenter, ticks: 2)]
    }
}
