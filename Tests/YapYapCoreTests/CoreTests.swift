import CoreGraphics
import XCTest
@testable import YapYapCore

/// Builds a line from top-left pixel coords on a 1000×1000 image.
private func line(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat = 300, h: CGFloat = 20) -> OCRLine {
    let rect = CGRect(x: x / 1000, y: 1 - (y + h) / 1000, width: w / 1000, height: h / 1000)
    let parts = text.split(separator: " ").map(String.init)
    let ww = rect.width / CGFloat(parts.count)
    let words = parts.enumerated().map { i, p in
        OCRWord(text: p, rect: CGRect(x: rect.minX + CGFloat(i) * ww, y: rect.minY, width: ww, height: rect.height))
    }
    return OCRLine(text: text, rect: rect, words: words)
}

private let size = CGSize(width: 1000, height: 1000)

final class LayoutTests: XCTestCase {
    func testSingleColumnIsOneParagraph() {
        let lines = [line("two", x: 50, y: 124), line("one", x: 50, y: 100), line("three", x: 50, y: 148)]
        let blocks = Layout.blocks(lines, imageSize: size)
        XCTAssertEqual(blocks.map { $0.map(\.text) }, [["one", "two", "three"]])
    }

    func testParagraphGapStartsNewBlock() {
        let lines = [line("a1", x: 50, y: 100), line("a2", x: 50, y: 124), line("b1", x: 50, y: 200)]
        XCTAssertEqual(Layout.blocks(lines, imageSize: size).map { $0.map(\.text) }, [["a1", "a2"], ["b1"]])
    }

    func testTwoColumnsReadLeftThenRight() {
        let lines = [
            line("Title across both", x: 50, y: 40, w: 800),
            line("L1", x: 50, y: 100), line("R1", x: 500, y: 100),
            line("L2", x: 50, y: 124), line("R2", x: 500, y: 124),
            line("L3", x: 50, y: 200), line("R3", x: 500, y: 200),
        ]
        let order = Layout.blocks(lines, imageSize: size).flatMap { $0.map(\.text) }
        XCTAssertEqual(order, ["Title across both", "L1", "L2", "L3", "R1", "R2", "R3"])
    }

    func testSidebarReadBeforeContent() {
        let lines = [
            line("Inbox", x: 10, y: 100, w: 100), line("Sent", x: 10, y: 124, w: 100),
            line("Hello there", x: 300, y: 100, w: 600), line("General Kenobi", x: 300, y: 124, w: 600),
        ]
        let order = Layout.blocks(lines, imageSize: size).flatMap { $0.map(\.text) }
        XCTAssertEqual(order, ["Inbox", "Sent", "Hello there", "General Kenobi"])
    }
}

final class DocTests: XCTestCase {
    func testRangesPointAtWords() {
        let doc = Doc(blocks: [[line("Hello, world", x: 0, y: 0)], [line("Next para", x: 0, y: 100)]])
        XCTAssertEqual(doc.text, "Hello, world\nNext para")
        let ns = doc.text as NSString
        XCTAssertEqual(doc.words.map { ns.substring(with: $0.range) }, ["Hello,", "world", "Next", "para"])
        XCTAssertEqual(doc.wordIndex(atUTF16: 7), 1)
        XCTAssertEqual(doc.wordIndex(atUTF16: 13), 2)
        XCTAssertEqual(doc.wordIndex(atUTF16: 0), 0)
    }

    func testUTF16RangesWithEmoji() {
        let doc = Doc(blocks: [[line("hi 👋🏽 there", x: 0, y: 0)]])
        let ns = doc.text as NSString
        XCTAssertEqual(ns.substring(with: doc.words[2].range), "there")
    }

    func testWordAtPoint() {
        let doc = Doc(blocks: [[line("alpha beta", x: 0, y: 0, w: 200)]])
        let beta = doc.words[1].rect
        XCTAssertEqual(doc.wordIndex(at: CGPoint(x: beta.midX, y: beta.midY)), 1)
        // Past the end of the line still picks the nearest word on it.
        XCTAssertEqual(doc.wordIndex(at: CGPoint(x: 0.9, y: beta.midY)), 1)
        XCTAssertNil(doc.wordIndex(at: CGPoint(x: 0.5, y: 0.5)))
    }
}

final class AlignTests: XCTestCase {
    func testFindsShiftAfterScroll() {
        let old = Doc(blocks: [[line("one two three four five six seven eight", x: 0, y: 0, w: 900)]])
        let new = Doc(blocks: [[line("five six seven eight nine ten", x: 0, y: 0, w: 900)]])
        XCTAssertEqual(Align.shift(from: old, at: 4, to: new), -4)
    }

    func testToleratesOneOCRDifference() {
        let old = Doc(blocks: [[line("the quick brown fox jumps over", x: 0, y: 0, w: 900)]])
        let new = Doc(blocks: [[line("intro the quick brovvn fox jumps over", x: 0, y: 0, w: 900)]])
        XCTAssertEqual(Align.shift(from: old, at: 0, to: new), 1)
    }

    func testNilWhenTextGone() {
        let old = Doc(blocks: [[line("alpha beta gamma delta", x: 0, y: 0)]])
        let new = Doc(blocks: [[line("something else entirely here", x: 0, y: 0)]])
        XCTAssertNil(Align.shift(from: old, at: 0, to: new))
    }
}

final class ChunkTests: XCTestCase {
    private func doc(_ paragraphs: [String]) -> Doc {
        Doc(blocks: paragraphs.enumerated().map { i, p in [line(p, x: 50, y: CGFloat(100 + i * 100))] })
    }

    func testBreaksAtParagraphsAndCoversAllText() {
        let d = doc(["One two three.", "Four five"])
        let parts = d.chunks(from: 0).map { (d.text as NSString).substring(with: $0) }
        XCTAssertEqual(parts, ["One two three.", "Four five"])
    }

    func testBreaksAfterSentencesOnceLongEnough() {
        let d = doc(["Aa bb. Cc dd. Ee ff."])
        let parts = d.chunks(from: 0, first: 5, target: 10).map { (d.text as NSString).substring(with: $0) }
        XCTAssertEqual(parts, ["Aa bb.", "Cc dd. Ee ff."])
    }

    func testHardLimitAndStartWord() {
        let d = doc(["a b c d e f g h"])
        let parts = d.chunks(from: 2, limit: 5).map { (d.text as NSString).substring(with: $0) }
        XCTAssertEqual(parts, ["c d e", "f g h"])
    }
}

final class SentenceTests: XCTestCase {
    // Words: 0 One 1 two. 2 Three 3 four 4 five. | 5 Six 6 seven
    private let d = Doc(blocks: [[line("One two. Three four five.", x: 50, y: 100)], [line("Six seven", x: 50, y: 200)]])

    func testSentenceStart() {
        XCTAssertEqual(d.sentenceStart(containing: 0), 0)
        XCTAssertEqual(d.sentenceStart(containing: 1), 0)
        XCTAssertEqual(d.sentenceStart(containing: 4), 2)
        XCTAssertEqual(d.sentenceStart(containing: 6), 5, "paragraph starts a sentence")
    }

    func testNextSentence() {
        XCTAssertEqual(d.nextSentence(from: 0), 2)
        XCTAssertEqual(d.nextSentence(from: 3), 5)
        XCTAssertNil(d.nextSentence(from: 6))
    }

    func testPreviousSentenceGoesBackFurtherNearTheStart() {
        XCTAssertEqual(d.previousSentence(from: 4), 2, "mid-sentence restarts it")
        XCTAssertEqual(d.previousSentence(from: 2), 0, "at the start goes to the one before")
        XCTAssertEqual(d.previousSentence(from: 3), 0, "one word in still counts as the start")
        XCTAssertEqual(d.previousSentence(from: 0), 0)
    }
}

final class LinkSkippingTests: XCTestCase {
    private func doc(_ text: String) -> Doc {
        Doc(blocks: [[line(text, x: 50, y: 100)]])
    }

    func testBlanksLinksAndEmailsButKeepsPunctuationAndOffsets() {
        let d = doc("See https://example.com/a?b=1, www.apple.com or mail me@test.org. Thanks")
        let spoken = d.speechText(skippingLinks: true)
        XCTAssertEqual(spoken.utf16.count, d.text.utf16.count, "offsets must not move")
        XCTAssertFalse(spoken.contains("example"))
        XCTAssertFalse(spoken.contains("apple"))
        XCTAssertFalse(spoken.contains("test.org"))
        XCTAssertTrue(spoken.hasPrefix("See "))
        XCTAssertTrue(spoken.contains(","), "trailing punctuation stays so the voice still pauses")
        XCTAssertTrue(spoken.hasSuffix(". Thanks"))
    }

    func testLeavesOrdinaryTextAlone() {
        let d = doc("Version 2.5 e.g. Mr. Smith said hi.")
        XCTAssertEqual(d.speechText(skippingLinks: true), d.text)
    }

    func testCanBeTurnedOff() {
        let d = doc("Go to https://example.com now")
        XCTAssertEqual(d.speechText(skippingLinks: false), d.text)
    }
}

final class CollapseSpacesTests: XCTestCase {
    func testCollapsesRunsAndMapsBack() {
        let original = "Hi      there  you"
        let c = SpeechText.collapsingSpaces(original)
        XCTAssertEqual(c.text, "Hi there you")
        let ns = c.text as NSString
        XCTAssertEqual(c.original(ns.range(of: "there").location), (original as NSString).range(of: "there").location)
        XCTAssertEqual(c.original(ns.range(of: "you").location), (original as NSString).range(of: "you").location)
        XCTAssertEqual(c.original(0), 0)
        XCTAssertEqual(c.original(c.text.utf16.count), original.utf16.count, "the end maps to the end")
    }

    func testLeavesSingleSpacesAlone() {
        let c = SpeechText.collapsingSpaces("a b c")
        XCTAssertEqual(c.text, "a b c")
        XCTAssertEqual(c.original(4), 4)
    }
}
