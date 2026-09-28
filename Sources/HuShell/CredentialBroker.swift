import Foundation
import Darwin

/// Keeps unlocked passwords in this process and serves SSH_ASKPASS over a private Unix socket.
/// The password never appears in process arguments, environment variables, or a temporary file.
final class CredentialBroker {
    static let shared = CredentialBroker()

    let socketPath: String
    let token = UUID().uuidString
    private var listener: Int32 = -1
    private let lock = NSLock()
    private let prepareLock = NSLock()
    private var passwords: [UUID: String] = [:]

    private init() {
        socketPath = "/private/tmp/hushell-\(getpid())-\(UUID().uuidString.prefix(8)).sock"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, let address = Self.address(socketPath), Self.bind(fd, address) == 0,
              Darwin.listen(fd, 16) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            unlink(socketPath)
            return
        }
        listener = fd
        _ = chmod(socketPath, 0o600)
        atexit { unlink(CredentialBroker.shared.socketPath) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
    }

    func prepare(_ profile: ConnectionProfile) throws {
        guard profile.usesPassword else { return }
        guard listener >= 0 else { throw SSHError.launch("无法建立本机凭据通道") }
        prepareLock.lock()
        defer { prepareLock.unlock() }
        lock.lock()
        let cached = passwords[profile.id] != nil
        lock.unlock()
        if cached { return }
        guard let password = try LocalCredentialVault.shared.password(for: profile.id) else {
            throw VaultError.missingCredential
        }
        lock.lock()
        passwords[profile.id] = password
        lock.unlock()
    }

    func invalidate(_ id: UUID) {
        lock.lock()
        passwords.removeValue(forKey: id)
        lock.unlock()
    }

    #if DEBUG
    func cacheForTesting(_ password: String, for id: UUID) {
        lock.lock()
        passwords[id] = password
        lock.unlock()
    }
    #endif

    private func serve() {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 { break }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
                Darwin.close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        guard let request = Self.readLine(client) else { return }
        let parts = request.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == token, let id = UUID(uuidString: String(parts[0])) else { return }
        lock.lock()
        let password = passwords[id]
        lock.unlock()
        guard let password else { return }
        let bytes = Array((password + "\n").utf8)
        Self.writeAll(client, bytes)
    }

    static func request(path: String, token: String, id: UUID) -> String? {
        let client = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard client >= 0, let address = address(path) else { return nil }
        defer { Darwin.close(client) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        guard connect(client, address) == 0 else { return nil }
        let request = Array("\(id.uuidString)|\(token)\n".utf8)
        writeAll(client, request)
        return readLine(client)
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 16_384 {
            let count = Darwin.read(fd, &byte, 1)
            if count <= 0 { break }
            if byte == 10 { break }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count <= 0 { break }
                written += count
            }
        }
    }

    private static func address(_ path: String) -> sockaddr_un? {
        let bytes = Array(path.utf8) + [UInt8(0)]
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination -> Void in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
        return address
    }

    private static func bind(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func connect(_ fd: Int32, _ address: sockaddr_un) -> Int32 {
        var address = address
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    deinit {
        if listener >= 0 { Darwin.close(listener); unlink(socketPath) }
    }
}
