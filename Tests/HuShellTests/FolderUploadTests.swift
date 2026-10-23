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
}
