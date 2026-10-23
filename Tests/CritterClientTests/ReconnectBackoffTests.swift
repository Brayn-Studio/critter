import CritterClient
import Testing

struct ReconnectBackoffTests {
    @Test func doublesFromTwoSecondsToAMinute() {
        var backoff = ReconnectBackoff()
        let delays = (0..<7).map { _ in backoff.nextDelay() }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) })
    }

    @Test func resetStartsOver() {
        var backoff = ReconnectBackoff()
        _ = backoff.nextDelay()
        _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.nextDelay() == .seconds(2))
        #expect(backoff.nextDelay() == .seconds(4))
    }
}
