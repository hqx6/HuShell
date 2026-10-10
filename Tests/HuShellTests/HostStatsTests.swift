import XCTest
@testable import HuShell

final class HostStatsTests: XCTestCase {
    func testParsesMonitorSectionsAndRates() {
        let stats = HostStats(output: """
        HUSHELL|system|Linux x86_64
        HUSHELL|load|0.42 0.35 0.28
        HUSHELL|cpu|16
        HUSHELL|cpuUsage|23
        HUSHELL|memory|2048|8192
        HUSHELL|swap|128|1024
        HUSHELL|process|321|18.4|2.5G|/opt/worker/bin/python3
        HUSHELL|network|4096|2048
        HUSHELL|mount|/data|150.0|500.0
        """)

        XCTAssertEqual(stats.cpuUsage, 23)
        XCTAssertEqual(stats.memoryFraction, 0.25)
        XCTAssertEqual(stats.swapFraction, 0.125)
        XCTAssertEqual(stats.processes.first?.command, "python3")
        XCTAssertEqual(stats.processes.first?.memory, "2.5G")
        XCTAssertEqual(stats.networkReceive, "4096")
        XCTAssertEqual(stats.disks.first?.path, "/data")
        XCTAssertEqual(stats.disks.first?.fraction, 0.3)
    }

    func testParsesAndOrdersGPUsWithUnavailableMetrics() {
        let stats = HostStats(output: """
        HUSHELL|gpu|1|NVIDIA H100 80GB HBM3|22118|81559|82
        HUSHELL|gpu|0|NVIDIA A100-SXM4-80GB|40960|81920|N/A
        """)

        XCTAssertEqual(stats.gpus.map(\.index), [0, 1])
        XCTAssertEqual(stats.gpus[0].name, "NVIDIA A100-SXM4-80GB")
        XCTAssertEqual(stats.gpus[0].memoryText, "40.0 / 80.0 GiB")
        XCTAssertEqual(stats.gpus[0].memoryFraction, 0.5)
        XCTAssertEqual(stats.gpus[0].utilizationText, "—")
        XCTAssertEqual(stats.gpus[1].utilizationText, "82%")
        XCTAssertEqual(stats.gpus[1].memoryText, "21.6 / 79.6 GiB")
    }

    func testOnlyPhysicalDisksAreShown() {
        let stats = HostStats(output: """
        HUSHELL|mount|overlay|overlay|/|100.0|500.0
        HUSHELL|mount|tmpfs|tmpfs|/run|0.1|8.0
        HUSHELL|mount|/dev/loop0|squashfs|/snap/app|1.0|1.0
        HUSHELL|mount|/dev/sda1|ext4|/|120.0|480.0
        HUSHELL|mount|/dev/sda2|vfat|/boot/efi|0.2|1.0
        HUSHELL|mount|/dev/nvme0n1p1|xfs|/data|950.0|2000.0
        HUSHELL|mount|/dev/mapper/vg-home|ext4|/home|40.0|100.0
        HUSHELL|mount|server:/share|nfs|/mnt/share|300.0|1000.0
        """)
        XCTAssertEqual(stats.disks.map(\.path), ["/", "/data", "/home"])
        XCTAssertEqual(stats.disks[0].fraction, 0.25)
    }

    func testMacDataVolumeReplacesSystemVolume() {
        let stats = HostStats(output: """
        HUSHELL|mount|/dev/disk3s1s1|darwin|/|20.0|500.0
        HUSHELL|mount|/dev/disk3s5|darwin|/System/Volumes/Data|180.0|500.0
        HUSHELL|mount|/dev/disk3s2|darwin|/System/Volumes/Preboot|2.0|500.0
        HUSHELL|mount|/dev/disk5s1|darwin|/Library/Developer/CoreSimulator/Volumes/iOS|6.0|7.0
        HUSHELL|mount|/dev/disk4s1|darwin|/Volumes/External|100.0|1000.0
        """)
        XCTAssertEqual(stats.disks.map(\.path), ["/", "/Volumes/External"])
        XCTAssertEqual(stats.disks[0].used, "180.0")
    }

    func testCollapsedSectionsDoNotRunRemoteQueries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("queried")
        let command = directory.appendingPathComponent("nvidia-smi")
        try "#!/bin/sh\ntouch \"$GPU_MARKER\"\nprintf '0, NVIDIA A100, 1024, 8192, 50\\n'\n"
            .write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)

        func execute(_ sections: Set<HostMonitorSection>) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", SSHService.statsScript(sections: sections)]
            process.environment = ["PATH": directory.path + ":/usr/bin:/bin", "GPU_MARKER": marker.path]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            return text
        }

        XCTAssertEqual(try execute([]), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try execute([.gpu]).trimmingCharacters(in: .whitespacesAndNewlines),
                       "HUSHELL|gpu|0|NVIDIA A100|1024|8192|50")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let allOutput = try execute(Set(HostMonitorSection.allCases))
        XCTAssertTrue(allOutput.contains("HUSHELL|system|"))
        XCTAssertTrue(allOutput.contains("HUSHELL|mount|"))
    }
}
