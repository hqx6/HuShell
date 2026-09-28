import XCTest
@testable import HuShell

final class FinalShellImportTests: XCTestCase {
    func testKnownPublicPasswordVectorAndInvalidInput() throws {
        // Public sample from the format's reference implementation; not a user's credential.
        XCTAssertEqual(try FinalShellImport.decodePassword("UU8hWV51DmVNgmX/pUd0LlaEo53VTa6s"), "beac3d85988e")
        XCTAssertThrowsError(try FinalShellImport.decodePassword("invalid"))
        XCTAssertThrowsError(try FinalShellImport.decodePassword(Data(repeating: 0, count: 16).base64EncodedString()))
    }

    func testNestedAndEmptyGroupsAndBackwardCompatibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, parent, name) in [("a", "root", "公司"), ("b", "a", "研发"), ("empty", "root", "空分组")] {
            let directory = root.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["id": id, "parent_id": parent, "name": name]).write(to: directory.appendingPathComponent("folder.json"))
        }
        let config: [String: Any] = ["id": "demo", "parent_id": "b", "name": "demo", "host": "localhost",
            "user_name": "test", "port": 22, "conection_type": 100, "authentication_type": 1,
            "password": "UU8hWV51DmVNgmX/pUd0LlaEo53VTa6s"]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("b/demo_connect_config.json"))
        let plan = try FinalShellImport(directory: root)
        XCTAssertEqual(Set(plan.groups), ["公司", "公司/研发", "空分组"])
        XCTAssertEqual(plan.entries.first?.profile.groupPath, "公司/研发")
        XCTAssertEqual(plan.entries.first?.profile.importSourceID, "finalshell:demo")
        XCTAssertEqual(plan.entries.first?.password, "beac3d85988e")
        let old = Data("{\"id\":\"\(UUID())\",\"name\":\"old\",\"host\":\"localhost\",\"port\":22,\"username\":\"test\",\"identityFile\":\"\",\"usesPassword\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(ConnectionProfile.self, from: old).groupPath)
    }
}
