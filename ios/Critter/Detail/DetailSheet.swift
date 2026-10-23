import CritterClient
import CritterKit
import SwiftUI

/// One session's details and 「发一句」 (Android `DetailActivity`): a sheet over the home list. The session is looked up
/// in the latest snapshot by id; when it is gone the sheet says so and closes.
struct DetailSheet: View {
    let sessionId: String
    let store: BridgeStore

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var feedback: Feedback?
    /// Missing from a cached snapshot proves nothing: the live one gets a while to arrive.
    @State private var waitedOut = false
    @State private var now = Date()

    private struct Feedback {
        let message: String
        let ok: Bool
    }

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
            } else {
                Text(gone ? "这个会话已经结束" : "正在连接电脑…")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task(id: sessionId) {
            try? await Task.sleep(for: .seconds(8))
            waitedOut = true
        }
        .task(id: gone) {
            guard gone else { return }
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { dismiss() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                now = Date()
            }
        }
    }

    // MARK: - The details

    private func details(_ session: BridgeSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Text(verbatim: session.name)
                        .font(.title2.bold())
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    StateChip(state: session.state)
                }
                Text(verbatim: SessionText.doing(session))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                facts(session)
                sayArea(session)
                if SessionText.canStopTurn(session, online: store.canAct) {
                    Button(role: .destructive) { stopTurn(session) } label: {
                        Text(busy ? "正在发送…" : "停止当前回合").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy)
                }
                if let feedback {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: feedback.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        Text(verbatim: feedback.message)
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(feedback.ok ? Color(.systemGreen) : Color(.systemRed))
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func facts(_ session: BridgeSession) -> some View {
        var pairs: [(label: String, value: String)] = []
        if let branch = session.branch, !branch.trimmingCharacters(in: .whitespaces).isEmpty {
            pairs.append(("分支", branch))
        }
        pairs.append(("来源", SessionText.source(SessionText.visibleSource(session))))
        if let model = session.model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            pairs.append(("模型", model))
        }
        let rows = stride(from: 0, to: pairs.count, by: 2).map { Array(pairs[$0..<min($0 + 2, pairs.count)]) }
        let updated = SessionText.ago(Date(timeIntervalSince1970: Double(session.eventTime) / 1000), now: now)
        return Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 12) {
            GridRow {
                Fact(label: "目录", value: session.cwd, monospaced: true)
                    .gridCellColumns(2)
            }
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    ForEach(rows[i].indices, id: \.self) { j in
                        Fact(label: rows[i][j].label, value: rows[i][j].value)
                    }
                    if rows[i].count == 1 { Color.clear.frame(height: 0) }
                }
            }
            if let context = session.context {
                GridRow {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("上下文")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: SessionText.contextPercent(context))
                                .font(.footnote.weight(.bold))
                                .monospacedDigit()
                        }
                        UsageBar(percent: context.usedPercent, height: 8)
                    }
                    .accessibilityElement(children: .combine)
                    .gridCellColumns(2)
                }
            }
            GridRow {
                Fact(label: "最后更新", value: updated)
                Color.clear.frame(height: 0)
            }
        }
    }

    // MARK: - 发一句

    private func sayArea(_ session: BridgeSession) -> some View {
        let canMessage = SessionText.supportsMessages(session)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("发一句…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .disabled(!canMessage)
                Button { say(session) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 36))
                }
                .disabled(!canSend(session))
                .accessibilityLabel("发送")
            }
            Text(verbatim: SessionText.messageHint(session))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Something to say, no longer than the Mac takes (trimmed, in UTF-16 units as phones count them), a session that
    /// takes messages, and a Mac to tell.
    private func canSend(_ session: BridgeSession) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return SessionText.supportsMessages(session) && store.canAct && !busy
            && !trimmed.isEmpty && trimmed.utf16.count <= BridgeProtocol.maxSayUTF16Units
    }

    private func say(_ session: BridgeSession) {
        guard canSend(session) else { return }
        let sent = text
        busy = true
        feedback = nil
        Task {
            let result = await store.send(.say(sessionId: session.id, text: sent.trimmingCharacters(in: .whitespacesAndNewlines)))
            busy = false
            feedback = Feedback(message: Self.sayFeedback(result, codex: SessionText.isCodex(session)), ok: result.ok)
            if result.ok { text = Self.afterSent(current: text, sent: sent) }
        }
    }

    private func stopTurn(_ session: BridgeSession) {
        guard SessionText.canStopTurn(session, online: store.canAct), !busy else { return }
        busy = true
        feedback = nil
        Task {
            let result = await store.send(.interrupt(sessionId: session.id))
            busy = false
            feedback = Feedback(message: Self.interruptFeedback(result), ok: result.ok)
        }
    }

    /// The text of the field after `sent` went out: the field stays editable while sending, so what was typed after
    /// the sent words is kept; a field whose sent words were edited meanwhile is a new draft and stays as it is.
    static func afterSent(current: String, sent: String) -> String {
        guard current.hasPrefix(sent) else { return current }
        return String(current.dropFirst(sent.count).drop { $0.isWhitespace })
    }

    /// What the sheet says about the Mac's receipt for a message (Android `sayFeedback`; success is 「已送到」).
    static func sayFeedback(_ result: CommandResult, codex: Bool) -> String {
        if result.ok { return "已送到" }
        if let message = result.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
        if result.reason == .unavailable {
            return codex ? "尚未连接 Codex 控制通道，请在电脑上继续操作" : "这个会话收不到消息（可能是启动得太早，重启会话后可用）"
        }
        return "发送失败"
    }

    /// A receipt confirms the stop request was accepted, not that the turn has already stopped (Android
    /// `interruptFeedback`).
    static func interruptFeedback(_ result: CommandResult) -> String {
        if let message = result.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return message }
        if result.ok { return "已请求停止当前回合" }
        return result.reason == .unavailable ? "当前会话无法停止，请在电脑上处理" : "停止请求未发送成功"
    }
}

private struct Fact: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: label)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(monospaced ? .system(.subheadline, design: .monospaced).weight(.semibold) : .subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(monospaced ? .middle : .tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
