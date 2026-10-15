import AppKit
import YapYapCore
import XCTest
@testable import YapYap

/// Records what it was asked to say; the test plays the voice's callbacks.
private final class FakeSpeaker: SpeechEngine {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var isPaused = false
    var spokeFrom: [Int] = []

    func speak(_ doc: Doc, from wordIndex: Int) { spokeFrom.append(wordIndex); isPaused = false }
    func togglePause() { isPaused.toggle() }
    func stop() { isPaused = false }
}

final class AppModelTests: XCTestCase {
    private var voice: FakeSpeaker!
    private var model: AppModel!
    private var history: History!
    // Words: 0 One 1 two. 2 Three 3 four.
    private let doc = Doc(blocks: [[OCRLine(text: "One two. Three four.", rect: .zero, words: ["One", "two.", "Three", "four."].map {
        OCRWord(text: $0, rect: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.05))
    })]])

    override func setUp() {
        _ = NSApplication.shared
        voice = FakeSpeaker()
        history = History(file: nil)
        model = AppModel(controller: Controller(speaker: voice), history: history)
    }

    override func tearDown() {
        model.stop()
    }

    private func start() {
        model.controller.begin(doc, target: .region, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
    }

    func testStartsPreparingThenReadsOnFirstWord() {
        start()
        XCTAssertEqual(model.phase, .preparing)
        XCTAssertEqual(voice.spokeFrom, [0])
        voice.onWord?(0)
        XCTAssertEqual(model.phase, .reading)
        voice.onWord?(3)
        XCTAssertEqual(model.progress, 1, accuracy: 0.001)
    }

    func testPauseAndResume() {
        start()
        voice.onWord?(1)
        model.togglePause()
        XCTAssertEqual(model.phase, .paused)
        model.togglePause()
        XCTAssertEqual(model.phase, .reading)
    }

    func testSkipMovesBetweenSentences() {
        start()
        voice.onWord?(0)
        model.skip(by: 1)
        XCTAssertEqual(voice.spokeFrom.last, 2)
        voice.onWord?(2)
        model.skip(by: -1)
        XCTAssertEqual(voice.spokeFrom.last, 0, "at a sentence start, back goes to the previous one")
    }

    func testSkipWhilePausedResumes() {
        start()
        voice.onWord?(0)
        model.togglePause()
        model.skip(by: 1)
        XCTAssertEqual(model.phase, .reading)
        XCTAssertFalse(voice.isPaused)
    }

    func testFinishingAndStoppingReturnToIdle() {
        start()
        voice.onWord?(0)
        voice.onFinish?()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.isReading)

        start()
        model.stop()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.progress, 0)
    }

    func testMessagesShowAndClear() {
        model.show("No text found")
        XCTAssertEqual(model.message, "No text found")
    }
    func testFinishedReadIsCountedInHistory() {
        start()
        voice.onWord?(0)
        voice.onWord?(2)
        model.stop()
        XCTAssertEqual(history.totals.wordsRead, 3)
        XCTAssertEqual(history.entries.first?.kind, .read)
        XCTAssertEqual(history.entries.first?.text, "One two. Three four.")
    }

    func testStoppingBeforeAnyWordCountsNothing() {
        start()
        model.stop()
        XCTAssertEqual(history.totals.wordsRead, 0)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testHistoryOffKeepsTotalsOnly() {
        history.addDictation("hello there friend", keep: false)
        XCTAssertEqual(history.totals.wordsDictated, 3)
        XCTAssertTrue(history.entries.isEmpty)
    }
}

final class ShortcutTests: XCTestCase {
    private func press(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testRecordsModifiersInAppleOrder() {
        let combo = KeyCombo(event: press("t", code: 17, [.command, .shift, .control]))
        XCTAssertEqual(combo?.displayKeys, ["⌃", "⇧", "⌘", "T"])
    }

    func testRejectsPlainKeysButAllowsFunctionKeys() {
        XCTAssertNil(KeyCombo(event: press("t", code: 17, [])))
        XCTAssertNil(KeyCombo(event: press("T", code: 17, [.shift])), "Shift alone would block typing capitals")
        XCTAssertEqual(KeyCombo(event: press("\u{F708}", code: 96, []))?.displayKeys, ["F5"])
    }

    func testRejectsYapYapsOwnShortcuts() {
        let model = AppModel(controller: Controller(speaker: Speaker()))
        let readWindow = KeyCombo(keyCode: Keys.r, modifiers: Keys.optCmd, keyName: "R")
        XCTAssertNotNil(model.setRegionShortcut(readWindow))
        XCTAssertNotEqual(model.settings.regionShortcut, readWindow)
    }

    func testAcceptsAFreeShortcut() {
        let model = AppModel(controller: Controller(speaker: Speaker()))
        let combo = KeyCombo(keyCode: 96, modifiers: 0, keyName: "F5")
        XCTAssertNil(model.setRegionShortcut(combo))
        XCTAssertEqual(model.settings.regionShortcut, combo)
        _ = model.setRegionShortcut(.defaultRegion)
    }

    func testNoVoiceDownloadAfterTheUserRemovedThem() {
        let model = AppModel(controller: Controller(speaker: Speaker()))
        let was = model.settings.autoDownloadVoices
        defer { model.settings.autoDownloadVoices = was }
        model.settings.autoDownloadVoices = false
        model.downloadVoicesIfNeeded()
        XCTAssertEqual(model.download.state, KokoroDownload.State.idle)
    }

}
