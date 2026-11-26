import XCTest
import AppKit
import SwiftUI
@testable import HuShell

private final class FileBrowserTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

final class RemoteFileTests: XCTestCase {
    func testAbsolutePathNavigationAndBreadcrumbs() {
        XCTAssertEqual(RemotePath.resolved("../logs/./today", relativeTo: "/srv/app/data", home: "/home/alice"),
                       "/srv/app/logs/today")
        XCTAssertEqual(RemotePath.resolved("~/documents", relativeTo: "/srv/app", home: "/home/alice"),
                       "/home/alice/documents")
        XCTAssertEqual(RemotePath.resolved("../../..", relativeTo: "/srv", home: "/home/alice"), "/")
        XCTAssertEqual(RemotePath.breadcrumbs("/srv/app/logs").map(\.path),
                       ["/", "/srv", "/srv/app", "/srv/app/logs"])
    }

    func testEditorOnlyAcceptsSmallTextDocuments() {
        let text = RemoteFile(name: "notes.md", isDirectory: false, size: "50000000", modified: "", permissions: "")
        let oversized = RemoteFile(name: "notes.md", isDirectory: false, size: "50000001", modified: "", permissions: "")
        let image = RemoteFile(name: "photo.png", isDirectory: false, size: "100", modified: "", permissions: "")
        XCTAssertTrue(RemoteDocumentPolicy.canEdit(text))
        XCTAssertFalse(RemoteDocumentPolicy.canEdit(oversized))
        XCTAssertFalse(RemoteDocumentPolicy.canEdit(image))
        XCTAssertNil(RemoteDocumentPolicy.decode(Data([0, 1, 2])))
    }

    func testListingsUseFullTimestampAndSortNumerically() throws {
        let listing = """
        total 12
        drwxr-xr-x 2 user group 4096 2026-09-30 08:09:10 backup
        -rw-r--r-- 1 user group 120 2026-09-29 23:59:58 medium file.txt
        -rw-r--r-- 1 user group 9 2026-09-30 08:09:11 small.txt
        -rw-r--r-- 1 user group 1000 2026-09-28 08:09:10 large.txt
        """
        let files = try SSHService.parseListing(listing)
        XCTAssertEqual(files.first(where: { $0.name == "medium file.txt" })?.modified, "2026-09-29 23:59:58")
        XCTAssertEqual(files.first(where: { $0.name == "medium file.txt" })?.owner, "user")
        XCTAssertEqual(files.first(where: { $0.name == "medium file.txt" })?.group, "group")
        var sort = RemoteFileSort()
        sort.select(.size)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "small.txt", "medium file.txt", "large.txt"])
        sort.select(.size)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "large.txt", "medium file.txt", "small.txt"])
        sort.select(.modified)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "small.txt", "medium file.txt", "large.txt"])
    }

    func testShiftSelectionUsesVisibleSortOrderAndKeepsOriginalAnchor() {
        let files = [
            RemoteFile(name: "charlie.txt", isDirectory: false, size: "", modified: "", permissions: ""),
            RemoteFile(name: "alpha", isDirectory: true, size: "", modified: "", permissions: ""),
            RemoteFile(name: "bravo.txt", isDirectory: false, size: "", modified: "", permissions: "")
        ]
        let sorted = RemoteFileSort().files(files)
        XCTAssertEqual(RemoteFileSelection.names(in: sorted, anchor: "alpha", through: "charlie.txt"),
                       ["alpha", "bravo.txt", "charlie.txt"])
        XCTAssertEqual(RemoteFileSelection.names(in: sorted, anchor: "charlie.txt", through: "alpha"),
                       ["alpha", "bravo.txt", "charlie.txt"])
    }

    @MainActor func testFileBrowserMouseEventsInListAndColumnViews() async throws {
        _ = NSApplication.shared
        let folder = RemoteFile(name: "folder", isDirectory: true, size: "", modified: "", permissions: "")
        let file = RemoteFile(name: "notes.txt", isDirectory: false, size: "0", modified: "", permissions: "")
        let tab = ConnectionTab(profile: ConnectionProfile(name: "test", host: "localhost", username: "test"),
                                transferCenter: TransferCenter(),
                                directoryLoader: { _, path in path == "/" ? [folder, file] : [] })
        tab.connected = true
        tab.files = [folder, file]
        let pane = ConnectionPane(tab: tab, showsFiles: true, filePanelPosition: .bottom,
                                  onOpenTransferRemote: { _, _ in })
        let window = FileBrowserTestWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                                            styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: pane)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(120))

        func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
        func click(at point: NSPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                                             windowNumber: window.windowNumber, context: nil,
                                                             eventNumber: 0, clickCount: count, pressure: 0))
                window.sendEvent(event)
            }
        }
        func click(_ name: String, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
            host.layoutSubtreeIfNeeded()
            let row = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileRowClickObserver.ClickView }
                .first { $0.dragItem?.path == "/\(name)" })
            try click(at: row.convert(NSPoint(x: row.bounds.width / 3, y: row.bounds.midY), to: nil),
                      count: count, modifiers: modifiers)
        }

        let terminal = try XCTUnwrap(descendants(of: host).first { $0 is SearchableTerminalWebView })
        XCTAssertTrue(window.makeFirstResponder(terminal))
        try click(file.name)
        XCTAssertEqual(tab.selectedFiles, [file.name], "A first click must select the row immediately")
        try click(folder.name, modifiers: .shift)
        XCTAssertEqual(tab.selectedFiles, [file.name, folder.name])
        try click(file.name)
        XCTAssertEqual(tab.selectedFiles, [file.name])
        try click(file.name)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        let field = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileRenameTextField.EditableTextField }.first)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: file.name.utf16.count))

        try click(folder.name)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(descendants(of: host).contains { $0 is FileRenameTextField.EditableTextField })
        try click(folder.name)
        try click(folder.name, count: 2)
        XCTAssertEqual(tab.directory, "/folder")

        tab.goToDirectory("/")
        try await Task.sleep(for: .milliseconds(120))
        let breadcrumb = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileRowClickObserver.ClickView }
            .first { $0.dragItem == nil })
        let toolbarY = breadcrumb.convert(NSPoint(x: 0, y: breadcrumb.bounds.midY), to: nil).y
        try click(at: NSPoint(x: 723, y: toolbarY))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(tab.columns.map(\.path), ["/"])
        try click(folder.name)
        XCTAssertEqual(tab.columns.map(\.path), ["/", "/folder"])
        XCTAssertEqual(tab.columns.first?.selectedName, folder.name)
        try click(folder.name)
        XCTAssertEqual(tab.columns.map(\.path), ["/", "/folder"], "A repeat press should keep the child column until editing starts")
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.15))
        let columnField = try XCTUnwrap(descendants(of: host).compactMap { $0 as? FileRenameTextField.EditableTextField }.first)
        let columnEditor = try XCTUnwrap(columnField.currentEditor() as? NSTextView)
        XCTAssertEqual(columnEditor.selectedRange(), NSRange(location: 0, length: folder.name.utf16.count))
        columnEditor.insertText("renamed", replacementRange: columnEditor.selectedRange())
        XCTAssertEqual(columnEditor.string, "renamed")
        columnEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(descendants(of: host).contains { $0 is FileRenameTextField.EditableTextField })
    }

    func testLegacySFTPListingUsesFourDigitYearAndSeconds() throws {
        let older = try SSHService.parseListing("-rw-r--r-- 1 user group 7 Sep 12 2024 old.txt")
        XCTAssertEqual(older.first?.modified, "2024-09-12 00:00:00")
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        XCTAssertEqual(RemoteFileDate.normalized("Sep 29 13:04", now: now), "2026-09-29 13:04:00")
        XCTAssertEqual(RemoteFileDate.normalized("Dec 30 13:04", now: now), "2025-12-30 13:04:00")
    }

    func testMovingRemoteItemsRejectsSelfAndExistingDestinations() throws {
        XCTAssertThrowsError(try SSHService.moveDestination(from: "/srv/folder", toDirectory: "/srv/folder/child"))
        XCTAssertThrowsError(try SSHService.moveDestination(from: "/srv/file", toDirectory: "/srv"))
        XCTAssertEqual(try SSHService.moveDestination(from: "/srv/file", toDirectory: "/"), "/file")
        XCTAssertEqual(RemotePath.relocatedDirectory("/srv/folder/child", moving: "/srv/folder",
                                                     to: "/data/folder"), "/data/folder/child")
        XCTAssertNil(RemotePath.relocatedDirectory("/srv/folder2", moving: "/srv/folder",
                                                  to: "/data/folder"))
        let item = RemoteFileDragItem(profileID: UUID(), path: "/srv/file", isDirectory: false)
        XCTAssertTrue(item.canMove(to: "/tmp", profileID: item.profileID))
        XCTAssertFalse(item.canMove(to: "/tmp", profileID: UUID()))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("other/source.txt")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("source".utf8).write(to: source)
        try Data("existing".utf8).write(to: destination)
        let script = SSHService.moveCommand(from: source.path, to: destination.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let output = Pipe()
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: source), "source")
        XCTAssertEqual(try String(contentsOf: destination), "existing")
        try FileManager.default.removeItem(at: destination)
        let successful = Process()
        successful.executableURL = URL(fileURLWithPath: "/bin/sh")
        successful.arguments = ["-c", script]
        try successful.run()
        successful.waitUntilExit()
        XCTAssertEqual(successful.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination), "source")
    }

    func testSSHDirectoryRequestsCanReuseTheTerminalConnection() {
        let profile = ConnectionProfile(name: "test", host: "example.com", username: "user")
        let options = SSHService.options(for: profile)
        XCTAssertTrue(options.contains("ControlMaster=auto"))
        XCTAssertTrue(options.contains("ControlPersist=no"))
        XCTAssertTrue(options.contains(where: { $0.hasPrefix("ControlPath=/tmp/hushell-") && $0.hasSuffix("-%C") }))
    }
}
