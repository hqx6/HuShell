import AppKit
import SwiftUI
import XCTest
@testable import HuShell

@MainActor
final class HostMonitorViewTests: XCTestCase {
    func testGPUAndNPUStartCollapsedAndCanBeExpanded() {
        let tab = ConnectionTab(profile: ConnectionProfile(name: "test", host: "localhost", username: "test"),
                                transferCenter: TransferCenter())
        XCTAssertFalse(tab.monitoredSections.contains(.gpu))
        XCTAssertEqual(tab.monitoredSections, Set(HostMonitorSection.allCases).subtracting([.gpu]))

        tab.toggleMonitorSection(.gpu)
        XCTAssertTrue(tab.monitoredSections.contains(.gpu))
        tab.toggleMonitorSection(.gpu)
        XCTAssertFalse(tab.monitoredSections.contains(.gpu))
    }

    func testSidebarUsesOnlyThinCustomScrollbarAndRemainsScrollable() throws {
        let frame = NSRect(x: 0, y: 0, width: 335, height: 180)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let hosting = NSHostingView(rootView: EmptyHostMonitorView())
        hosting.frame = frame
        window.contentView = hosting
        window.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for child in view.subviews {
                if let found = findScrollView(in: child) { return found }
            }
            return nil
        }

        let scrollView = try XCTUnwrap(findScrollView(in: hosting))
        XCTAssertFalse(scrollView.hasVerticalScroller)
        let clipView = scrollView.contentView
        let initialY = clipView.bounds.origin.y
        clipView.scroll(to: NSPoint(x: 0, y: initialY + 40))
        scrollView.reflectScrolledClipView(clipView)
        XCTAssertGreaterThan(clipView.bounds.origin.y, initialY)
    }
}
