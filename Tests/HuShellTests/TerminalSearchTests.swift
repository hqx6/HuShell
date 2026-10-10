import AppKit
import WebKit
import XCTest
@testable import HuShell

@MainActor
final class TerminalSearchTests: XCTestCase {
    func testFindOverlayNavigatesTerminalBufferWithoutSendingInput() throws {
        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/HuShell/Resources")
        let webView = SearchableTerminalWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        var sentInput = false
        let inputHandler = InputHandler { sentInput = true }
        webView.configuration.userContentController.add(inputHandler, name: "input")
        webView.configuration.userContentController.add(inputHandler, name: "resize")
        webView.loadFileURL(resources.appendingPathComponent("terminal.html"), allowingReadAccessTo: resources)

        func evaluate(_ script: String) throws -> Any? {
            var result: Any?
            var failure: Error?
            var complete = false
            webView.evaluateJavaScript(script) { value, error in
                result = value
                failure = error
                complete = true
            }
            let deadline = Date().addingTimeInterval(8)
            while !complete && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            XCTAssertTrue(complete, "JavaScript execution timed out")
            if let failure { throw failure }
            return result
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if (try? evaluate("typeof window.huOpenFind === 'function'")) as? Bool == true { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(try evaluate("typeof window.huOpenFind") as? String, "function")
        _ = try evaluate("window.huAppend('alpha first\\r\\nbeta\\r\\nalpha second\\r\\n' + Array(80).fill('later').join('\\r\\n') + '\\r\\n')")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let bottomViewport = try XCTUnwrap(try evaluate("terminal.buffer.active.viewportY") as? Int)
        let findKey = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        XCTAssertTrue(webView.performKeyEquivalent(with: findKey))
        _ = try evaluate("document.getElementById('find-input').value='alpha'; document.getElementById('find-input').dispatchEvent(new Event('input'))")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(try evaluate("document.getElementById('find-count').textContent") as? String, "1/2")
        XCTAssertEqual(try evaluate("document.activeElement.id") as? String, "find-input")
        XCTAssertEqual(try evaluate("terminal.getSelection()") as? String, "alpha")
        XCTAssertLessThan(try XCTUnwrap(try evaluate("terminal.buffer.active.viewportY") as? Int), bottomViewport)
        _ = try evaluate("document.getElementById('find-input').dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', bubbles:true}))")
        XCTAssertEqual(try evaluate("document.getElementById('find-count').textContent") as? String, "2/2")
        _ = try evaluate("document.getElementById('find-input').dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', shiftKey:true, bubbles:true}))")
        XCTAssertEqual(try evaluate("document.getElementById('find-count').textContent") as? String, "1/2")
        _ = try evaluate("document.getElementById('find-input').dispatchEvent(new KeyboardEvent('keydown', {key:'Escape', bubbles:true}))")
        XCTAssertEqual(try evaluate("document.getElementById('find').hidden") as? Bool, true)
        XCTAssertFalse(sentInput)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "input")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "resize")
    }
}

private final class InputHandler: NSObject, WKScriptMessageHandler {
    let onInput: () -> Void
    init(onInput: @escaping () -> Void) { self.onInput = onInput }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "input" { onInput() }
    }
}
