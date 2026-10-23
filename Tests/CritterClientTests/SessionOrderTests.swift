import CritterClient
import CritterKit
import Testing

/// `SessionOrderTest.kt`.
struct SessionOrderTests {
    @Test func sessionOrderPutsWaitingFirst() {
        let body = fixtureBody(
            [fixtureSession("a"), fixtureSession("b", state: .waiting), fixtureSession("c"), fixtureSession("d", state: .waiting)],
            pending: [
                fixturePending("r1", "d", createdAt: 10),
                fixturePending("r2", "b", createdAt: 20),
                fixturePending("r3", "b", createdAt: 5),
            ]
        )
        // b's oldest request (5) is older than d's (10), so b leads; a and c keep their order.
        #expect(SessionOrder.forBoard(body).map(\.id) == ["b", "d", "a", "c"])
    }

    @Test func sessionOrderKeepsTheOrderWhenNothingIsPending() {
        let body = fixtureBody([fixtureSession("a"), fixtureSession("b")])
        #expect(SessionOrder.forBoard(body).map(\.id) == ["a", "b"])
    }

    @Test func sessionsWaitingSinceTheSameMomentKeepTheMacsOrder() {
        let body = fixtureBody(
            [fixtureSession("a"), fixtureSession("b"), fixtureSession("c"), fixtureSession("d")],
            pending: [fixturePending("r1", "d", createdAt: 7), fixturePending("r2", "c", createdAt: 7), fixturePending("r3", "b", createdAt: 7)]
        )
        #expect(SessionOrder.forBoard(body).map(\.id) == ["b", "c", "d", "a"])
    }

    @Test func aRequestOfAnUnknownSessionAddsNothing() {
        let body = fixtureBody([fixtureSession("a"), fixtureSession("b")], pending: [fixturePending("r1", "ghost", createdAt: 1)])
        #expect(SessionOrder.forBoard(body).map(\.id) == ["a", "b"])
    }
}
