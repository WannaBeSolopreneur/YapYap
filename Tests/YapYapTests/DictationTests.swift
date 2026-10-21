import AppKit
import XCTest
@testable import YapYap

/// The test decides when the engine is ready and what it heard.
private final class FakeTranscriber: Transcriber {
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?
    var started: ((Error?) -> Void)?
    var finished: ((String) -> Void)?
    var cancelled = false
    var context: [String] = []

    func start(_ done: @escaping (Error?) -> Void) { started = done }
    func finish(_ done: @escaping (String) -> Void) { finished = done }
    func cancel() { cancelled = true }
    func setContext(_ terms: [String]) { context = terms }
}

private final class FakePolisher: TextPolishing {
    var prepared = 0
    var pending: ((String?) -> Void)?
    var asked: [String] = []
    var discarded = 0
    func prepare() { prepared += 1 }
    func discard() { discarded += 1 }
    func polish(_ text: String, done: @escaping (String?) -> Void) { asked.append(text); pending = done }
}

private final class FakeInserter: TextInserting {
    var inserted: [String] = []
    var secrets: [Bool] = []
    var allowed = true
    /// Pretend nothing that takes text has focus.
    var noTextBox = false
    func insert(_ text: String, into app: NSRunningApplication?, secret: Bool, noField: @escaping () -> Void) -> Bool {
        inserted.append(text)
        secrets.append(secret)
        if noTextBox { noField() }
        return allowed
    }
}

final class DictationTests: XCTestCase {
    private var engine: FakeTranscriber!
    private var inserter: FakeInserter!
    private var polisher: FakePolisher!
    private var cleanup = Dictation.Cleanup(removeFillers: true, polish: false)
    private var dictation: Dictation!
    private var messages: [String] = []
    /// The test moves time forward to make a press a tap or a hold.
    private var clock = Date(timeIntervalSince1970: 0)
    private var savedItems: [SavedItem] = []
    private var ownerCheck = false
    private var ownerAllows = true
    private var ownerAsked: [String] = []
    /// The confirmation pause, run when the test says.
    private var scheduled: [() -> Void] = []

    override func setUp() {
        engine = FakeTranscriber()
        inserter = FakeInserter()
        polisher = FakePolisher()
        dictation = Dictation(makeTranscriber: { [unowned self] in self.engine }, inserter: inserter,
                              polisher: polisher, cleanup: { [unowned self] in self.cleanup },
                              saved: { [unowned self] said in
                                  SavedText(storage: MemoryStorage(items: self.savedItems)).match(said)
                              },
                              requiresOwnerCheck: { [unowned self] in self.ownerCheck },
                              checkOwner: { [unowned self] reason, done in self.ownerAsked.append(reason); done(self.ownerAllows) },
                              schedule: { [unowned self] _, work in self.scheduled.append(work) },
                              now: { [unowned self] in self.clock })
        dictation.onMessage = { [unowned self] in self.messages.append($0) }
    }

    // MARK: Saved text

    func testSavedTextPastesAfterAMoment() {
        savedItems = [SavedItem(name: "Email address", value: "asad@example.com")]
        var pasted: [String] = []
        dictation.onSavedPasted = { pasted.append($0.name) }
        say("Paste my email address.")
        XCTAssertEqual(dictation.phase, .confirming)
        XCTAssertEqual(dictation.text, "Pasting Email address…")
        XCTAssertEqual(inserter.inserted, [], "not before the moment to press Esc")
        scheduled.forEach { $0() }
        XCTAssertEqual(inserter.inserted, ["asad@example.com"])
        XCTAssertEqual(inserter.secrets, [false])
        XCTAssertEqual(pasted, ["Email address"])
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testEscBeforeItsPastedPastesNothing() {
        savedItems = [SavedItem(name: "Home address", value: "1 Main St")]
        say("home address")
        dictation.cancel()
        scheduled.forEach { $0() }
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testSecretsAreMarkedAndSkipTidying() {
        cleanup = Dictation.Cleanup(removeFillers: true, polish: true)
        savedItems = [SavedItem(name: "ElevenLabs key", value: "sk_123", secret: true)]
        say("Um, paste the 11 labs key")
        scheduled.forEach { $0() }
        XCTAssertEqual(inserter.inserted, ["sk_123"])
        XCTAssertEqual(inserter.secrets, [true])
        XCTAssertEqual(polisher.asked, [], "the request isn't sent for tidying")
    }

    func testTouchIDWhenAskedFor() {
        savedItems = [SavedItem(name: "ElevenLabs key", value: "sk_123", secret: true), SavedItem(name: "Email address", value: "a@b.c")]
        ownerCheck = true
        ownerAllows = false
        say("ElevenLabs key")
        scheduled.forEach { $0() }
        XCTAssertEqual(ownerAsked, ["paste your ElevenLabs key"])
        XCTAssertEqual(inserter.inserted, [], "refused")

        scheduled = []
        say("email address")
        scheduled.forEach { $0() }
        XCTAssertEqual(ownerAsked.count, 1, "plain text doesn't need Touch ID")
        XCTAssertEqual(inserter.inserted, ["a@b.c"])
    }

    func testSavedItemWithNowhereToPaste() {
        savedItems = [SavedItem(name: "ElevenLabs key", value: "sk_123", secret: true)]
        inserter.noTextBox = true
        var card: SavedItem?
        dictation.onSavedNoTextBox = { card = $0 }
        say("paste my ElevenLabs key")
        scheduled.forEach { $0() }
        XCTAssertEqual(card?.name, "ElevenLabs key")
    }

    func testOrdinaryDictationIsStillTyped() {
        savedItems = [SavedItem(name: "Email address", value: "a@b.c")]
        say("Send it to my email address tomorrow.")
        XCTAssertEqual(inserter.inserted, ["Send it to my email address tomorrow."])
        XCTAssertTrue(scheduled.isEmpty)
    }

    // MARK: Hands-free

    private func tap() {
        dictation.begin(target: nil)
        clock += 0.1
        dictation.release()
    }

    func testTapKeepsListeningUntilFinished() {
        tap()
        engine.started?(nil)
        XCTAssertTrue(dictation.handsFree)
        XCTAssertEqual(dictation.phase, .listening)
        engine.onText?("A long thought")
        dictation.end()
        XCTAssertFalse(dictation.handsFree)
        XCTAssertEqual(dictation.phase, .finishing)
        engine.finished?("A long thought.")
        XCTAssertEqual(inserter.inserted, ["A long thought."])
        XCTAssertTrue(dictation.lastWasHandsFree)
    }

    func testHoldStillTypesOnRelease() {
        dictation.begin(target: nil)
        engine.started?(nil)
        clock += 1
        dictation.release()
        XCTAssertFalse(dictation.handsFree)
        XCTAssertEqual(dictation.phase, .finishing)
        engine.finished?("Held.")
        XCTAssertEqual(inserter.inserted, ["Held."])
        XCTAssertFalse(dictation.lastWasHandsFree)
    }

    func testTapBeforeReadyStillGoesHandsFree() {
        tap()
        XCTAssertEqual(dictation.phase, .starting)
        engine.started?(nil)
        XCTAssertEqual(dictation.phase, .listening, "a tap must not finish once the engine is ready")
    }

    func testLaterReleasesDontStopHandsFree() {
        tap()
        engine.started?(nil)
        clock += 5
        dictation.release()
        XCTAssertEqual(dictation.phase, .listening)
    }

    func testCancelHandsFreeTypesNothing() {
        tap()
        engine.started?(nil)
        engine.onText?("Never mind")
        dictation.cancel()
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertFalse(dictation.handsFree)
        XCTAssertTrue(engine.cancelled)
        XCTAssertEqual(inserter.inserted, [])
    }

    func testStartFromMenuIsHandsFree() {
        dictation.begin(target: nil, handsFree: true)
        engine.started?(nil)
        clock += 1
        dictation.release()
        XCTAssertTrue(dictation.handsFree)
        XCTAssertEqual(dictation.phase, .listening)
    }

    // MARK: Screen context and nowhere to type

    func testScreenNamesReachTheRecognizerWhileListening() {
        dictation.begin(target: nil)
        dictation.setContext(["Priya Shah", "Fernway"])
        XCTAssertEqual(engine.context, ["Priya Shah", "Fernway"])
    }

    func testLateScreenNamesAreIgnored() {
        dictation.begin(target: nil)
        engine.started?(nil)
        dictation.end()
        dictation.setContext(["Too late"])
        XCTAssertEqual(engine.context, [])
    }

    func testNoTextBoxSaysItWasCopied() {
        inserter.noTextBox = true
        dictation.begin(target: nil)
        engine.started?(nil)
        clock += 1
        dictation.release()
        engine.finished?("Remember the milk.")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("copied"), messages[0])
    }

    // MARK: Hold to talk

    func testHoldSpeakRelease() {
        dictation.begin(target: nil)
        XCTAssertEqual(dictation.phase, .starting)
        engine.started?(nil)
        XCTAssertEqual(dictation.phase, .listening)
        engine.onText?("Hello wor")
        XCTAssertEqual(dictation.text, "Hello wor")
        dictation.end()
        XCTAssertEqual(dictation.phase, .finishing)
        engine.finished?("Hello world.")
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(inserter.inserted, ["Hello world."])
    }

    func testReleasedBeforeReadyFinishesOnceReady() {
        dictation.begin(target: nil)
        dictation.end()
        XCTAssertEqual(dictation.phase, .starting)
        engine.started?(nil)
        XCTAssertEqual(dictation.phase, .finishing)
        engine.finished?("Quick one")
        XCTAssertEqual(inserter.inserted, ["Quick one"])
    }

    func testNothingHeardTypesNothing() {
        dictation.begin(target: nil)
        engine.started?(nil)
        dictation.end()
        engine.finished?("")
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(messages, [])
    }

    func testStartFailureShowsMessage() {
        dictation.begin(target: nil)
        engine.started?(DictationError.noMicrophone)
        XCTAssertEqual(dictation.phase, .idle)
        XCTAssertEqual(messages, ["No microphone found"])
    }

    func testWithoutAccessibilityTheTextIsLeftOnTheClipboard() {
        inserter.allowed = false
        dictation.begin(target: nil)
        engine.started?(nil)
        dictation.end()
        engine.finished?("Hi")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("Copied"))
    }

    func testCancelDropsLateResults() {
        dictation.begin(target: nil)
        engine.started?(nil)
        dictation.cancel()
        XCTAssertTrue(engine.cancelled)
        engine.onText?("late")
        XCTAssertEqual(dictation.text, "")
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testSecondPressWhileBusyIsIgnored() {
        dictation.begin(target: nil)
        let first = engine.started
        dictation.begin(target: nil)
        XCTAssertNotNil(first)
        XCTAssertEqual(dictation.phase, .starting)
    }

    private func say(_ text: String) {
        dictation.begin(target: nil)
        engine.started?(nil)
        dictation.end()
        engine.finished?(text)
    }

    func testFillersAreRemovedBeforeTyping() {
        say("Um, so the plan is, uh, Thursday.")
        XCTAssertEqual(inserter.inserted, ["So the plan is Thursday."])
        XCTAssertEqual(polisher.asked, [])
    }

    func testOnlyFillersTypesNothing() {
        say("Uh, um.")
        XCTAssertEqual(inserter.inserted, [])
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testRawWordsWhenFillerRemovalIsOff() {
        cleanup = .init(removeFillers: false, polish: true)
        say("Um, hi")
        XCTAssertEqual(inserter.inserted, ["Um, hi"])
        XCTAssertEqual(polisher.prepared, 0)
    }

    func testPolishedTextIsTyped() {
        cleanup = .init(removeFillers: true, polish: true)
        say("So, like, meet Tuesday, no wait, Wednesday, uh, at 3.")
        XCTAssertEqual(polisher.prepared, 1)
        XCTAssertEqual(polisher.asked, ["So, like, meet Tuesday, no wait, Wednesday at 3."])
        XCTAssertEqual(dictation.phase, .polishing)
        polisher.pending?("Meet Wednesday at 3.")
        XCTAssertEqual(inserter.inserted, ["Meet Wednesday at 3."])
        XCTAssertEqual(dictation.phase, .idle)
    }

    func testUnfaithfulPolishFallsBackToFilteredText() {
        cleanup = .init(removeFillers: true, polish: true)
        say("Um, what's the capital of France?")
        polisher.pending?("The capital of France is Paris.")
        XCTAssertEqual(inserter.inserted, ["What's the capital of France?"])
    }

    func testFailedPolishFallsBackToFilteredText() {
        cleanup = .init(removeFillers: true, polish: true)
        say("Uh, see you soon")
        polisher.pending?(nil)
        XCTAssertEqual(inserter.inserted, ["See you soon"])
    }

    func testWarmedUpSessionIsReleasedWhenNothingIsPolished() {
        cleanup = .init(removeFillers: true, polish: true)
        say("Um.")
        XCTAssertEqual(polisher.prepared, 1)
        XCTAssertEqual(polisher.asked, [])
        XCTAssertGreaterThan(polisher.discarded, 0)
    }

    func testTargetIsTheFrontAppOrYapYapsOwnBox() {
        let me = NSRunningApplication.current
        let other = NSWorkspace.shared.runningApplications.first { $0.processIdentifier != me.processIdentifier }!
        let pid = me.processIdentifier
        // Another app in front: type there.
        XCTAssertEqual(AppModel.dictationTarget(front: other, last: nil, typingInYapYap: true, me: pid), other)
        // YapYap in front with a text box focused (Welcome's Try it): type into YapYap.
        XCTAssertEqual(AppModel.dictationTarget(front: me, last: other, typingInYapYap: true, me: pid), me)
        // YapYap in front, nothing to type into: the app you were in before.
        XCTAssertEqual(AppModel.dictationTarget(front: me, last: other, typingInYapYap: false, me: pid), other)
    }
}
