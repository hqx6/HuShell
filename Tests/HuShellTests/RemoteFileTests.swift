import XCTest
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
        var sort = RemoteFileSort()
        sort.select(.size)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "small.txt", "medium file.txt", "large.txt"])
        sort.select(.size)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "large.txt", "medium file.txt", "small.txt"])
        sort.select(.modified)
        XCTAssertEqual(sort.files(files).map(\.name), ["backup", "small.txt", "medium file.txt", "large.txt"])
    }

    func testLegacySFTPListingUsesFourDigitYearAndSeconds() throws {
        let older = try SSHService.parseListing("-rw-r--r-- 1 user group 7 Sep 12 2024 old.txt")
        XCTAssertEqual(older.first?.modified, "2024-09-12 00:00:00")
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30))!
        XCTAssertEqual(RemoteFileDate.normalized("Sep 29 13:04", now: now), "2026-09-29 13:04:00")
        XCTAssertEqual(RemoteFileDate.normalized("Dec 30 13:04", now: now), "2025-12-30 13:04:00")
    }
}
