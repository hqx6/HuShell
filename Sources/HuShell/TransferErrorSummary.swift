import Foundation

enum TransferErrorSummary {
    static func upload(_ error: Error) -> String {
        summarize(error, action: "上传")
    }

    static func delete(_ error: Error) -> String {
        summarize(error, action: "删除")
    }

    private static func summarize(_ error: Error, action: String) -> String {
        let detail = error.localizedDescription
        let lowercased = detail.lowercased()

        if lowercased.contains("permission denied") || lowercased.contains("operation not permitted") {
            return "权限不足，无法\(action)"
        }
        if lowercased.contains("read-only file system") {
            return "目标文件系统为只读，无法\(action)"
        }
        if lowercased.contains("no space left on device") || lowercased.contains("disk quota exceeded") {
            return "目标磁盘空间不足，无法\(action)"
        }
        if lowercased.contains("no such file or directory") {
            return action == "上传" ? "本地文件或远端目录不存在" : "文件或目录不存在"
        }
        if action == "删除" && lowercased.contains("directory not empty") {
            return "文件夹非空，无法删除；可使用快速删除"
        }
        if lowercased.contains("not a directory") {
            return "目标路径不是文件夹"
        }
        if lowercased.contains("connection closed") || lowercased.contains("connection reset") ||
            lowercased.contains("broken pipe") {
            return "连接已断开，\(action)未完成"
        }

        let lines = detail.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("sftp>") && !$0.hasPrefix("Uploading ") &&
                !$0.hasPrefix("Connected to ") }
        guard let last = lines.last else { return "\(action)失败" }
        let limit = 100
        let brief = last.count > limit ? String(last.prefix(limit)) + "…" : last
        return "\(action)失败：\(brief)"
    }
}
