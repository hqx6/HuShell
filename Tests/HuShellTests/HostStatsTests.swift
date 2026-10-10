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

    func testNPUFallbackParsesDeviceRowsButNotProcessRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let nvidia = directory.appendingPathComponent("nvidia-smi")
        try "#!/bin/sh\nexit 1\n".write(to: nvidia, atomically: true, encoding: .utf8)
        let npu = directory.appendingPathComponent("npu-smi")
        try """
        #!/bin/sh
        [ "$1" = info ] || exit 1
        cat <<'NPU_OUTPUT'
        | NPU   Name                | Health        | Power(W)             Temp(C)                 Hugepages-Usage(page)   |
        | Chip                      | Bus-Id        | AICore(%)            Memory-Usage(MB)        HBM-Usage(MB)           |
        | 0     910B3               | OK            | 90.7                 37                      0    / 0                |
        | 0                         | 0000:C1:00.0  | 7                    0    / 0                53984/ 65536            |
        | 1     910B3               | OK            | 96.9                 36                      0    / 0                |
        | 0                         | 0000:C2:00.0  | 42                   0    / 0                52314/ 65536            |
        | NPU     Chip              | Process id    | Process name       | Process memory(MB)    | Process id in container |
        | 0       0                 | 1712733       | sglangschedul      | 48954                 | NA                      |
        NPU_OUTPUT
        """.write(to: npu, atomically: true, encoding: .utf8)
        for command in [nvidia, npu] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SSHService.statsScript(sections: [.gpu])]
        process.environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let stats = HostStats(output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(stats.gpus.count, 2)
        XCTAssertEqual(stats.gpus.map(\.kind), [.npu, .npu])
        XCTAssertEqual(stats.gpus.map(\.index), [0, 1])
        XCTAssertEqual(stats.gpus.map(\.name), ["910B3", "910B3"])
        XCTAssertEqual(stats.gpus[0].memoryUsedMiB, 53984)
        XCTAssertEqual(stats.gpus[0].memoryTotalMiB, 65536)
        XCTAssertEqual(stats.gpus[0].utilizationText, "7%")
        XCTAssertEqual(stats.gpus[1].utilizationText, "42%")
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
        let npuMarker = directory.appendingPathComponent("npu-queried")
        let npuCommand = directory.appendingPathComponent("npu-smi")
        try "#!/bin/sh\ntouch \"$GPU_MARKER\"\nprintf '0, NVIDIA A100, 1024, 8192, 50\\n'\n"
            .write(to: command, atomically: true, encoding: .utf8)
        try "#!/bin/sh\ntouch \"$NPU_MARKER\"\n".write(to: npuCommand, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: command.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: npuCommand.path)

        func execute(_ sections: Set<HostMonitorSection>) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", SSHService.statsScript(sections: sections)]
            process.environment = ["PATH": directory.path + ":/usr/bin:/bin", "GPU_MARKER": marker.path,
                                   "NPU_MARKER": npuMarker.path]
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: npuMarker.path))
        let allOutput = try execute(Set(HostMonitorSection.allCases))
        XCTAssertTrue(allOutput.contains("HUSHELL|system|"))
        XCTAssertTrue(allOutput.contains("HUSHELL|mount|"))
    }
}
