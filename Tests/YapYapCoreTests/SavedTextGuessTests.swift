import XCTest
@testable import YapYapCore

final class SavedTextGuessTests: XCTestCase {
    private func guess(_ text: String) -> String { SavedTextGuess.guess(text).name }

    func testPersonalDetails() {
        XCTAssertEqual(guess("sam@example.com"), "Email address")
        XCTAssertEqual(guess("  sam.lee+work@mail.example.co.uk \n"), "Email address")
        XCTAssertEqual(guess("+1 (415) 555-0134"), "Phone number")
        XCTAssertEqual(guess("https://yapyap.cc/download"), "Link")
        XCTAssertFalse(SavedTextGuess.guess("sam@example.com").secret)
    }

    func testKnownKeys() {
        XCTAssertEqual(SavedTextGuess.guess("sk-ant-api03-AbCdEf0123456789xyz").name, "Anthropic key")
        XCTAssertTrue(SavedTextGuess.guess("sk-ant-api03-AbCdEf0123456789xyz").secret)
        XCTAssertEqual(guess("sk-proj-AbCdEf0123456789xyz"), "OpenAI key")
        XCTAssertEqual(guess("sk_live_51AbCdEf0123456789"), "Stripe key")
        XCTAssertEqual(guess("sk_3f9a0b1c2d3e4f5a6b7c8d9e"), "ElevenLabs key")
        XCTAssertEqual(guess("ghp_AbCdEf0123456789AbCdEf0123456789"), "GitHub token")
        XCTAssertEqual(guess("AKIAIOSFODNN7EXAMPLE"), "AWS key")
    }

    func testUnknownTokensAreSecret() {
        XCTAssertEqual(SavedTextGuess.guess("a8f3k29dl3kd93kd0slk3m").name, "API key")
        XCTAssertTrue(SavedTextGuess.guess("a8f3k29dl3kd93kd0slk3m").secret)
    }

    func testOtherTextIsLeftToName() {
        XCTAssertEqual(guess("1 Main Street, Springfield"), "")
        XCTAssertEqual(guess("Thanks so much, talk soon!"), "")
        XCTAssertEqual(guess("sk-short"), "", "too short to be a key")
        XCTAssertEqual(guess("internationalization"), "", "a long word isn't a key")
    }
}
