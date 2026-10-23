import Foundation

struct TerminalOutput {
    private(set) var text = ""
    private(set) var offset = 0
    private(set) var length = 0
    private(set) var epoch = 0

    mutating func reset(_ initial: String) {
        epoch &+= 1
        text = initial
        offset = 0
        length = initial.unicodeScalars.count
    }

    mutating func append(_ chunk: String) {
        text += chunk
        length += chunk.unicodeScalars.count
        guard length > 250_000 else { return }
        let removed = length - 200_000
        let scalars = text.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: removed)
        text = String(scalars[start...])
        offset += removed
        length = 200_000
    }

    func suffix(after position: Int) -> String? {
        guard position >= offset, position <= offset + length else { return nil }
        let scalars = text.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: position - offset)
        return String(scalars[start...])
    }
}

struct TerminalOutputDelivery {
    private(set) var epoch: Int?
    private(set) var position = 0

    mutating func consume(_ output: TerminalOutput) -> (clear: Bool, text: String) {
        if epoch != output.epoch {
            epoch = output.epoch
            position = output.offset + output.length
            return (true, output.text)
        }
        let delta = output.suffix(after: position)
        position = output.offset + output.length
        return delta.map { (false, $0) } ?? (true, output.text)
    }
}
