import Foundation
import Darwin

enum SSHError: LocalizedError {
    case launch(String)
    case command(String)
    case cancelled
    case invalidPath
    case unsafeTarget
    var errorDescription: String? {
        switch self {
        case .launch(let value): return "无法启动 SSH：\(value)"
        case .command(let value): return value.isEmpty ? "远程操作失败" : value
        case .cancelled: return "传输已终止"
        case .invalidPath: return "文件路径包含不支持的换行符"
        case .unsafeTarget: return "不能删除根目录或上级目录"
        }
    }
}

final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldStop = cancelled
        lock.unlock()
        if shouldStop && process.isRunning { process.terminate() }
    }

    func detach(_ process: Process) {
        lock.lock()
        if self.process === process { self.process = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { process.terminate() }
    }
}

enum SSHService {
    static func environment(for profile: ConnectionProfile) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = Bundle.main.executablePath ?? CommandLine.arguments[0]
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["DISPLAY"] = ":0"
        environment["HUSHELL_CREDENTIAL_ID"] = profile.id.uuidString
        environment["HUSHELL_BROKER_SOCKET"] = CredentialBroker.shared.socketPath
        environment["HUSHELL_BROKER_TOKEN"] = CredentialBroker.shared.token
        environment["LC_ALL"] = "C"
        environment["TERM"] = "xterm-256color"
        return environment
    }

    static func options(for profile: ConnectionProfile) -> [String] {
        var args = ["-o", "BatchMode=no", "-o", "ConnectTimeout=12", "-o", "ServerAliveInterval=20",
                    "-o", "StrictHostKeyChecking=accept-new", "-o", "NumberOfPasswordPrompts=1"]
        args += knownHostsOptions()
        if profile.usesPassword { args += ["-o", "PreferredAuthentications=password,keyboard-interactive"] }
        if !profile.identityFile.isEmpty { args += ["-i", profile.identityFile] }
        return args
    }

    static func run(_ executable: String, args: [String], profile: ConnectionProfile,
                    input: Data? = nil, timeout: TimeInterval? = 45,
                    cancellation: TransferCancellation? = nil) throws -> String {
        if cancellation?.isCancelled == true { throw SSHError.cancelled }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment(for: profile)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        if let input {
            let source = Pipe()
            process.standardInput = source
            try process.run()
            source.fileHandleForWriting.write(input)
            try? source.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        cancellation?.attach(process)
        defer { cancellation?.detach(process) }
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if cancellation?.isCancelled == true { throw SSHError.cancelled }
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SSHError.command(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return text
    }

    static func stats(profile: ConnectionProfile) throws -> HostStats {
        let script = #"""
        printf 'HUSHELL|system|'; uname -srm
        printf 'HUSHELL|uptime|'; uptime -p 2>/dev/null || uptime
        printf 'HUSHELL|load|'; if [ -r /proc/loadavg ]; then awk '{print $1 " " $2 " " $3}' /proc/loadavg; else sysctl -n vm.loadavg 2>/dev/null | tr -d '{}'; fi; printf '\n'
        printf 'HUSHELL|cpu|'; (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null) | head -1
        if [ -r /proc/meminfo ]; then
          awk '/MemTotal:/ {t=$2} /MemAvailable:/ {a=$2} /SwapTotal:/ {st=$2} /SwapFree:/ {sf=$2} END {if (t>0) printf "HUSHELL|memory|%.0f|%.0f\n", (t-a)/1024, t/1024; if (st>0) printf "HUSHELL|swap|%.0f|%.0f\n", (st-sf)/1024, st/1024}' /proc/meminfo
        elif [ "$(uname -s)" = Darwin ]; then
          vm_stat | awk -v page="$(sysctl -n hw.pagesize)" -v total="$(sysctl -n hw.memsize)" '/Pages free:/ {free=$3} /Pages inactive:/ {inactive=$3} /Pages speculative:/ {speculative=$3} END {if (total>0) printf "HUSHELL|memory|%.0f|%.0f\n", (total-(free+inactive+speculative)*page)/1048576, total/1048576}'
          sysctl -n vm.swapusage | awk '{used=$6; total=$3; gsub(/M/, "", used); gsub(/M/, "", total); if (total>0) printf "HUSHELL|swap|%.0f|%.0f\n", used, total}'
          top -l 1 -n 0 | awk '/CPU usage:/ {u=$3; s=$5; gsub(/%/, "", u); gsub(/%/, "", s); printf "HUSHELL|cpuUsage|%.0f\n", u+s}'
        fi
        df -Pk / 2>/dev/null | awk 'NR==2 {printf "HUSHELL|disk|%.1f|%.1f\n", $3/1048576, $2/1048576}'
        df -Pk 2>/dev/null | awk 'NR>1 && $2>0 {printf "HUSHELL|mount|%s|%.1f|%.1f\n", $NF, $3/1048576, $2/1048576}' | head -14
        ps -eo pid=,pcpu=,rss=,comm= 2>/dev/null | sort -k2nr | head -5 | awk '{memory=$3>=1048576 ? sprintf("%.1fG",$3/1048576) : sprintf("%.0fM",$3/1024); command=$4; for (i=5;i<=NF;i++) command=command " " $i; printf "HUSHELL|process|%s|%s|%s|%s\n", $1, $2, memory, command}'
        if [ -r /proc/stat ]; then
          read _ u1 n1 s1 i1 w1 x1 y1 z1 rest < /proc/stat
          net1=$(awk -F: 'NR>2 {name=$1; gsub(/ /,"",name); if (name=="lo") next; gsub(/^ +/, "", $2); split($2,a,/ +/); rx+=a[1]; tx+=a[9]} END {printf "%.0f %.0f", rx, tx}' /proc/net/dev)
          sleep 0.3
          read _ u2 n2 s2 i2 w2 x2 y2 z2 rest < /proc/stat
          total1=$((u1+n1+s1+i1+w1+x1+y1+z1)); total2=$((u2+n2+s2+i2+w2+x2+y2+z2))
          idle1=$((i1+w1)); idle2=$((i2+w2)); delta=$((total2-total1))
          if [ "$delta" -gt 0 ]; then awk -v d="$delta" -v idle="$((idle2-idle1))" 'BEGIN {printf "HUSHELL|cpuUsage|%.0f\n", 100*(d-idle)/d}'; fi
          net2=$(awk -F: 'NR>2 {name=$1; gsub(/ /,"",name); if (name=="lo") next; gsub(/^ +/, "", $2); split($2,a,/ +/); rx+=a[1]; tx+=a[9]} END {printf "%.0f %.0f", rx, tx}' /proc/net/dev)
          set -- $net1 $net2; awk -v rx1="$1" -v tx1="$2" -v rx2="$3" -v tx2="$4" 'BEGIN {printf "HUSHELL|network|%.0f|%.0f\n", (rx2-rx1)/0.3, (tx2-tx1)/0.3}'
        elif [ "$(uname -s)" = Darwin ]; then
          net1=$(netstat -ibn | awk '$3 ~ /^<Link/ && $1 !~ /^(lo|gif|stf)/ {rx+=$7; tx+=$10} END {printf "%.0f %.0f", rx, tx}')
          sleep 0.3
          net2=$(netstat -ibn | awk '$3 ~ /^<Link/ && $1 !~ /^(lo|gif|stf)/ {rx+=$7; tx+=$10} END {printf "%.0f %.0f", rx, tx}')
          set -- $net1 $net2; awk -v rx1="$1" -v tx1="$2" -v rx2="$3" -v tx2="$4" 'BEGIN {printf "HUSHELL|network|%.0f|%.0f\n", (rx2-rx1)/0.3, (tx2-tx1)/0.3}'
        fi
        """#
        let args = options(for: profile) + ["-p", String(profile.port), profile.endpoint, "sh -c " + shellQuote(script)]
        return HostStats(output: try run("/usr/bin/ssh", args: args, profile: profile))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func sftpQuote(_ value: String) throws -> String {
        guard !value.contains("\n"), !value.contains("\r") else { throw SSHError.invalidPath }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func sftp(profile: ConnectionProfile, command: String, transfer: Bool = false,
                     cancellation: TransferCancellation? = nil) throws -> String {
        let args = ["-o", "BatchMode=no", "-o", "ConnectTimeout=12", "-o", "StrictHostKeyChecking=accept-new",
                    "-o", "NumberOfPasswordPrompts=1", "-o", "ServerAliveInterval=15",
                    "-o", "ServerAliveCountMax=3", "-P", String(profile.port)]
            + knownHostsOptions()
            + (profile.identityFile.isEmpty ? [] : ["-i", profile.identityFile])
            + ["-b", "-", profile.endpoint]
        return try run("/usr/bin/sftp", args: args, profile: profile,
                       input: Data((command + "\n").utf8), timeout: transfer ? nil : 45,
                       cancellation: cancellation)
    }

    static func list(profile: ConnectionProfile, path: String) throws -> [RemoteFile] {
        let result = try sftp(profile: profile, command: "ls -la " + sftpQuote(path))
        return try parseListing(result)
    }

    static func listDirectory(profile: ConnectionProfile, path: String) throws -> [RemoteFile] {
        // GNU ls exposes seconds. SFTP's human-readable listing only exposes minutes.
        // Retain SFTP for servers without a compatible remote shell or GNU ls.
        let command = "cd " + shellQuote(path)
            + " && LC_ALL=C ls -la --color=never --time-style='+%Y-%m-%d %H:%M:%S' -- ."
        if let result = try? runRemote(profile: profile, command: command) {
            return try parseListing(result)
        }
        let result = try sftp(profile: profile, command: "cd " + sftpQuote(path) + "\nls -la .")
        return try parseListing(result)
    }

    static func workingDirectory(profile: ConnectionProfile) throws -> String {
        let output = try sftp(profile: profile, command: "pwd")
        guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("Remote working directory: ") }) else {
            throw SSHError.command("无法读取远端绝对路径")
        }
        let path = String(line.dropFirst("Remote working directory: ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw SSHError.command("远端返回的路径不是绝对路径") }
        return path
    }

    static func parseListing(_ result: String) throws -> [RemoteFile] {
        let pattern = #"^([dlcbps-][rwxstST-]{9}[+@.]?)\s+\S+\s+\S+\s+\S+\s+(\d+)\s+((?:\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})|(?:\S+\s+\S+\s+\S+))\s+(.+)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        return result.split(separator: "\n").compactMap { line in
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            guard let match = regex.firstMatch(in: value, range: range) else { return nil }
            func group(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: value) else { return "" }
                return String(value[range])
            }
            let fullName = group(4).components(separatedBy: " -> ")[0]
            let name = String(fullName.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
            guard name != ".", name != ".." else { return nil }
            return RemoteFile(name: name, isDirectory: group(1).hasPrefix("d"),
                              size: group(2), modified: RemoteFileDate.normalized(group(3)), permissions: group(1))
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func download(profile: ConnectionProfile, remote: String, local: URL,
                         cancellation: TransferCancellation? = nil) throws {
        _ = try sftp(profile: profile, command: "get " + sftpQuote(remote) + " " + sftpQuote(local.path),
                     transfer: true, cancellation: cancellation)
    }

    static func upload(profile: ConnectionProfile, local: URL, remote: String,
                       cancellation: TransferCancellation? = nil) throws {
        _ = try sftp(profile: profile, command: "put " + sftpQuote(local.path) + " " + sftpQuote(remote),
                     transfer: true, cancellation: cancellation)
    }

    static func remoteFileSize(profile: ConnectionProfile, path: String) throws -> Int64 {
        let quoted = shellQuote(path)
        let command = "stat -c %s -- \(quoted) 2>/dev/null || stat -f %z \(quoted) 2>/dev/null"
        let args = options(for: profile) + ["-p", String(profile.port), profile.endpoint, command]
        let result = try run("/usr/bin/ssh", args: args, profile: profile, timeout: 12)
        guard let size = Int64(result.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SSHError.command("无法读取远端文件大小")
        }
        return size
    }

    static func makeDirectory(profile: ConnectionProfile, path: String) throws {
        _ = try sftp(profile: profile, command: "mkdir " + sftpQuote(path))
    }

    static func rename(profile: ConnectionProfile, from: String, to: String) throws {
        _ = try sftp(profile: profile, command: "rename " + sftpQuote(from) + " " + sftpQuote(to))
    }

    static func remove(profile: ConnectionProfile, path: String, isDirectory: Bool) throws {
        guard safeTargetPath(path) else { throw SSHError.unsafeTarget }
        _ = try sftp(profile: profile, command: (isDirectory ? "rmdir " : "rm ") + sftpQuote(path))
    }

    static func fastRemove(profile: ConnectionProfile, path: String) throws {
        guard safeTargetPath(path) else { throw SSHError.unsafeTarget }
        _ = try runRemote(profile: profile, command: "rm -rf -- " + shellQuote(path))
    }

    private static func safeTargetPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.contains("\n") && !path.contains("\r") &&
        !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    static func changePermissions(profile: ConnectionProfile, path: String, mode: String) throws {
        guard mode.range(of: "^[0-7]{3,4}$", options: .regularExpression) != nil else {
            throw SSHError.command("权限须为 3 或 4 位八进制数字")
        }
        _ = try sftp(profile: profile, command: "chmod \(mode) " + sftpQuote(path))
    }

    static func createFile(profile: ConnectionProfile, path: String) throws {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("hushell-empty-\(UUID().uuidString)")
        try Data().write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        try upload(profile: profile, local: local, remote: path)
    }

    static func createArchive(profile: ConnectionProfile, source: String) throws -> String {
        let archive = "/tmp/hushell-\(UUID().uuidString).tar.gz"
        let parent = RemotePath.parent(source)
        let name = (source as NSString).lastPathComponent
        _ = try runRemote(profile: profile,
                          command: "tar -czf \(shellQuote(archive)) -C \(shellQuote(parent)) \(shellQuote(name))")
        return archive
    }

    static func removeArchive(profile: ConnectionProfile, path: String) {
        _ = try? runRemote(profile: profile, command: "rm -f -- " + shellQuote(path))
    }

    private static func runRemote(profile: ConnectionProfile, command: String) throws -> String {
        let args = options(for: profile) + ["-p", String(profile.port), profile.endpoint, command]
        return try run("/usr/bin/ssh", args: args, profile: profile)
    }

    private static func knownHostsOptions() -> [String] {
        guard let path = ProcessInfo.processInfo.environment["HUSHELL_KNOWN_HOSTS_FILE"], !path.isEmpty else { return [] }
        return ["-o", "UserKnownHostsFile=\(path)"]
    }
}

final class TerminalSession {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var process: Process?
    private var master: Int32 = -1
    private var generation = 0

    func start(profile: ConnectionProfile) throws {
        stop()
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw SSHError.launch("无法创建伪终端") }
        master = masterFD
        let slave = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = SSHService.options(for: profile) + ["-tt", "-p", String(profile.port), profile.endpoint]
        process.environment = SSHService.environment(for: profile)
        process.standardInput = slave
        process.standardOutput = slave
        process.standardError = slave
        do { try process.run() }
        catch {
            close(masterFD); close(slaveFD); master = -1
            throw SSHError.launch(error.localizedDescription)
        }
        close(slaveFD)
        self.process = process
        let currentGeneration = generation
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard self?.generation == currentGeneration else { return }
                self?.onExit?(process.terminationStatus)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            while let self, self.master == masterFD, self.generation == currentGeneration {
                let count = Darwin.read(masterFD, &buffer, buffer.count)
                if count <= 0 { break }
                let output = String(decoding: buffer[..<count], as: UTF8.self)
                DispatchQueue.main.async {
                    guard self.generation == currentGeneration else { return }
                    self.onOutput?(output)
                }
            }
        }
    }

    func send(_ text: String) {
        guard master >= 0 else { return }
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress, bytes.count) }
    }

    func resize(columns: Int, rows: Int) {
        guard master >= 0, columns > 0, rows > 0 else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: columns), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    func stop() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        if master >= 0 { close(master); master = -1 }
    }

    deinit { stop() }
}

enum Askpass {
    static func handleIfRequested() -> Bool {
        guard CommandLine.arguments.dropFirst().first == "--askpass" ||
                ProcessInfo.processInfo.environment["HUSHELL_CREDENTIAL_ID"] != nil &&
                ProcessInfo.processInfo.environment["SSH_ASKPASS"] == Bundle.main.executablePath else { return false }
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").lowercased()
        guard prompt.contains("password"),
              let raw = ProcessInfo.processInfo.environment["HUSHELL_CREDENTIAL_ID"],
              let id = UUID(uuidString: raw),
              let path = ProcessInfo.processInfo.environment["HUSHELL_BROKER_SOCKET"],
              let token = ProcessInfo.processInfo.environment["HUSHELL_BROKER_TOKEN"],
              let password = CredentialBroker.request(path: path, token: token, id: id) else { exit(1) }
        print(password)
        exit(0)
    }
}
