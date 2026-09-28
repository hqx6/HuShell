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
}
