import CritterClient
import CritterKit
import SwiftUI
import UIKit

/// One session's details and 「发一句」 (visual design §8.5, Android `DetailActivity`), the content of a `sheetShell`
/// over the home screen. The session is looked up in the latest snapshot by id; when it is gone the sheet says so
/// and closes.
///
/// On top a 150 pt meadow with the Critter going on with what it does and a bubble beside it saying what that is
/// (it looks up at you once the sheet has settled); then the name and state, the facts in two columns, the field and
/// the send button. Sent, a pixel letter flies in an arc from the button to over the Critter's head, seven steps of
/// 60 ms, and the Critter notices it and finishes with a little wiggle; "已送到" in green below. Not sent: the
/// reason in red, and the words stay in the field. With the keyboard up the meadow gets lower and the facts fold
/// away, so the field stays in view.
struct DetailSheet: View {
    let sessionId: String
    let store: BridgeStore
    /// 「打开回答」: the session's request, in its answer card.
    let onOpenRequest: (String) -> Void

    @Environment(\.closeSheet) private var closeSheet
    @Environment(SkinStore.self) private var skins
    @Environment(\.reduceMotion) private var reduceMotion

    @State private var text = ""
    /// Something the field could not take: it holds 4000 at most.
    @State private var clipped = false
    /// 「发送」 and 「停止当前回合」 each wait for their own receipt.
    @State private var sending = false
    @State private var stopping = false
    @State private var feedback: Feedback?
    /// Missing from a cached snapshot proves nothing: the live one gets a while to arrive.
    @State private var waitedOut = false
    @State private var typing = false
    @State private var stage = CritterStageControl()
    /// Where the letter is while it flies, in the sheet's space.
    @State private var letter: CGPoint?
    @State private var sendFrame: CGRect = .zero
    @State private var stageFrame: CGRect = .zero

    private struct Feedback: Equatable {
        let message: String
        let ok: Bool
    }

    /// The meadow at the top; lower while the keyboard is up, to leave room for the field.
    private static let stageHeight: CGFloat = 150
    private static let stageHeightTyping: CGFloat = 118
    /// The letter lands this many cells above the Critter's feet, over its head.
    private static let headRows: CGFloat = 14
    /// The `letter` icon is 9 × 6 cells of 2 pt.
    private static let letterSize = CGSize(width: 18, height: 12)
    private static let letterStep: Duration = .milliseconds(60)
    private nonisolated static let space = "detail-sheet"

    private var session: BridgeSession? {
        store.snapshot?.sessions.first { $0.id == sessionId }
    }

    private var gone: Bool {
        session == nil && (store.isLive || waitedOut)
    }

    var body: some View {
        Group {
            if let session {
                details(session)
                    .sheetMeadowTop()
            } else {
                SheetMessage(text: gone ? "这个会话已经结束" : "正在连接电脑…")
            }
        }
        .task(id: sessionId) {
            try? await Task.sleep(for: .seconds(8))
            waitedOut = true
        }
        .task(id: gone) {
            guard gone else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { closeSheet() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            typing = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            typing = false
        }
        #if DEBUG
        .task {
            guard let draft = DebugLaunch.current.sayDraft else { return }
            setText(draft)
            guard DebugLaunch.current.autoSay else { return }
            // One second after the sheet is up: the same as tapping the send button.
            try? await Task.sleep(for: .seconds(1))
            if let session { say(session) }
        }
        #endif
    }

    // MARK: - The sheet

    private func details(_ session: BridgeSession) -> some View {
        VStack(spacing: 0) {
            DetailStage(
                session: session, manifest: skins.library.manifest(session.skin),
                height: typing ? Self.stageHeightTyping : Self.stageHeight, control: stage
            )
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { stageFrame = $0 }
            // The sheet's own scroll view takes it when it does not fit: the field stays one field.
            column(session)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) {
            if let letter {
                PixelIconView(.letter)
                    .foregroundStyle(Theme.brand)
                    .offset(x: letter.x, y: letter.y)
                    .allowsHitTesting(false)
            }
        }
    }

    private func column(_ session: BridgeSession) -> some View {
        let canMessage = SessionText.supportsMessages(session)
        let pending = store.snapshot?.pending.filter { $0.sessionId == session.id }.min { $0.createdAt < $1.createdAt }
        return VStack(alignment: .leading, spacing: typing ? 10 : 14) {
            HStack(spacing: 8) {
                Text(verbatim: session.name)
                    .font(.nunito(size: typing ? 18 : 20, weight: .black))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StateTag(state: session.state)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !typing {
                Facts(session: session)
            }
            if canMessage {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 8) {
                        // Not disabled while sending: that drops the keyboard and the sheet changes shape under the
                        // flying letter. The send button waits instead, and what is typed meanwhile survives the
                        // send (`SayFeedback.afterSent`).
                        PixelTextField("发一句…", text: Binding(get: { text }, set: { setText($0) }), maxLines: 5)
                        SendButton(enabled: canSend(session)) { say(session) }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: {
                                sendFrame = $0
                            }
                    }
                    if clipped {
                        Text(verbatim: "一次最多发 \(SayFeedback.maxLength) 个字，多出来的没有放进输入框。")
                            .font(.nunito(size: 11.5, weight: .heavy))
                            .foregroundStyle(Theme.err)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    hint(session)
                }
            } else {
                hint(session)
            }
            if SessionText.canStopTurn(session, online: store.canAct) {
                PixelButton(
                    title: stopping ? "正在发送…" : "停止当前回合", role: .destructive, style: .secondary, size: .small,
                    wide: true
                ) {
                    stopTurn(session)
                }
                .disabled(stopping)
            }
            if let pending, SessionText.supportsAnswers(session) {
                PixelButton(title: "打开回答", style: .secondary, size: .small, wide: true) {
                    onOpenRequest(pending.requestId)
                }
                .disabled(!store.canAct)
            }
            if let hint = SessionText.waitingHint(session, hasActionableRequest: pending != nil) {
                Text(verbatim: hint)
                    .font(.nunito(size: 12, weight: .bold))
                    .foregroundStyle(Theme.ink2)
            }
            if let feedback {
                HStack(spacing: 6) {
                    PixelIconView(feedback.ok ? .check : .bang)
                    Text(verbatim: feedback.message)
                        .font(.nunito(size: 12.5, weight: .heavy))
                }
                .foregroundStyle(feedback.ok ? Theme.done : Theme.err)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, typing ? 12 : 14)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ session: BridgeSession) -> some View {
        Text(verbatim: SessionText.messageHint(session))
            .font(.nunito(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.ink2)
            .lineSpacing(17 - 11.5 * 1.36)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 发一句

    /// The field takes at most `SayFeedback.maxLength` UTF-16 units (as Android's field and the Mac count them);
    /// anything past that is left out and the sheet says so.
    private func setText(_ new: String) {
        let room = SayFeedback.maxLength
        if new.utf16.count <= room {
            text = new
            if new.utf16.count < room { clipped = false }
            return
        }
        var kept = ""
        var units = 0
        for character in new {
            let size = String(character).utf16.count
            if units + size > room { break }
            kept.append(character)
            units += size
        }
        text = kept
        clipped = true
    }

    /// Something to say, a session that takes messages, a Mac to tell, and no message on its way.
    private func canSend(_ session: BridgeSession) -> Bool {
        SessionText.supportsMessages(session) && store.canAct && !sending
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func say(_ session: BridgeSession) {
        guard canSend(session) else { return }
        let sent = text
        sending = true
        feedback = nil
        Task {
            let result = await store.send(.say(sessionId: session.id, text: sent.trimmingCharacters(in: .whitespacesAndNewlines)))
            sending = false
            // Sent: "已送到" (visual design §7); otherwise the Mac's reason, or what the failure means.
            let message = result.ok ? "已送到" : SayFeedback.text(for: result, codex: SessionText.isCodex(session))
            feedback = Feedback(message: message, ok: result.ok)
            if result.ok {
                setText(SayFeedback.afterSent(current: text, sent: sent))
                // Under reduce motion nothing flies: the green line says it.
                if !reduceMotion { await flyLetter(session) }
            }
        }
    }

    /// The letter flies from the send button to just over the Critter's head, one 60 ms step at a time, then the
    /// Critter notices it and ends with its little after-petting wiggle.
    private func flyLetter(_ session: BridgeSession) async {
        guard sendFrame != .zero, stageFrame != .zero else { return }
        let half = CGSize(width: Self.letterSize.width / 2, height: Self.letterSize.height / 2)
        let from = CGPoint(x: sendFrame.midX - half.width, y: sendFrame.midY - half.height)
        let cell = DetailStage.cell
        let petLeft = DetailStage.petLeft(width: stageFrame.width)
        let ground = stageFrame.height - DetailStage.ground
        let to = CGPoint(
            x: stageFrame.minX + petLeft + 9 * cell - half.width,
            y: stageFrame.minY + ground - Self.headRows * cell
        )
        for point in LetterFlight.path(from: from, to: to, steps: 7, rise: 60, cell: 3) {
            letter = point
            try? await Task.sleep(for: Self.letterStep)
        }
        letter = nil
        let skin = skins.library.manifest(session.skin)
        let n = skin.interactions
        stage.playClip(LonePet.petId, clip: (skin.clips[n.notice] ?? []) + (skin.clips[n.petEnd] ?? []))
    }

    private func stopTurn(_ session: BridgeSession) {
        guard SessionText.canStopTurn(session, online: store.canAct), !stopping else { return }
        stopping = true
        feedback = nil
        Task {
            let result = await store.send(.interrupt(sessionId: session.id))
            stopping = false
            feedback = Feedback(message: SayFeedback.text(for: result, isInterrupt: true), ok: result.ok)
        }
    }
}

// MARK: - The meadow

/// The meadow at the top: the session's Critter a quarter of the way in, going on with what it does, and a bubble
/// beside it saying what that is (one line). Once the sheet has settled, the Critter looks up at you.
private struct DetailStage: View {
    let session: BridgeSession
    let manifest: SkinManifest
    let height: CGFloat
    let control: CritterStageControl

    /// The Critter's feet above the bottom of the meadow, its cell, and where it stands: a quarter of the way in.
    static let ground: CGFloat = 22
    static let cell: CGFloat = 4
    private static let center: CGFloat = 0.25
    /// The bubble's top sits this far above the Critter's feet (44 pt from the top of the 150 pt meadow).
    private static let bubbleAboveGround: CGFloat = 84
    /// The mockup's details sky: the moon in the top right corner, clear of the bubble.
    private static let clouds = [CGPoint(x: 0.05, y: 0.12), CGPoint(x: 0.5, y: 0.05)]
    private static let moon = CGPoint(x: 0.9, y: 0.08)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let petLeft = Self.petLeft(width: width)
            let petRight = petLeft + 18 * Self.cell
            let groundY = height - Self.ground
            let bubbleLeft = petRight + 18
            ZStack(alignment: .topLeading) {
                LonePet(
                    skin: manifest, state: session.state, activity: session.activity, cell: Self.cell,
                    groundInset: Self.ground, petX: petLeft, clouds: Self.clouds, moon: Self.moon, control: control
                )
                SideBubble(text: SessionText.doing(session))
                    .frame(width: max(width - bubbleLeft - 12, 0), alignment: .leading)
                    .offset(x: bubbleLeft, y: max(groundY - Self.bubbleAboveGround, 4))
            }
        }
        .frame(height: height)
        .lookAtYouOnceSettled(control)
    }
}

extension DetailStage {
    /// Where the Critter's base box starts in a meadow `width` wide.
    static func petLeft(width: CGFloat) -> CGFloat {
        (width * center - 9 * cell).rounded()
    }
}

/// What the session is doing, in a bubble whose stepped tail points left at the Critter (the mockups'
/// `.mbub.side`).
private struct SideBubble: View {
    let text: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Four rows, each one 2 pt step wider to the left: a staircase down to the bubble's corner.
            Canvas { context, size in
                for row in 0..<4 {
                    let x = CGFloat(3 - row) * 2
                    context.fill(
                        Path(CGRect(x: x, y: CGFloat(row) * 2, width: size.width - x, height: 2)),
                        with: .color(Theme.surface)
                    )
                }
            }
            .frame(width: 8, height: 8)
            .padding(.bottom, 4)
            Text(verbatim: text)
                .font(.nunito(size: 12, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.top, 4)
                .padding(.bottom, 6)
                .pixelSurface(fill: Theme.surface, lip: Theme.shade, step: 3, lipHeight: 2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - The facts

/// Two columns of facts, each with its icon; the context share takes a whole row, and a Codex session's own quota
/// another.
private struct Facts: View {
    let session: BridgeSession

    private struct Item {
        let icon: PixelIcon
        let label: String
        let value: String
        /// Shown in monospace and cut in the middle, so both ends stay readable.
        var path = false
    }

    var body: some View {
        let source = SessionText.visibleSource(session)
        var items = [Item(icon: .folder, label: "目录", value: session.cwd, path: true)]
        if let branch = session.branch, !branch.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(Item(icon: .branch, label: "分支", value: branch))
        }
        items.append(Item(icon: PlaceRow.icon(source), label: "来源", value: SessionText.source(source)))
        if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(Item(icon: .spark, label: "模型", value: model))
        }
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        let updated = Date(timeIntervalSince1970: Double(session.eventTime) / 1000)
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(rows.indices, id: \.self) { i in
                factRow(rows[i])
            }
            // An estimated context share (the Mac could not read the real one) is marked with ≈.
            if let context = session.context {
                ContextFact(context: context)
            }
            if SessionText.isCodex(session), let limits = session.limits {
                LimitsFact(limits: limits)
            }
            // The age reads the clock once a minute, on its own.
            TimelineView(.everyMinute) { context in
                factRow([Item(icon: .dot, label: "最后更新", value: SessionText.ago(updated, now: context.date))])
            }
        }
    }

    private func factRow(_ row: [Item]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(row.indices, id: \.self) { j in
                fact(row[j])
            }
            if row.count == 1 { Color.clear.frame(maxWidth: .infinity, maxHeight: 0) }
        }
    }

    private func fact(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            FactLabel(icon: item.icon, label: item.label)
            Text(verbatim: item.value)
                .font(item.path ? .system(size: 13, weight: .bold, design: .monospaced) : .nunito(size: 14, weight: .bold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(item.path ? .middle : .tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct FactLabel: View {
    let icon: PixelIcon
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            PixelIconView(icon)
            Text(verbatim: label)
                .font(.nunito(size: 11.5, weight: .heavy))
        }
        .foregroundStyle(Theme.ink2)
    }
}

/// "上下文" and its share ("≈32%": the digits in Silkscreen, the signs in Nunito) over a 24-cell meter.
private struct ContextFact: View {
    let context: BridgeContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FactLabel(icon: .battery, label: "上下文")
                Spacer(minLength: 8)
                Text.percent(SessionText.contextPercent(context), digits: .silkscreen(size: 13), signSize: 13)
                    .foregroundStyle(Theme.ink)
            }
            SegmentMeter(fraction: context.usedPercent / 100, segments: 24)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A Codex session's own quota windows (Android `LimitsFact`), their resets and age read off the clock once a minute.
private struct LimitsFact: View {
    let limits: BridgeLimits

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FactLabel(icon: .battery, label: "Codex 额度")
            HStack(alignment: .top, spacing: 14) {
                window("5 小时", limits.fiveHour, now: now)
                window("7 天", limits.sevenDay, now: now)
            }
            if let age = LimitsText.staleness(updatedAt: limits.updatedAt, now: now) {
                Text(verbatim: "额度更新于 \(age)")
                    .font(.nunito(size: 11.5))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func window(_ name: String, _ window: RateWindow?, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: "\(name) · \(LimitsText.percent(window))")
                .font(.nunito(size: 13, weight: .heavy))
                .foregroundStyle(Theme.ink)
            if let window {
                SegmentMeter(fraction: window.usedPercentage / 100, segments: 12)
            }
            Text(verbatim: LimitsText.resets(window, now: now, calendar: .autoupdatingCurrent))
                .font(.nunito(size: 11.5))
                .foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The send button

/// The 48 × 44 send button: a primary pixel button with only the `send` icon.
private struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The style's 16 pt on each side make it 48 wide.
            PixelIconView(.send)
                .frame(width: 16)
        }
        .buttonStyle(PixelButtonStyle(style: .primary, size: .regular))
        .disabled(!enabled)
        .accessibilityLabel(Text("发送"))
    }
}
