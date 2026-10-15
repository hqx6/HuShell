import AppKit
import SwiftUI
import XCTest
@testable import HuShell

@MainActor
final class TransferCenterViewTests: XCTestCase {
    func testTransferRowOpensItsRemoteDirectory() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("file".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let profile = ConnectionProfile(name: "test", host: "127.0.0.1", port: 1, username: "test")
        let center = TransferCenter()
        center.upload(profile: profile, local: source, remote: "/data/jobs/" + source.lastPathComponent) { _ in }
        center.cancelAll()
        var opened: (ConnectionProfile, String)?
        var openCount = 0
        let frame = NSRect(x: 0, y: 0, width: 470, height: 420)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: TransferCenterView(center: center) { id, path in
            opened = (id, path)
            openCount += 1
        })
        hosting.frame = frame
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        for x in [CGFloat(90), CGFloat(430)] {
            for eventType in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: eventType,
                    location: NSPoint(x: x, y: 330), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(openCount, 2)
        XCTAssertEqual(opened?.0, profile)
        XCTAssertEqual(opened?.1, "/data/jobs")
    }
}
