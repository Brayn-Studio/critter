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

    /// Another Mac running Critter is not the paired one (its pin would not match, and that ends in "请重新配对"):
    /// none with the name is no Mac at all.
    @Test func noMacWithTheNameIsNil() async {
        let browser = FakeBrowser([
            DiscoveredMac(name: "Office iMac", endpoint: other),
            DiscoveredMac(name: "Studio", endpoint: moved),
            // Starts with the name, but is another Mac's.
            DiscoveredMac(name: "Xuan's MacBook Pro", endpoint: other),
            DiscoveredMac(name: "Xuan's MacBook(2)", endpoint: other),
        ])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: true) == nil)
    }

    /// As Android's `NsdLocator.namesMatch`: the name in any case.
    @Test func theNameMatchesInAnyCase() async {
        let browser = FakeBrowser([
            DiscoveredMac(name: "Office iMac", endpoint: other),
            DiscoveredMac(name: "XUAN'S macbook", endpoint: moved),
        ])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: true) == moved)
    }

    /// Bonjour adds " (2)" to a name that is taken on the network.
    @Test func theNameWithANumberBonjourAddedMatches() async {
        let browser = FakeBrowser([
            DiscoveredMac(name: "Office iMac", endpoint: other),
            DiscoveredMac(name: "xuan's MacBook (2)", endpoint: moved),
        ])
        let resolver = FallbackResolver(lastGood: { last }, macName: "Xuan's MacBook", browser: browser)
        #expect(await resolver.resolve(afterFailure: true) == moved)
        // No name to go by: only a service with no name either, never every "… (n)".
        let nameless = FallbackResolver(lastGood: { nil }, macName: "", browser: FakeBrowser([DiscoveredMac(name: " (2)", endpoint: moved)]))
        #expect(await nameless.resolve(afterFailure: true) == nil)
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
