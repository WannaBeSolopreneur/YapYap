import XCTest
@testable import YapYap

final class NameCandidateTests: XCTestCase {
    private let text = "Hey Tig, can you send the deck to Priya Shah and Sioban before Thursday?"

    private func candidate(_ heard: String, _ name: String, similarity: Float, passed: Bool = true, margin: Float = 5) -> NameCandidate {
        let start = text.utf8.count - text[text.range(of: heard)!.lowerBound...].utf8.count
        return NameCandidate(heard: heard, name: name, range: start..<(start + heard.utf8.count), similarity: similarity, passed: passed, margin: margin)
    }

    func testRespellsASoundAlike() {
        let chosen = NameCandidate.pick([candidate("Sioban", "Siobhan", similarity: 0.86)])
        XCTAssertEqual(NameCandidate.apply(chosen, to: text), "Hey Tig, can you send the deck to Priya Shah and Siobhan before Thursday?")
    }

    /// FluidAudio passed these on the audio alone; they overwrote the start of the sentence.
    func testLeavesWordsThatLookNothingLikeTheName() {
        XCTAssertEqual(NameCandidate.pick([candidate("Hey Tig,", "Priya Shah", similarity: 0.2),
                                           candidate("Hey Tig,", "Nguyen", similarity: 0)]), [])
    }

    func testNeedsAsManyWords() {
        XCTAssertEqual(NameCandidate.pick([candidate("to Priya Shah", "Priya Shah", similarity: 0.77),
                                           candidate("Priya Shah and", "Priya Shah", similarity: 0.71)]), [])
    }

    func testNeedsTheAudioToAgree() {
        XCTAssertEqual(NameCandidate.pick([candidate("Sioban", "Siobhan", similarity: 0.86, passed: false)]), [])
    }

    func testOverlappingCandidatesKeepTheBestSupported() {
        let weak = candidate("Sioban", "Siobhan", similarity: 0.86, margin: 1)
        let strong = candidate("Sioban", "Shioban", similarity: 0.9, margin: 4)
        XCTAssertEqual(NameCandidate.pick([weak, strong]), [strong])
    }

    func testSeveralReplacementsKeepTheirPlaces() {
        let chosen = NameCandidate.pick([candidate("Tig", "Tadhg", similarity: 0.6), candidate("Sioban", "Siobhan", similarity: 0.86)])
        XCTAssertEqual(NameCandidate.apply(chosen, to: text), "Hey Tadhg, can you send the deck to Priya Shah and Siobhan before Thursday?")
    }
}
