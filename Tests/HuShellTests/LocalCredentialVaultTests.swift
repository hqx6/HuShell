import XCTest
import CryptoKit
import CommonCrypto
@testable import HuShell

final class LocalCredentialVaultTests: XCTestCase {
    func testConnectionsReadWithoutMasterPasswordButRevealRequiresIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushell-vault-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let other = UUID()
        let vault = LocalCredentialVault(directory: directory)
        try vault.create(masterPassword: "private test master password")
        try vault.set("ssh secret one", for: id)
        try vault.set("ssh secret two", for: other)

        let file = directory.appendingPathComponent("credentials.vault")
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(bytes.range(of: Data("ssh secret one".utf8)) != nil)
        XCTAssertFalse(bytes.range(of: Data("ssh secret two".utf8)) != nil)
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        let keyFile = directory.appendingPathComponent("credentials.key")
        let keyMode = (try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(keyMode, 0o600)

        let reopened = LocalCredentialVault(directory: directory)
        XCTAssertEqual(try reopened.password(for: id), "ssh secret one")
        XCTAssertThrowsError(try reopened.verify(masterPassword: "incorrect password"))
        XCTAssertEqual(try reopened.password(for: other), "ssh secret two")
        try reopened.verify(masterPassword: "private test master password")
        XCTAssertEqual(try reopened.password(for: other), "ssh secret two")
        try reopened.remove(for: id)

        let again = LocalCredentialVault(directory: directory)
        XCTAssertNil(try again.password(for: id))
        XCTAssertEqual(try again.password(for: other), "ssh secret two")
    }

    func testOldVaultNeedsOneTimeMigrationThenConnectsDirectly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hushell-migrate-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let master = "legacy master password"
        let salt = Data(repeating: 7, count: 16)
        let rounds = 100_000
        var rawKey = [UInt8](repeating: 0, count: 32)
        let input = Array(master.utf8)
        let status = input.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pass.baseAddress?.assumingMemoryBound(to: Int8.self), input.count,
                                     saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     &rawKey, rawKey.count)
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess))
        let plaintext = try JSONEncoder().encode([id.uuidString: "legacy ssh secret"])
        let ciphertext = try AES.GCM.seal(plaintext, using: SymmetricKey(data: Data(rawKey))).combined!
        struct Old: Codable { let version: Int; let salt: Data; let rounds: Int; let ciphertext: Data }
        try JSONEncoder().encode(Old(version: 1, salt: salt, rounds: rounds, ciphertext: ciphertext))
            .write(to: directory.appendingPathComponent("credentials.vault"))

        let vault = LocalCredentialVault(directory: directory)
        XCTAssertTrue(vault.requiresMigration)
        XCTAssertThrowsError(try vault.password(for: id))
        XCTAssertThrowsError(try vault.migrate(masterPassword: "wrong master"))
        try vault.migrate(masterPassword: master)
        XCTAssertFalse(vault.requiresMigration)
        let reopened = LocalCredentialVault(directory: directory)
        XCTAssertEqual(try reopened.password(for: id), "legacy ssh secret")
    }
}
