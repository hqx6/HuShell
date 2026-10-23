import XCTest
@testable import HuShell

final class TerminalOutputTests: XCTestCase {
    func testTrimmingHistoryDoesNotResetActiveTerminalOrLoseNewInput() {
        var output = TerminalOutput()
        var delivery = TerminalOutputDelivery()
        output.reset("prompt$ ")
        let initial = delivery.consume(output)
        XCTAssertTrue(initial.clear)
        XCTAssertEqual(initial.text, "prompt$ ")

        output.append(String(repeating: "a", count: 240_000))
        XCTAssertFalse(delivery.consume(output).clear)
        output.append(String(repeating: "b", count: 20_000))
        XCTAssertGreaterThan(output.offset, 0)
        let newInput = delivery.consume(output)
        XCTAssertFalse(newInput.clear, "Trimming scrollback must not clear a prompt being edited")
        XCTAssertEqual(newInput.text, String(repeating: "b", count: 20_000))

        output.reset("new connection")
        let reconnected = delivery.consume(output)
        XCTAssertTrue(reconnected.clear)
        XCTAssertEqual(reconnected.text, "new connection")
    }

    func testTerminalRemembersGridSizeBeforeSSHStarts() {
        let terminal = TerminalSession()
        terminal.resize(columns: 137, rows: 39)
        XCTAssertEqual(terminal.columns, 137)
        XCTAssertEqual(terminal.rows, 39)
        terminal.resize(columns: 0, rows: 0)
        XCTAssertEqual(terminal.columns, 137)
        XCTAssertEqual(terminal.rows, 39)
    }
}
