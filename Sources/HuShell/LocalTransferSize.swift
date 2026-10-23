import Foundation

enum LocalTransferSize {
    static func directory(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let entries = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return 0
        }
        var total: Int64 = 0
        for case let entry as URL in entries {
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true, let size = values.fileSize {
                total = total > Int64.max - Int64(size) ? Int64.max : total + Int64(size)
            }
        }
        return total
    }
}
