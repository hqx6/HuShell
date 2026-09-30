import Foundation

enum RemoteFileSortKey: String, CaseIterable {
    case name = "名称"
    case size = "大小"
    case modified = "修改时间"
}

struct RemoteFileSort {
    var key: RemoteFileSortKey = .name
    var ascending = true

    mutating func select(_ newKey: RemoteFileSortKey) {
        if key == newKey { ascending.toggle() }
        else { key = newKey; ascending = newKey != .modified }
    }

    func files(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { left, right in
            if left.isDirectory != right.isDirectory { return left.isDirectory }
            let comparison: ComparisonResult
            switch key {
            case .name:
                comparison = left.name.localizedStandardCompare(right.name)
            case .size:
                let a = Int64(left.size) ?? 0
                let b = Int64(right.size) ?? 0
                comparison = a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
            case .modified:
                comparison = left.modified.compare(right.modified)
            }
            if comparison == .orderedSame {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}

enum RemoteFileDate {
    private static let months = ["Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
                                 "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12]

    static func normalized(_ raw: String, now: Date = Date()) -> String {
        let parts = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if parts.count == 2, parts[0].range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
           parts[1].range(of: #"^\d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil {
            return parts.joined(separator: " ")
        }
        guard parts.count == 3, let month = months[parts[0]], let day = Int(parts[1]),
              (1...31).contains(day) else { return raw }
        let year: Int
        var time = "00:00:00"
        if parts[2].contains(":") {
            let clock = parts[2].split(separator: ":")
            guard clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]),
                  (0...23).contains(hour), (0...59).contains(minute) else { return raw }
            time = String(format: "%02d:%02d:00", hour, minute)
            let calendar = Calendar.current
            let currentYear = calendar.component(.year, from: now)
            let candidate = calendar.date(from: DateComponents(year: currentYear, month: month, day: day,
                                                               hour: hour, minute: minute)) ?? now
            year = candidate > now.addingTimeInterval(86_400) ? currentYear - 1 : currentYear
        } else {
            guard let value = Int(parts[2]) else { return raw }
            year = value
        }
        return String(format: "%04d-%02d-%02d %@", year, month, day, time)
    }
}
