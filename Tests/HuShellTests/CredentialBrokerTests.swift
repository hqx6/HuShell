import XCTest
@testable import HuShell

final class CredentialBrokerTests: XCTestCase {
    func testPrivateBrokerServesCachedPasswordAndRejectsInvalidToken() {
        let id = UUID()
        let broker = CredentialBroker.shared
        broker.cacheForTesting("temporary-test-password", for: id)
        XCTAssertEqual(CredentialBroker.request(path: broker.socketPath, token: broker.token, id: id),
                       "temporary-test-password")
        XCTAssertNil(CredentialBroker.request(path: broker.socketPath, token: "invalid", id: id))
        broker.invalidate(id)
        XCTAssertNil(CredentialBroker.request(path: broker.socketPath, token: broker.token, id: id))
    }
}
