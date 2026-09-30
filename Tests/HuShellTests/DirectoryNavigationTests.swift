import XCTest
@testable import HuShell

private actor DirectoryResponses {
    private var pending: [String: [CheckedContinuation<[RemoteFile], Error>]] = [:]
    private(set) var counts: [String: Int] = [:]

    func load(_ path: String) async throws -> [RemoteFile] {
        counts[path, default: 0] += 1
        return try await withCheckedThrowingContinuation { pending[path, default: []].append($0) }
    }

    func finish(_ path: String, name: String) {
        guard var requests = pending[path], !requests.isEmpty else { return }
        let response = requests.removeFirst()
        pending[path] = requests
        response.resume(returning: [RemoteFile(name: name, isDirectory: true, size: "", modified: "", permissions: "")])
    }
}

final class DirectoryNavigationTests: XCTestCase {
    @MainActor private func tab(_ responses: DirectoryResponses) -> ConnectionTab {
        let tab = ConnectionTab(profile: ConnectionProfile(name: "test", host: "localhost", username: "test"),
                                transferCenter: TransferCenter(),
                                directoryLoader: { _, path in try await responses.load(path) })
        tab.connected = true
        return tab
    }

    @MainActor private func waitUntil(_ predicate: () async -> Bool) async {
        for _ in 0..<1000 {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Directory response did not arrive")
    }

    @MainActor func testColumnModeRestoresAncestorsAndCachedBreadcrumbsImmediately() async {
        let responses = DirectoryResponses()
        let tab = tab(responses)
        tab.directory = "/data/app"
        tab.files = [RemoteFile(name: "config.txt", isDirectory: false, size: "10", modified: "", permissions: "")]
        tab.showColumns()
        XCTAssertEqual(tab.columns.map(\.path), ["/", "/data", "/data/app"])
        XCTAssertEqual(tab.columns.map(\.selectedName), ["data", "app", nil])
        XCTAssertEqual(tab.columns.last?.files.first?.name, "config.txt")
        await waitUntil { await responses.counts["/data"] == 1 }
        await responses.finish("/", name: "data")
        await responses.finish("/data", name: "app")
        await waitUntil { tab.loadingDirectories.isEmpty }
        tab.goToDirectory("/data")
        XCTAssertEqual(tab.directory, "/data")
        XCTAssertEqual(tab.files.first?.name, "app")
        XCTAssertEqual(tab.columns.map(\.path), ["/", "/data"])
        XCTAssertFalse(tab.busy)
        tab.setColumnMode(false)
        tab.setColumnMode(true)
        XCTAssertEqual(tab.columns.map(\.path), ["/", "/data"])
        let counts = await responses.counts
        XCTAssertEqual(counts["/data"], 1)
    }

    @MainActor func testLateReplyDoesNotOverwriteNewNavigationAndIsReusable() async {
        let responses = DirectoryResponses()
        let tab = tab(responses)
        tab.goToDirectory("/old")
        tab.goToDirectory("/new")
        XCTAssertEqual(tab.directory, "/new")
        await waitUntil { await responses.counts["/new"] == 1 }
        await responses.finish("/new", name: "new-file")
        await waitUntil { !tab.busy }
        await responses.finish("/old", name: "old-file")
        await waitUntil { tab.loadingDirectories.isEmpty }
        XCTAssertEqual(tab.files.first?.name, "new-file")
        tab.goToDirectory("/old")
        XCTAssertEqual(tab.files.first?.name, "old-file")
        XCTAssertFalse(tab.busy)
    }

    @MainActor func testRefreshIgnoresSupersededResponseAndDisconnectClearsCache() async {
        let responses = DirectoryResponses()
        let tab = tab(responses)
        tab.goToDirectory("/data")
        await waitUntil { await responses.counts["/data"] == 1 }
        tab.loadFiles()
        await waitUntil { await responses.counts["/data"] == 2 }
        await responses.finish("/data", name: "stale")
        await Task.yield()
        XCTAssertTrue(tab.busy)
        await responses.finish("/data", name: "fresh")
        await waitUntil { !tab.busy }
        XCTAssertEqual(tab.files.first?.name, "fresh")
        tab.disconnect()
        tab.connected = true
        tab.goToDirectory("/data")
        XCTAssertTrue(tab.files.isEmpty)
        await waitUntil { await responses.counts["/data"] == 3 }
        await responses.finish("/data", name: "reconnected")
        await waitUntil { !tab.busy }
        XCTAssertEqual(tab.files.first?.name, "reconnected")
    }
}
