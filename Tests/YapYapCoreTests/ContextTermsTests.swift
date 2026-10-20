import XCTest
@testable import YapYapCore

final class ContextTermsTests: XCTestCase {
    private let email = """
    To: Design Team
    Hi all, the offsite has moved to the fourth floor. Priya Shah will bring the Fernway numbers.
    Ask Priya Shah before Thursday. Lunch is at noon.
    """

    func testFindsNamesAndMidSentenceCapitals() {
        let terms = ContextTerms.from(email)
        XCTAssertTrue(terms.contains { $0.contains("Priya") }, "\(terms)")
        XCTAssertTrue(terms.contains("Fernway"), "\(terms)")
    }

    func testSkipsOrdinarySentenceStarts() {
        let terms = ContextTerms.from(email)
        for word in ["Hi", "Ask", "Lunch", "the", "floor"] {
            XCTAssertFalse(terms.contains(word), "\(word) in \(terms)")
        }
    }

    func testMostFrequentFirstAndLimited() {
        let terms = ContextTerms.from("Met Zara and Omar. Then Zara left. Later Zara called Omar and Kofi.", limit: 2)
        XCTAssertEqual(terms.count, 2)
        XCTAssertEqual(terms.first, "Zara")
    }

    func testEmptyText() {
        XCTAssertEqual(ContextTerms.from(""), [])
    }
}
