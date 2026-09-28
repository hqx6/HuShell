import Foundation
import CommonCrypto
import CryptoKit

struct FinalShellImport {
    struct Entry {
        var profile: ConnectionProfile
        let password: String
    }
    let entries: [Entry]
    let groups: [String]

    init(directory: URL) throws {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: directory, includingPropertiesForKeys: nil) else {
            throw ImportError.invalidConfiguration
        }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        var folders: [String: (String, String)] = [:]
        for file in files where file.lastPathComponent == "folder.json" {
            let data = try Self.object(file)
            if (data["delete_time"] as? NSNumber)?.int64Value ?? 0 != 0 { continue }
            guard let id = data["id"] as? String, let name = data["name"] as? String else { throw ImportError.invalidConfiguration }
            folders[id] = (name, data["parent_id"] as? String ?? "root")
        }
        func path(_ id: String, seen: Set<String> = []) throws -> String? {
            if id == "root" || id.isEmpty { return nil }
            guard !seen.contains(id), let folder = folders[id] else { throw ImportError.invalidConfiguration }
            let parent = try path(folder.1, seen: seen.union([id]))
            return parent.map { $0 + "/" + folder.0 } ?? folder.0
        }
        groups = try folders.keys.map { try path($0)! }.sorted()
        var result: [Entry] = []
        for file in files.sorted(by: { $0.path < $1.path }) where file.lastPathComponent.hasSuffix("_connect_config.json") {
            let data = try Self.object(file)
            if (data["delete_time"] as? NSNumber)?.int64Value ?? 0 != 0 { continue }
            guard (data["conection_type"] as? Int) == 100 else { continue }
            guard (data["authentication_type"] as? Int) == 1,
                  let name = data["name"] as? String, let host = data["host"] as? String,
                  let user = data["user_name"] as? String, let sourceID = data["id"] as? String,
                  let encrypted = data["password"] as? String else { throw ImportError.invalidConfiguration }
            var profile = ConnectionProfile(name: name, host: host, port: data["port"] as? Int ?? 22, username: user)
            profile.groupPath = try path(data["parent_id"] as? String ?? "root")
            profile.importSourceID = "finalshell:" + sourceID
            guard ProfileValidation.message(for: profile) == nil else { throw ImportError.invalidConfiguration }
            result.append(Entry(profile: profile, password: try Self.decodePassword(encrypted)))
        }
        entries = result
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else { throw ImportError.invalidConfiguration }
        return value
    }

    // FinalShell's legacy Java Random + MD5 + DES format. Plaintext is kept in memory only.
    // Format reference: github.com/jas502n/FinalShellDecodePass
    static func decodePassword(_ encoded: String) throws -> String {
        if encoded.isEmpty { return "" }
        guard let raw = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters), raw.count >= 16,
              (raw.count - 8) % 8 == 0 else { throw ImportError.passwordFormat }
        let header = Array(raw.prefix(8)).map { Int64(Int8(bitPattern: $0)) }
        var seedRandom = JavaRandom(seed: header[5])
        let divisor = seedRandom.nextInt(127)
        guard divisor != 0 else { throw ImportError.passwordFormat }
        var random = JavaRandom(seed: 3680984568597093857 / divisor)
        for _ in 0..<max(0, Int(header[0])) { _ = random.nextLong() }
        var second = JavaRandom(seed: random.nextLong())
        let numbers = [header[4], second.nextLong(), header[7], header[3], second.nextLong(), header[1], random.nextLong(), header[2]]
        var material = Data()
        for number in numbers {
            var value = number.bigEndian
            withUnsafeBytes(of: &value) { material.append(contentsOf: $0) }
        }
        let key = Array(Insecure.MD5.hash(data: material).prefix(8))
        let ciphertext = Array(raw.dropFirst(8))
        var plaintext = [UInt8](repeating: 0, count: ciphertext.count + 8)
        var count = 0
        let status = key.withUnsafeBytes { keyBytes in
            ciphertext.withUnsafeBytes { bytes in
                plaintext.withUnsafeMutableBytes { output in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding), keyBytes.baseAddress,
                            kCCKeySizeDES, nil, bytes.baseAddress, bytes.count, output.baseAddress, output.count, &count)
                }
            }
        }
        guard status == kCCSuccess, let password = String(bytes: plaintext.prefix(count), encoding: .utf8),
              !password.contains("\0") else { throw ImportError.passwordFormat }
        return password
    }

    private struct JavaRandom {
        var seed: UInt64
        init(seed: Int64) { self.seed = (UInt64(bitPattern: seed) ^ 0x5DEECE66D) & ((1 << 48) - 1) }
        mutating func next(_ bits: Int) -> UInt64 {
            seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
            return seed >> (48 - bits)
        }
        mutating func nextInt(_ bound: Int64) -> Int64 {
            while true {
                let bits = Int64(next(31)), value = bits % bound
                if bits - value + bound - 1 <= Int64(Int32.max) { return value }
            }
        }
        mutating func nextLong() -> Int64 {
            let high = Int64(Int32(bitPattern: UInt32(next(32))))
            let low = Int64(Int32(bitPattern: UInt32(next(32))))
            return (high &<< 32) &+ low
        }
    }
}

enum ImportError: LocalizedError {
    case invalidConfiguration, passwordFormat
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "FinalShell 配置、分组或认证方式不受支持，未执行导入"
        case .passwordFormat: return "FinalShell 密码无法解码，未执行导入"
        }
    }
}
