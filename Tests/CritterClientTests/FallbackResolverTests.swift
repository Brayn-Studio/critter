import CritterClient
import Testing

private let last = Endpoint(host: "192.168.1.20", port: 47823)
private let moved = Endpoint(host: "192.168.1.31", port: 47823)
private let other = Endpoint(host: "192.168.1.40", port: 47824)

struct FallbackResolverTests {
    @Test func usesTheLastAddressFirst() async {
        let browser = FakeBrowser([DiscoveredMac(name: "Xuan's MacBook", endpoint: moved)])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: false) == last)
        #expect(browser.discoveries == 0)
    }

    @Test func fallsBackToBonjourAfterTheLastAddressFails() async {
        let browser = FakeBrowser([
            DiscoveredMac(name: "Office iMac", endpoint: other),
            DiscoveredMac(name: "Xuan's MacBook", endpoint: moved),
        ])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: true) == moved)
        // No last address at all: Bonjour straight away.
        let fresh = FallbackResolver(lastGood: { nil }, macName: "Xuan's MacBook", browser: browser)
        #expect(await fresh.resolve(afterFailure: false) == moved)
    }

    @Test func picksTheFirstMacWhenNoneHasTheName() async {
        let browser = FakeBrowser([
            DiscoveredMac(name: "Office iMac", endpoint: other),
            DiscoveredMac(name: "Studio", endpoint: moved),
        ])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: true) == other)
    }

    @Test func nothingFoundIsNil() async {
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: FakeBrowser([]))
        #expect(await resolver.resolve(afterFailure: true) == nil)
    }

    @Test func staticResolverAlwaysGivesItsAddress() async {
        let resolver = StaticResolver(last)
        #expect(await resolver.resolve(afterFailure: false) == last)
        #expect(await resolver.resolve(afterFailure: true) == last)
    }
}
