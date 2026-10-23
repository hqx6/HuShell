import XCTest
@testable import HuShell

final class UTF8StreamDecoderTests: XCTestCase {
    func testChineseAndEmojiSurviveEveryReadBoundary() {
        let original = "连接成功：中文路径 /数据/文件.txt 🚀\r\n"
        let bytes = Array(original.utf8)
        for split in 0...bytes.count {
            var decoder = UTF8StreamDecoder()
            let decoded = decoder.append(bytes[..<split])
                + decoder.append(bytes[split...]) + decoder.finish()
            XCTAssertEqual(decoded, original, "Split at byte \(split)")
        }

        var decoder = UTF8StreamDecoder()
        let oneByteAtATime = bytes.map { decoder.append([$0][...]) }.joined() + decoder.finish()
        XCTAssertEqual(oneByteAtATime, original)
    }

    func testIncompleteFinalSequenceIsReplacedOnlyAtEnd() {
        var decoder = UTF8StreamDecoder()
        XCTAssertEqual(decoder.append([0xE4, 0xB8][...]), "")
        XCTAssertEqual(decoder.finish(), "�")
    }

    func testInteractiveTerminalDoesNotForceCLocale() {
        let profile = ConnectionProfile(name: "test", host: "localhost", username: "test")
        XCTAssertEqual(SSHService.environment(for: profile)["LC_ALL"], "C")
        let environment = SSHService.terminalEnvironment(for: profile)
        XCTAssertNil(environment["LC_ALL"])
        XCTAssertTrue(environment["LANG"]?.uppercased().contains("UTF-8") == true)
    }
}
