import Foundation
import CryptoKit
import CommonCrypto
import Darwin

enum VaultError: LocalizedError {
    case alreadyExists, missing, weakPassword, wrongPassword, damaged, missingCredential, migrationRequired
    var errorDescription: String? {
        switch self {
        case .alreadyExists: return "密码保险库已经存在"
        case .missing: return "尚未设置主密码"
        case .weakPassword: return "主密码至少需要 8 个字符"
        case .wrongPassword: return "主密码不正确"
        case .damaged: return "密码保险库文件或本机密钥无法读取"
        case .missingCredential: return "没有保存的 SSH 密码，请编辑连接并重新输入"
        case .migrationRequired: return "需要输入一次旧主密码以升级密码文件"
        }
    }
}

/// The local 0600 key enables automatic SSH connections. The master password
/// verifies explicit password reveal; it is not the data encryption key.
final class LocalCredentialVault {
    static let shared = LocalCredentialVault()

    private struct LegacyEnvelope: Codable {
        let version: Int
        let salt: Data
        let rounds: Int
        let ciphertext: Data
    }
    private struct Envelope: Codable {
        let version: Int
        let salt: Data
        let rounds: Int
        let verifier: Data
        let ciphertext: Data
    }

    private let fileURL: URL
    private let keyURL: URL
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var values: [String: String] = [:]
    private var envelope: Envelope?
    private let rounds = 600_000
    private static let verificationMessage = Data("HuShell-password-reveal-v2".utf8)

    init(directory: URL? = nil) {
        let folder: URL
        if let directory { folder = directory }
        else if let override = ProcessInfo.processInfo.environment["HUSHELL_PROFILE_STORE_DIRECTORY"], !override.isEmpty {
            folder = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("HuShell", isDirectory: true)
        }
        fileURL = folder.appendingPathComponent("credentials.vault")
        keyURL = folder.appendingPathComponent("credentials.key")
    }

    var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }
    var requiresMigration: Bool {
        guard let data = try? Data(contentsOf: fileURL),
              let old = try? JSONDecoder().decode(LegacyEnvelope.self, from: data) else { return false }
        return old.version == 1
    }

    func create(masterPassword: String) throws {
        guard masterPassword.count >= 8 else { throw VaultError.weakPassword }
        lock.lock(); defer { lock.unlock() }
        guard !exists else { throw VaultError.alreadyExists }
        try prepareFolder()
        let dataKey = SymmetricKey(size: .bits256)
        try writeKey(dataKey)
        let salt = randomSalt()
        let verifier = try Self.makeVerifier(masterPassword, salt: salt, rounds: rounds)
        let saved = try persist(values: [:], key: dataKey, salt: salt, rounds: rounds, verifier: verifier)
        key = dataKey
        values = [:]
        envelope = saved
    }

    /// Converts the previous master-encrypted file only after successful decryption.
    func migrate(masterPassword: String) throws {
        lock.lock(); defer { lock.unlock() }
        let old: LegacyEnvelope
        do { old = try JSONDecoder().decode(LegacyEnvelope.self, from: Data(contentsOf: fileURL)) }
        catch { throw VaultError.damaged }
        guard old.version == 1, old.salt.count == 16,
              (100_000...2_000_000).contains(old.rounds) else { throw VaultError.damaged }
        let oldKey = try Self.derive(masterPassword, salt: old.salt, rounds: old.rounds)
        let decoded: [String: String]
        do {
            let box = try AES.GCM.SealedBox(combined: old.ciphertext)
            decoded = try JSONDecoder().decode([String: String].self, from: AES.GCM.open(box, using: oldKey))
        } catch { throw VaultError.wrongPassword }
        try prepareFolder()
        let dataKey: SymmetricKey
        if FileManager.default.fileExists(atPath: keyURL.path) { dataKey = try readKey() }
        else { dataKey = SymmetricKey(size: .bits256); try writeKey(dataKey) }
        let salt = randomSalt()
        let verifier = try Self.makeVerifier(masterPassword, salt: salt, rounds: rounds)
        let saved = try persist(values: decoded, key: dataKey, salt: salt, rounds: rounds, verifier: verifier)
        key = dataKey
        values = decoded
        envelope = saved
    }

    func verify(masterPassword: String) throws {
        lock.lock(); defer { lock.unlock() }
        try loadIfNeeded()
        guard let envelope else { throw VaultError.missing }
        let computed = try Self.makeVerifier(masterPassword, salt: envelope.salt, rounds: envelope.rounds)
        guard Self.equal(computed, envelope.verifier) else { throw VaultError.wrongPassword }
    }

    func password(for id: UUID) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        try loadIfNeeded()
        return values[id.uuidString]
    }
    func hasPassword(for id: UUID) throws -> Bool { try password(for: id) != nil }

    func set(_ password: String, for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        try loadIfNeeded()
        guard let key, let envelope else { throw VaultError.missing }
        var updated = values
        updated[id.uuidString] = password
        let saved = try persist(values: updated, key: key, salt: envelope.salt,
                                rounds: envelope.rounds, verifier: envelope.verifier)
        values = updated
        self.envelope = saved
    }

    func setMany(_ passwords: [UUID: String]) throws {
        lock.lock(); defer { lock.unlock() }
        try loadIfNeeded()
        guard let key, let envelope else { throw VaultError.missing }
        var updated = values
        for (id, password) in passwords { updated[id.uuidString] = password }
        let saved = try persist(values: updated, key: key, salt: envelope.salt,
                                rounds: envelope.rounds, verifier: envelope.verifier)
        values = updated
        self.envelope = saved
    }

    func reload() {
        lock.lock(); defer { lock.unlock() }
        key = nil
        values = [:]
        envelope = nil
    }

    func remove(for id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        if !exists { return }
        try loadIfNeeded()
        guard let key, let envelope, values[id.uuidString] != nil else { return }
        var updated = values
        updated.removeValue(forKey: id.uuidString)
        let saved = try persist(values: updated, key: key, salt: envelope.salt,
                                rounds: envelope.rounds, verifier: envelope.verifier)
        values = updated
        self.envelope = saved
    }

    private func loadIfNeeded() throws {
        if envelope != nil { return }
        guard exists else { return }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw VaultError.damaged }
        if let old = try? JSONDecoder().decode(LegacyEnvelope.self, from: data), old.version == 1 {
            throw VaultError.migrationRequired
        }
        let saved: Envelope
        do { saved = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw VaultError.damaged }
        guard saved.version == 2, saved.salt.count == 16, saved.verifier.count == 32,
              (100_000...2_000_000).contains(saved.rounds) else { throw VaultError.damaged }
        let dataKey = try readKey()
        do {
            let box = try AES.GCM.SealedBox(combined: saved.ciphertext)
            values = try JSONDecoder().decode([String: String].self, from: AES.GCM.open(box, using: dataKey))
        } catch { throw VaultError.damaged }
        key = dataKey
        envelope = saved
    }

    private func persist(values: [String: String], key: SymmetricKey, salt: Data,
                         rounds: Int, verifier: Data) throws -> Envelope {
        try prepareFolder()
        let box = try AES.GCM.seal(JSONEncoder().encode(values), using: key)
        guard let combined = box.combined else { throw VaultError.damaged }
        let saved = Envelope(version: 2, salt: salt, rounds: rounds, verifier: verifier, ciphertext: combined)
        try writeAtomically(JSONEncoder().encode(saved), to: fileURL)
        return saved
    }

    private func prepareFolder() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard chmod(folder.path, 0o700) == 0 else { throw VaultError.damaged }
    }
    private func writeKey(_ key: SymmetricKey) throws {
        guard !FileManager.default.fileExists(atPath: keyURL.path) else { throw VaultError.damaged }
        try writeAtomically(key.withUnsafeBytes { Data($0) }, to: keyURL)
    }
    private func readKey() throws -> SymmetricKey {
        guard let data = try? Data(contentsOf: keyURL), data.count == 32 else { throw VaultError.damaged }
        return SymmetricKey(data: data)
    }
    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, 0o600) == 0 else { throw VaultError.damaged }
        guard rename(temporary.path, destination.path) == 0 else { throw VaultError.damaged }
    }
    private func randomSalt() -> Data { Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }
    private static func makeVerifier(_ password: String, salt: Data, rounds: Int) throws -> Data {
        let derived = try derive(password, salt: salt, rounds: rounds)
        return Data(HMAC<SHA256>.authenticationCode(for: verificationMessage, using: derived))
    }
    private static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    private static func derive(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let input = Array(password.utf8)
        var output = [UInt8](repeating: 0, count: 32)
        let status = input.withUnsafeBytes { pass in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pass.baseAddress?.assumingMemoryBound(to: Int8.self), input.count,
                                     saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                                     &output, output.count)
            }
        }
        guard status == kCCSuccess else { throw VaultError.damaged }
        return SymmetricKey(data: Data(output))
    }
}
