import XCTest
@testable import UploaderCore

/// 実 Keychain を触るため既定ではスキップ。`GEOFRAME_KEYCHAIN_TEST=1 swift test --filter KeychainTests` で実行。
final class KeychainTests: XCTestCase {
    func testRoundTripWithThrowawayService() throws {
        guard ProcessInfo.processInfo.environment["GEOFRAME_KEYCHAIN_TEST"] == "1" else {
            throw XCTSkip("set GEOFRAME_KEYCHAIN_TEST=1 to exercise the real keychain")
        }
        let store = KeychainTokenStore(service: "dev.local.geoframe.uploader.test-\(UUID().uuidString)", account: "t")
        try store.delete()
        defer { try? store.delete() }
        XCTAssertFalse(store.exists())
        XCTAssertNil(try store.load())
        try store.save("first")          // SecItemAdd
        try store.save("second")         // SecItemUpdate
        XCTAssertTrue(store.exists())
        XCTAssertEqual(try store.load(), "second")
        try store.delete()
        XCTAssertFalse(store.exists())
    }
}
