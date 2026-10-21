import XCTest
@testable import YapYap

final class SavedTextStoreTests: XCTestCase {
    func testSavingAddsThenReplacesByName() {
        let store = SavedText(storage: MemoryStorage())
        store.save(name: "Email address", value: "a@b.c", secret: false)
        store.save(name: " email ADDRESS ", value: "new@b.c", secret: false)
        store.save(name: "ElevenLabs key", value: "sk_1", secret: true)
        XCTAssertEqual(store.items.map(\.name), ["Email address", "ElevenLabs key"])
        XCTAssertEqual(store.named("email address")?.value, "new@b.c")
        XCTAssertEqual(store.match("paste my ElevenLabs key")?.value, "sk_1")
    }
}
