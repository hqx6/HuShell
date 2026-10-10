import XCTest
@testable import HuShell

final class TransferCenterTests: XCTestCase {
    @MainActor func testSingleAndBulkCancellationOnlyStopActiveItems() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0, count: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let center = TransferCenter()
        let profile = ConnectionProfile(name: "test", host: "127.0.0.1", port: 1, username: "test")
        center.upload(profile: profile, local: file, remote: "/first") { _ in }
        center.upload(profile: profile, local: file, remote: "/second") { _ in }
        XCTAssertEqual(center.activeCount, 2)
        center.cancel(center.items[0].id)
        XCTAssertEqual(center.activeCount, 1)
        XCTAssertEqual(center.items[0].phase, .cancelled)
        center.cancelAll()
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertTrue(center.items.allSatisfy { $0.phase == .cancelled })
    }

    func testEstimatedCompletionRequiresKnownSizeAndSpeed() {
        let now = Date(timeIntervalSince1970: 1_000)
        var item = TransferRecord(id: UUID(), direction: .upload, profileName: "test",
                                  fileName: "file.txt", totalBytes: 1_000)
        item.phase = .running
        item.completedBytes = 400
        item.bytesPerSecond = 100
        XCTAssertEqual(item.estimatedCompletion(at: now), now.addingTimeInterval(6))
        item.bytesPerSecond = 0
        XCTAssertNil(item.estimatedCompletion(at: now))
        item.bytesPerSecond = 100
        item.phase = .cancelled
        XCTAssertNil(item.estimatedCompletion(at: now))
    }

    func testCancellationStopsRunningProcess() async throws {
        let cancellation = TransferCancellation()
        let profile = ConnectionProfile(name: "test", host: "localhost", username: "test")
        let started = Date()
        let operation = Task.detached {
            try SSHService.run("/bin/sleep", args: ["10"], profile: profile,
                               timeout: nil, cancellation: cancellation)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        cancellation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled process unexpectedly succeeded")
        } catch let error as SSHError {
            guard case .cancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }
}
