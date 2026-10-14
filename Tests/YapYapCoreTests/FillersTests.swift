import XCTest
@testable import YapYapCore

final class FillersTests: XCTestCase {
    func testStripsFillerSoundsAndTidiesPunctuation() {
        XCTAssertEqual(Fillers.strip("Um, so the plan is, uh, Thursday."), "So the plan is Thursday.")
        XCTAssertEqual(Fillers.strip("I think, umm... we should go"), "I think we should go")
        XCTAssertEqual(Fillers.strip("Okay, er, let's begin"), "Okay, let's begin")
        XCTAssertEqual(Fillers.strip("Bring the numbers, uh."), "Bring the numbers.")
        XCTAssertEqual(Fillers.strip("Hmm. Okay, er, let's start. Uh, first item"), "Okay, let's start. First item")
        XCTAssertEqual(Fillers.strip("uh"), "")
    }

    func testLeavesRealWordsAlone() {
        let text = "I like the umbrella, the hummus and the ahead-of-time plan. Uh-oh, you know what I mean."
        XCTAssertEqual(Fillers.strip(text), text)
        XCTAssertEqual(Fillers.strip("Ahmed and Erma met at the museum."), "Ahmed and Erma met at the museum.")
    }

    func testFaithfulCleanupIsAccepted() {
        let said = "So, like, we should, you know, meet on Tuesday, no wait, Wednesday at 3."
        XCTAssertTrue(Fillers.isFaithful("We should meet on Wednesday at 3.", to: said))
        XCTAssertTrue(Fillers.isFaithful("So we should meet on Wednesday at 3.", to: said))
    }

    func testAnswersAndRewritesAreRejected() {
        let question = "What's the capital of France?"
        XCTAssertFalse(Fillers.isFaithful("The capital of France is Paris.", to: question))
        XCTAssertFalse(Fillers.isFaithful("Here is the cleaned text: we should meet Wednesday.", to: "we should meet Wednesday"))
        XCTAssertFalse(Fillers.isFaithful("", to: "hello there"))
    }
}
