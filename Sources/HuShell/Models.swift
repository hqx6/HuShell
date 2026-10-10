import Foundation

struct ConnectionProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var identityFile: String = ""
    var usesPassword: Bool = true
    var groupPath: String? = nil
    var importSourceID: String? = nil

    var endpoint: String { "\(username)@\(host)" }
}

enum ProfileValidation {
    static func message(for profile: ConnectionProfile) -> String? {
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入连接名称" }
        if profile.host.isEmpty || profile.host.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) == nil { return "主机地址格式无效" }
        if profile.username.isEmpty || profile.username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) == nil { return "用户名格式无效" }
        if !(1...65535).contains(profile.port) { return "端口需在 1–65535 之间" }
        return nil
    }
}

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let isDirectory: Bool
    let size: String
    let modified: String
    let permissions: String
    var id: String { name }
}

struct HostStats {
    var system = "—"
    var uptime = "—"
    var load = "—"
    var cpu = "—"
    var memoryUsed = "—"
    var memoryTotal = "—"
    var memoryFraction: Double = 0
    var diskUsed = "—"
    var diskTotal = "—"
    var diskFraction: Double = 0
    var cpuUsage: Double = 0
    var swapUsed = "—"
    var swapTotal = "—"
    var swapFraction: Double = 0
    var processes: [HostProcess] = []
    var gpus: [HostGPU] = []
    var disks: [HostDisk] = []
    var networkReceive = "—"
    var networkSend = "—"

    init() {}

    init(output: String) {
        self.init()
        for line in output.split(separator: "\n") where line.hasPrefix("HUSHELL|") {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            switch fields[1] {
            case "system": system = fields[2]
            case "uptime": uptime = fields[2]
            case "load": load = fields[2]
            case "cpu": cpu = fields[2]
            case "cpuUsage": cpuUsage = Double(fields[2]) ?? 0
            case "memory" where fields.count >= 4:
                memoryUsed = fields[2]; memoryTotal = fields[3]
                memoryFraction = Double(fields[2]).flatMap { used in Double(fields[3]).map { $0 > 0 ? used / $0 : 0 } } ?? 0
            case "disk" where fields.count >= 4:
                diskUsed = fields[2]; diskTotal = fields[3]
                diskFraction = Double(fields[2]).flatMap { used in Double(fields[3]).map { $0 > 0 ? used / $0 : 0 } } ?? 0
            case "swap" where fields.count >= 4:
                swapUsed = fields[2]; swapTotal = fields[3]
                swapFraction = Double(fields[2]).flatMap { used in Double(fields[3]).map { $0 > 0 ? used / $0 : 0 } } ?? 0
            case "process" where fields.count >= 6:
                let name = (fields[5] as NSString).lastPathComponent
                processes.append(HostProcess(pid: fields[2], cpu: fields[3], memory: fields[4], command: name))
            case "gpu" where fields.count >= 7:
                guard let index = Int(fields[2]), index >= 0, !fields[3].isEmpty else { break }
                gpus.append(HostGPU(index: index, name: fields[3],
                                    memoryUsedMiB: Double(fields[4]), memoryTotalMiB: Double(fields[5]),
                                    utilization: Double(fields[6])))
            case "mount" where fields.count >= 5:
                disks.append(HostDisk(path: fields[2], used: fields[3], total: fields[4]))
            case "network" where fields.count >= 4:
                networkReceive = fields[2]; networkSend = fields[3]
            default: break
            }
        }
        gpus.sort { $0.index < $1.index }
    }
}

struct HostProcess: Identifiable {
    let pid: String
    let cpu: String
    let memory: String
    let command: String
    var id: String { pid }
}

struct HostGPU: Identifiable {
    let index: Int
    let name: String
    let memoryUsedMiB: Double?
    let memoryTotalMiB: Double?
    let utilization: Double?
    var id: Int { index }
    var memoryFraction: Double {
        guard let memoryUsedMiB, let memoryTotalMiB, memoryTotalMiB > 0 else { return 0 }
        return min(max(memoryUsedMiB / memoryTotalMiB, 0), 1)
    }
    var memoryText: String {
        guard let memoryUsedMiB, let memoryTotalMiB else { return "—" }
        return String(format: "%.1f / %.1f GiB", memoryUsedMiB / 1024, memoryTotalMiB / 1024)
    }
    var utilizationText: String {
        guard let utilization else { return "—" }
        return String(format: "%.0f%%", utilization)
    }
}

struct HostDisk: Identifiable {
    let path: String
    let used: String
    let total: String
    var id: String { path }
    var fraction: Double {
        guard let used = Double(used), let total = Double(total), total > 0 else { return 0 }
        return used / total
    }
}

struct RemoteColumn: Identifiable {
    let path: String
    var files: [RemoteFile]
    var selectedName: String?
    var id: String { path }
}

enum RemotePath {
    static func resolved(_ input: String, relativeTo directory: String, home: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else { return nil }
        let expanded: String
        if trimmed == "~" { expanded = home }
        else if trimmed.hasPrefix("~/") { expanded = home + String(trimmed.dropFirst()) }
        else if trimmed.hasPrefix("/") { expanded = trimmed }
        else { expanded = joined(directory, trimmed) }
        var parts: [String] = []
        for part in expanded.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    static func breadcrumbs(_ path: String) -> [(name: String, path: String)] {
        var result = [(name: "/", path: "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            result.append((String(component), current))
        }
        return result
    }

    static func joined(_ directory: String, _ name: String) -> String {
        let base = directory == "/" ? "" : directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if directory.hasPrefix("/") { return "/\(base.isEmpty ? "" : base + "/")\(name)" }
        return base.isEmpty || base == "." ? name : "\(base)/\(name)"
    }

    static func parent(_ path: String) -> String {
        if path == "/" || path == "." { return path }
        let parts = path.split(separator: "/").dropLast()
        if path.hasPrefix("/") { return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/") }
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
}
