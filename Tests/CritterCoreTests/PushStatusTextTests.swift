import Foundation
import Testing
@testable import CritterCore

// The status line of the settings' "iPhone 推送": 未配置 / 已配置 · 上次发送 <x 分钟前> / 出错：<原因>.

private let now: Int64 = 1_760_000_000_000
private let ready = APNsSetup.ready(
    APNsConfig(keyId: "ABC123DEFG", teamId: "TEAM123456", keyFile: URL(fileURLWithPath: "/k.p8")), pem: "pem"
)

private func line(
    _ setup: APNsSetup?, blocked: String? = nil, failure: String? = nil, sentAt: Int64? = nil
) -> PushStatusText.Line {
    PushStatusText.line(setup: setup, blockedReason: blocked, lastFailure: failure, lastSentAt: sentAt, now: now)
}

@Test func notSetUpSaysSo() {
    #expect(line(.notConfigured) == PushStatusText.Line(text: "未配置", isError: false))
    #expect(line(nil) == PushStatusText.Line(text: "未配置", isError: false))
}

@Test func aWorkingSetupSaysWhenItLastSent() {
    #expect(line(ready) == PushStatusText.Line(text: "已配置 · 还没有发送过", isError: false))
    #expect(line(ready, sentAt: now - 20_000).text == "已配置 · 上次发送 刚刚")
    #expect(line(ready, sentAt: now - 3 * 60_000).text == "已配置 · 上次发送 3 分钟前")
    #expect(line(ready, sentAt: now - 2 * 3_600_000).text == "已配置 · 上次发送 2 小时前")
    #expect(line(ready, sentAt: now - 3 * 86_400_000).text == "已配置 · 上次发送 3 天前")
    #expect(!line(ready, sentAt: now - 3 * 60_000).isError)
}

@Test func errorsSayWhyInRed() {
    #expect(line(.problem("读不了 .p8 文件")) == PushStatusText.Line(text: "出错：读不了 .p8 文件", isError: true))
    #expect(line(ready, blocked: "密钥或 Team ID 不对", sentAt: now) == PushStatusText.Line(text: "出错：密钥或 Team ID 不对", isError: true))
    // A failed push after the last good one.
    #expect(line(ready, failure: "network error", sentAt: now - 60_000) == PushStatusText.Line(text: "出错：连不上 APNs", isError: true))
    #expect(line(ready, failure: "503").text == "出错：APNs 暂时不可用（503）")
    #expect(line(ready, failure: "429").text == "出错：APNs 暂时不可用（429）")
    #expect(line(ready, failure: "PayloadTooLarge").text == "出错：APNs 不收这条推送（PayloadTooLarge）")
    #expect(line(ready, failure: "413").text == "出错：APNs 不收这条推送（413）")
    #expect(line(ready, failure: "signing").text == "出错：签不了推送的令牌，检查 .p8 文件")
    // The 403 stop wins over a passing failure.
    #expect(line(ready, blocked: "密钥或 Team ID 不对", failure: "network error").text == "出错：密钥或 Team ID 不对")
}

@Test func theTestButtonExplainsWhyItCannotBeUsed() {
    #expect(PushStatusText.testHint(registered: 0, reachable: 0, setUp: true) == "还没有 iPhone 登记推送")
    #expect(PushStatusText.testHint(registered: 0, reachable: 0, setUp: false) == "还没有 iPhone 登记推送")
    #expect(PushStatusText.testHint(registered: 2, reachable: 0, setUp: true) == "登记了的 iPhone 不是这个 bundle id 的 App")
    #expect(PushStatusText.testHint(registered: 2, reachable: 0, setUp: false) == nil)
    #expect(PushStatusText.testHint(registered: 2, reachable: 1, setUp: true) == nil)
}
