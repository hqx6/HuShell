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
}
