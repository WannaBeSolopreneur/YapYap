import XCTest
@testable import YapYapCore

final class SavedTextCommandTests: XCTestCase {
    private let names = ["Email address", "Home address", "ElevenLabs key", "Phone number", "Work email"]

    private func match(_ said: String) -> String? {
        SavedTextCommand.match(said, names: names).map { names[$0] }
    }

    func testTheNameAlone() {
        XCTAssertEqual(match("Email address."), "Email address")
        XCTAssertEqual(match("home address"), "Home address")
        XCTAssertEqual(match("Work email"), "Work email")
    }

    func testAskingForIt() {
        XCTAssertEqual(match("Paste my email address."), "Email address")
        XCTAssertEqual(match("Type in my home address, please"), "Home address")
        XCTAssertEqual(match("put my phone number here"), "Phone number")
    }

    func testHowSpeechRecognitionWritesNames() {
        XCTAssertEqual(match("Paste the 11 labs key"), "ElevenLabs key")
        XCTAssertEqual(match("Paste in the Eleven Labs API key."), "ElevenLabs key")
        XCTAssertEqual(match("eleven labs key"), "ElevenLabs key")
        XCTAssertEqual(match("Paste my ElevenLab key"), "ElevenLabs key")
    }

    func testShortenedNeedsAsking() {
        XCTAssertEqual(match("paste my ElevenLabs"), "ElevenLabs key")
        XCTAssertEqual(match("paste my home"), "Home address")
        XCTAssertNil(match("Home."))
        XCTAssertNil(match("Phone"))
    }

    func testOrdinaryDictationIsTyped() {
        XCTAssertNil(match("Send the deck to my email address before Thursday."))
        XCTAssertNil(match("What's your home address?"))
        XCTAssertNil(match("Paste it into the doc"))
        XCTAssertNil(match(""))
        XCTAssertNil(SavedTextCommand.match("email address", names: []))
    }

    func testNumbersInNames() {
        XCTAssertEqual(SavedTextCommand.match("paste the S three key", names: ["S3 key"]), 0)
        XCTAssertEqual(SavedTextCommand.match("paste the s3 key", names: ["S3 key"]), 0)
    }
}
