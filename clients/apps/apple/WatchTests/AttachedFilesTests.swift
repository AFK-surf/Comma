import XCTest
@testable import CommaWatch

final class AttachedFilesTests: XCTestCase {
    /// The files listed under a sent message read as chips: workspace files, files named by their path on the sender's
    /// computer, or both, the local ones first; a list with a line that names no file leaves the text whole.
    func testSplitReadsLocalAndWorkspaceLists() {
        let local = "Attached local files on the sender's computer:\n"
            + "- 项目 资料 (1).zip (local path: /Users/me/下载/项目 资料 (1).zip)\n"
            + "- podcast.mp3 (local path: C:\\Users\\me\\podcast.mp3)"
        let workspace = "Attached files in your workspace:\n- notes.pdf (workspace file: /uploads/abcdefghijklmnopqrstuv-notes.pdf)"

        let alone = AttachedFiles.split("Unpack it\n\n" + local)
        XCTAssertEqual(alone.body, "Unpack it")
        XCTAssertEqual(alone.names, ["项目 资料 (1).zip", "podcast.mp3"])

        let uploaded = AttachedFiles.split("Read it\n\n" + workspace)
        XCTAssertEqual(uploaded.body, "Read it")
        XCTAssertEqual(uploaded.names, ["notes.pdf"])

        let both = AttachedFiles.split("I've attached some files:\n\n" + local + "\n\n" + workspace)
        XCTAssertEqual(both.body, "")
        XCTAssertEqual(both.names, ["项目 资料 (1).zip", "podcast.mp3", "notes.pdf"])

        let prose = "See\n\nAttached local files on the sender's computer:\nnot a file line"
        XCTAssertEqual(AttachedFiles.split(prose).body, prose)
        XCTAssertEqual(AttachedFiles.split(prose).names, [])
    }
}
