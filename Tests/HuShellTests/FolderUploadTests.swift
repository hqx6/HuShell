import Foundation
import XCTest
@testable import HuShell

final class FolderUploadTests: XCTestCase {
    func testRecursiveSFTPUploadPreservesFoldersAndMergesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local/项目 [2026] 文件夹")
        let remoteParent = root.appendingPathComponent("远端 目录")
        try FileManager.default.createDirectory(at: local.appendingPathComponent("nested/empty"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteParent, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: local.appendingPathComponent("nested/file.txt"))
        try Data("hidden".utf8).write(to: local.appendingPathComponent(".hidden"))
        try FileManager.default.createSymbolicLink(at: local.appendingPathComponent("outside-link"),
                                                   withDestinationURL: root)
        XCTAssertEqual(LocalTransferSize.directory(local), 11)

        let command = try SSHService.directoryUploadCommand(local: local, remoteParent: remoteParent.path)
        func transfer() throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            process.arguments = ["-D", "/usr/libexec/sftp-server", "-b", "-", "localhost"]
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            try process.run()
            input.fileHandleForWriting.write(Data((command + "\n").utf8))
            try input.fileHandleForWriting.close()
            let response = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: response, as: UTF8.self))
        }

        try transfer()
        let uploaded = remoteParent.appendingPathComponent(local.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: uploaded.appendingPathComponent("nested/file.txt")), "hello")
        XCTAssertEqual(try String(contentsOf: uploaded.appendingPathComponent(".hidden")), "hidden")
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploaded.appendingPathComponent("nested/empty").path))

        try Data("keep".utf8).write(to: uploaded.appendingPathComponent("keep.txt"))
        try transfer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: uploaded.appendingPathComponent("keep.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: uploaded.appendingPathComponent(local.lastPathComponent).path))
    }

    @MainActor func testFolderIsOneCancelableTransferRecord() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let center = TransferCenter()
        let profile = ConnectionProfile(name: "test", host: "127.0.0.1", port: 1, username: "test")
        center.upload(profile: profile, local: root, remote: "/srv/" + root.lastPathComponent) { _ in }
        XCTAssertEqual(center.activeCount, 1)
        guard case .remoteDirectory(let savedProfile, let path) = center.items[0].destination else {
            return XCTFail("Folder destination was not saved")
        }
        XCTAssertEqual(savedProfile, profile)
        XCTAssertEqual(path, "/srv/" + root.lastPathComponent)
        center.cancelAll()
        XCTAssertEqual(center.items[0].phase, .cancelled)
    }

    @MainActor func testBatchOfNestedFoldersQueuesExcessTransfersAndCanCancelThem() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = TransferCenter()
        let profile = ConnectionProfile(name: "test", host: "127.0.0.1", port: 1, username: "test")
        for number in 0..<6 {
            let folder = root.appendingPathComponent("folder-\(number)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("child/grandchild"),
                                                    withIntermediateDirectories: true)
            try Data("content".utf8).write(to: folder.appendingPathComponent("child/grandchild/file.txt"))
            center.upload(profile: profile, local: folder, remote: "/srv/" + folder.lastPathComponent) { _ in }
        }
        XCTAssertEqual(center.items.filter { $0.phase == .running }.count, 2)
        XCTAssertEqual(center.items.filter { $0.phase == .waiting }.count, 4)
        center.cancelAll()
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertTrue(center.items.allSatisfy { $0.phase == .cancelled })
    }

    func testTransferOutputKeepsOnlyTailOfLargeProcessOutput() throws {
        let profile = ConnectionProfile(name: "test", host: "127.0.0.1", port: 1, username: "test")
        let script = "awk 'BEGIN { for (i=0; i<20000; i++) print \"file-output-line\" }'; printf 'FINAL_ERROR_MARKER' >&2; exit 7"
        XCTAssertThrowsError(try SSHService.run("/bin/sh", args: ["-c", script], profile: profile,
                                                   maxOutputBytes: 4096)) { error in
            guard case SSHError.command(let output) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(output.contains("FINAL_ERROR_MARKER"))
            XCTAssertLessThanOrEqual(output.utf8.count, 4096)
        }
    }

    func testMultipleNestedFoldersUploadToOneDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("remote")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let profile = ConnectionProfile(name: "test", host: "localhost", username: "test")
        for number in 0..<5 {
            let source = root.appendingPathComponent("folder-\(number)")
            try FileManager.default.createDirectory(at: source.appendingPathComponent("a/b/c"),
                                                    withIntermediateDirectories: true)
            try Data("file-\(number)".utf8).write(to: source.appendingPathComponent("a/b/c/item.txt"))
            let command = try SSHService.directoryUploadCommand(local: source, remoteParent: destination.path)
            _ = try SSHService.run("/usr/bin/sftp",
                                   args: ["-D", "/usr/libexec/sftp-server", "-b", "-", "localhost"],
                                   profile: profile, input: Data((command + "\n").utf8),
                                   maxOutputBytes: 64 * 1024)
        }
        for number in 0..<5 {
            let file = destination.appendingPathComponent("folder-\(number)/a/b/c/item.txt")
            XCTAssertEqual(try String(contentsOf: file), "file-\(number)")
        }
    }

    func testSudoUploadCopyMergesIntoExistingFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = root.appendingPathComponent("staged/项目 文件夹")
        let targetParent = root.appendingPathComponent("target")
        let target = targetParent.appendingPathComponent(staged.lastPathComponent)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: staged.appendingPathComponent("new.txt"))
        try Data("old".utf8).write(to: target.appendingPathComponent("old.txt"))

        let command = SSHService.sudoUploadCopyCommand(stagedPath: staged.path,
                                                       remote: target.path, isDirectory: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("new.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("old.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(staged.lastPathComponent).path))
    }
}
