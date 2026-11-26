import XCTest
import AppKit
@testable import HuShell

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

    func testSelectedRowClickRenameWaitsForSingleClick() {
        typealias ClickView = FileRowClickObserver.ClickView
        XCTAssertTrue(ClickView.shouldScheduleRename(isSelected: true, clickCount: 1, modifiers: []))
        XCTAssertTrue(ClickView.shouldScheduleRename(isSelected: true, clickCount: 0, modifiers: []))
        XCTAssertFalse(ClickView.shouldScheduleRename(isSelected: false, clickCount: 1, modifiers: []))
        XCTAssertFalse(ClickView.shouldScheduleRename(isSelected: true, clickCount: 2, modifiers: []))
        XCTAssertFalse(ClickView.shouldScheduleRename(isSelected: true, clickCount: 1, modifiers: [.shift]))
        XCTAssertFalse(ClickView.shouldScheduleRename(isSelected: true, clickCount: 1, modifiers: [.command]))
    }

    func testRenameSelectionUsesDeepBlueBackgroundAndWhiteText() {
        let background = DeepSelectionTextField.selectionBackground.usingColorSpace(.sRGB)
        let foreground = DeepSelectionTextField.selectionForeground.usingColorSpace(.sRGB)
        XCTAssertLessThan(try XCTUnwrap(background?.redComponent), 0.10)
        XCTAssertGreaterThan(try XCTUnwrap(background?.blueComponent), 0.60)
        XCTAssertEqual(try XCTUnwrap(foreground?.redComponent), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(foreground?.greenComponent), 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(foreground?.blueComponent), 1, accuracy: 0.001)
    }

    @MainActor func testSelectedRowStartsRenameAfterSingleClickDelay() async throws {
        let view = FileRowClickObserver.ClickView(frame: .zero)
        var renamed = false
        view.isSelected = true
        view.onSelect = { _ in true }
        view.onRename = { renamed = true }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 0))

        view.mouseDown(with: event)
        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.15) * 1_000_000_000))
        XCTAssertTrue(renamed)
    }

    @MainActor func testSelectedRowDoubleClickCancelsRename() async throws {
        let view = FileRowClickObserver.ClickView(frame: .zero)
        var renamed = false
        var opened = false
        view.isSelected = true
        view.onSelect = { _ in true }
        view.onRename = { renamed = true }
        view.onDoubleClick = { opened = true }
        let first = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                     modifierFlags: [], timestamp: 0,
                                                     windowNumber: 0, context: nil,
                                                     eventNumber: 1, clickCount: 1, pressure: 0))
        let second = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                                                      modifierFlags: [], timestamp: 0.1,
                                                      windowNumber: 0, context: nil,
                                                      eventNumber: 2, clickCount: 2, pressure: 0))

        view.mouseDown(with: first)
        view.mouseDown(with: second)
        try await Task.sleep(nanoseconds: UInt64((NSEvent.doubleClickInterval + 0.15) * 1_000_000_000))
        XCTAssertTrue(opened)
        XCTAssertFalse(renamed)
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
