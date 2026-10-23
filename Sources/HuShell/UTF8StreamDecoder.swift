struct UTF8StreamDecoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: ArraySlice<UInt8>) -> String {
        var combined = pending
        combined.append(contentsOf: bytes)
        let incompleteCount = Self.incompleteSuffixLength(combined)
        let completeCount = combined.count - incompleteCount
        pending = Array(combined[completeCount...])
        return String(decoding: combined[..<completeCount], as: UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding: pending, as: UTF8.self)
    }

    private static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        guard !bytes.isEmpty else { return 0 }
        var lead = bytes.count - 1
        while lead >= 0 && bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        guard lead >= 0 else { return 0 }
        let first = bytes[lead]
        let expectedLength: Int
        switch first {
        case 0xC2...0xDF: expectedLength = 2
        case 0xE0...0xEF: expectedLength = 3
        case 0xF0...0xF4: expectedLength = 4
        default: return 0
        }
        let length = bytes.count - lead
        return length < expectedLength ? length : 0
    }
}
