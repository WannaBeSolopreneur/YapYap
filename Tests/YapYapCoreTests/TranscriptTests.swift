import XCTest
@testable import YapYapCore

final class TranscriptTests: XCTestCase {
    func testDraftIsReplacedAndFinalPiecesAreJoined() {
        var t = Transcript()
        t.receive("Hello", isFinal: false)
        t.receive("Hello there", isFinal: false)
        XCTAssertEqual(t.text, "Hello there")
        t.receive("Hello there.", isFinal: true)
        t.receive("How are", isFinal: false)
        XCTAssertEqual(t.text, "Hello there. How are")
        t.receive(" How are you?", isFinal: true)
        XCTAssertEqual(t.text, "Hello there. How are you?")
        XCTAssertEqual(t.draft, "")
    }

    func testEmptyAndWhitespace() {
        var t = Transcript()
        XCTAssertEqual(t.text, "")
        t.receive("  ", isFinal: false)
        XCTAssertEqual(t.text, "")
    }
}
