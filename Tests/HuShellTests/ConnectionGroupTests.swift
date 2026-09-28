import XCTest
@testable import HuShell

final class ConnectionGroupTests: XCTestCase {
    @MainActor func testRecentConnectionsPersistAndReconnectionMovesToFront() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ConnectionProfile(name: "first", host: "localhost", username: "test")
        let second = ConnectionProfile(name: "second", host: "localhost", username: "test")
        let unused = ConnectionProfile(name: "unused", host: "localhost", username: "test")
        try JSONEncoder().encode([first, second, unused]).write(to: directory.appendingPathComponent("connections.json"))
        let store = ProfileStore(directory: directory)
        try store.recordConnection(first.id, at: Date(timeIntervalSince1970: 100))
        try store.recordConnection(second.id, at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.recentlyConnectedProfiles.map(\.id), [second.id, first.id])
        try store.recordConnection(first.id, at: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(ProfileStore(directory: directory).recentlyConnectedProfiles.map(\.id), [first.id, second.id])
    }

    @MainActor func testRenameNestedGroupThenDeletePreservesConnections() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var nested = ConnectionProfile(name: "nested", host: "localhost", username: "test")
        nested.groupPath = "公司/研发/测试"
        var other = ConnectionProfile(name: "other", host: "localhost", username: "test")
        other.groupPath = "其他"
        let original = [nested, other]
        try JSONEncoder().encode(original).write(to: directory.appendingPathComponent("connections.json"))
        try JSONEncoder().encode(["公司/研发/空分组", "公司/财务"]).write(to: directory.appendingPathComponent("groups.json"))
        let store = ProfileStore(directory: directory)
        try store.renameGroup("公司/研发", to: "工程")
        let reopened = ProfileStore(directory: directory)
        XCTAssertEqual(reopened.profiles.first?.groupPath, "公司/工程/测试")
        XCTAssertTrue(reopened.availableGroups.contains("公司/工程/空分组"))
        XCTAssertFalse(reopened.availableGroups.contains("公司/研发"))
        XCTAssertThrowsError(try reopened.renameGroup("公司/工程", to: "财务"))
        XCTAssertThrowsError(try reopened.renameGroup("公司/工程", to: "非法/名称"))
        try reopened.removeGroup("公司/工程")
        let deleted = ProfileStore(directory: directory)
        XCTAssertEqual(deleted.profiles.count, 2)
        XCTAssertNil(deleted.profiles.first?.groupPath)
        XCTAssertEqual(deleted.profiles.last, other)
        XCTAssertEqual(deleted.profiles.first?.id, nested.id)
        XCTAssertEqual(deleted.profiles.first?.usesPassword, nested.usesPassword)
        XCTAssertTrue(deleted.availableGroups.contains("公司/财务"))
        XCTAssertFalse(deleted.availableGroups.contains { $0.hasPrefix("公司/工程") })
    }
}
