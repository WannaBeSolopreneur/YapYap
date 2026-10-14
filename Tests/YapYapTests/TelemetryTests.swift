import AppKit
import YapYapCore
import XCTest
@testable import YapYap

private final class SilentSpeaker: SpeechEngine {
    var onWord: ((Int) -> Void)?
    var onFinish: (() -> Void)?
    var isPaused = false

    func speak(_ doc: Doc, from wordIndex: Int) {}
    func togglePause() {}
    func stop() {}
}

final class TelemetryTests: XCTestCase {
    private var sent: [(name: String, parameters: [String: String], value: Double?)] = []
    private var on = true
    private var voice: SilentSpeaker!
    private var model: AppModel!
    private let doc = Doc(blocks: [[OCRLine(text: "Secret plans here", rect: .zero, words: ["Secret", "plans", "here"].map {
        OCRWord(text: $0, rect: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.05))
    })]])

    override func setUp() {
        _ = NSApplication.shared
        sent = []
        on = true
        voice = SilentSpeaker()
        model = makeModel(appID: "test-app")
    }

    override func tearDown() {
        model.stop()
    }

    private func makeModel(appID: String?) -> AppModel {
        let telemetry = Telemetry(appID: appID, isOn: { [unowned self] in self.on }) { [unowned self] in
            self.sent.append(($0, $1, $2))
        }
        return AppModel(controller: Controller(speaker: voice), history: History(file: nil), telemetry: telemetry)
    }

    private func readTwoWords() {
        model.controller.begin(doc, target: .region, frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        voice.onWord?(0)
        voice.onWord?(1)
        model.stop()
    }

    func testFinishedReadSendsWordCountButNoText() {
        readTwoWords()
        XCTAssertEqual(sent.map(\.name), ["Read.finished"])
        XCTAssertEqual(sent[0].value, 2)
        let values = sent.flatMap { $0.parameters.values }.joined(separator: " ")
        XCTAssertFalse(values.contains("Secret") || values.contains("plans"))
    }

    func testDictationSendsWordCountButNoText() {
        model.dictation.onTyped?("meet me at noon")
        XCTAssertEqual(sent.map(\.name), ["Dictation.finished"])
        XCTAssertEqual(sent[0].value, 4)
        XCTAssertFalse(sent[0].parameters.values.contains { $0.contains("noon") })
    }

    func testNothingSentWhenOff() {
        on = false
        readTwoWords()
        model.dictation.onTyped?("hello")
        XCTAssertTrue(sent.isEmpty)
    }

    func testNothingSentWithoutAppID() {
        model = makeModel(appID: nil)
        XCTAssertFalse(model.telemetry.isAvailable)
        readTwoWords()
        XCTAssertTrue(sent.isEmpty)
    }

    func testTurningOffStopsSending() {
        model.dictation.onTyped?("one")
        on = false
        model.dictation.onTyped?("two")
        XCTAssertEqual(sent.count, 1)
    }

    func testListeningTimeIsBucketed() {
        XCTAssertEqual(Telemetry.bucket(0.2), "<1")
        XCTAssertEqual(Telemetry.bucket(3), "1-5")
        XCTAssertEqual(Telemetry.bucket(10), "5-15")
        XCTAssertEqual(Telemetry.bucket(90), "15+")
    }
}
