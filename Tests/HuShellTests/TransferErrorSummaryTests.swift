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
}
