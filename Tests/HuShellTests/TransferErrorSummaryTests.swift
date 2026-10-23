import XCTest
@testable import HuShell

final class TransferErrorSummaryTests: XCTestCase {
    func testUploadPermissionErrorOmitsSFTPTranscript() {
        let transcript = """
        Connected to example.com.
        sftp> put /tmp/example.txt /protected/example.txt
        Uploading /tmp/example.txt to /protected/example.txt
        dest open(\"/protected/example.txt\"): Permission denied
        """
        XCTAssertEqual(TransferErrorSummary.upload(SSHError.command(transcript)), "权限不足，无法上传")
    }

    func testUploadOtherErrorsStayBrief() {
        XCTAssertEqual(TransferErrorSummary.upload(SSHError.command("No space left on device")),
                       "目标磁盘空间不足，无法上传")
        let transcript = "sftp> put local remote\nUploading local to remote\nremote reported an unexpected error"
        XCTAssertEqual(TransferErrorSummary.upload(SSHError.command(transcript)),
                       "上传失败：remote reported an unexpected error")
    }

    func testRecursiveDeleteShowsOneReasonInsteadOfEveryFileError() {
        let transcript = """
        rm: cannot remove '/srv/project/a': Permission denied
        rm: cannot remove '/srv/project/b': Permission denied
        rm: cannot remove '/srv/project/c': Permission denied
        """
        XCTAssertEqual(TransferErrorSummary.delete(SSHError.command(transcript)), "权限不足，无法删除")
        XCTAssertEqual(TransferErrorSummary.delete(SSHError.command("rmdir /srv/project: Directory not empty")),
                       "文件夹非空，无法删除；可使用快速删除")
    }

    func testSudoPromptOnlyFollowsFilePermissionFailures() {
        XCTAssertTrue(RemotePermission.isDenied(SSHError.command("dest open: Permission denied")))
        XCTAssertTrue(RemotePermission.isDenied(SSHError.command("rm: Operation not permitted")))
        XCTAssertFalse(RemotePermission.isDenied(SSHError.command("Permission denied (publickey).")))
        XCTAssertFalse(RemotePermission.isDenied(SSHError.command("No space left on device")))
    }

    @MainActor func testOneSudoPromptCanRetrySeveralFailedUploads() {
        let tab = ConnectionTab(profile: ConnectionProfile(name: "server", host: "localhost", username: "test"),
                                transferCenter: TransferCenter())
        var received: [String] = []
        tab.requestSudo(action: "上传", target: "first.txt") { received.append("first:\($0)") }
        tab.requestSudo(action: "上传", target: "second.txt") { received.append("second:\($0)") }
        XCTAssertEqual(tab.sudoChallenge?.target, "first.txt")
        tab.retryWithSudo(password: "one-use-password")
        XCTAssertEqual(received, ["first:one-use-password", "second:one-use-password"])
        XCTAssertNil(tab.sudoChallenge)
        tab.requestSudo(action: "删除", target: "third.txt") { received.append($0) }
        tab.cancelSudoRetry()
        XCTAssertNil(tab.sudoChallenge)
        XCTAssertEqual(received.count, 2)
    }
}
