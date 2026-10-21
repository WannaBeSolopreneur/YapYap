import AppKit
import Observation
import ServiceManagement

/// What every window shows: the reading state, progress, and inline messages.
/// Wraps the Controller, which does the actual capture → OCR → speech work.
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var phase = Controller.Phase.idle
    private(set) var progress = 0.0
    /// A short inline message ("No text found"); clears itself after a few seconds.
    private(set) var message: String?
    private(set) var hasPermission = Capture.hasPermission
    private(set) var micAllowed = DictationAccess.microphone
    private(set) var accessibilityAllowed = DictationAccess.accessibility
    private(set) var speechAllowed = DictationAccess.speech
    var dictationAllowed: Bool { micAllowed && accessibilityAllowed && speechAllowed }
    /// Screen Recording is switched on but only takes effect after a restart.
    private(set) var screenRecordingNeedsRestart = false
    var allPermissionsGranted: Bool { hasPermission && dictationAllowed }
    private(set) var kokoroInstalled = KokoroSpeaker.isInstalled
    let download = KokoroDownload()
    private(set) var dictationPhase = Dictation.Phase.idle
    /// Listening without the shortcut held; the capsule shows Done and Cancel.
    private(set) var dictationHandsFree = false
    /// What was dictated last, for Paste Last Dictation. In memory only.
    private(set) var lastDictation: String?
    /// What dictation has heard so far.
    private(set) var dictationText = ""
    private(set) var micLevel: Float = 0

    /// Set by the SwiftUI scene so non-view code can open the Welcome window.
    @ObservationIgnored var openWelcome: () -> Void = {}

    @ObservationIgnored let controller: Controller
    @ObservationIgnored let dictation: Dictation
    @ObservationIgnored private let bar = PlayerBarPanel()
    @ObservationIgnored private let dictationBar = DictationPanel()
    @ObservationIgnored private var messageWork: DispatchWorkItem?
    @ObservationIgnored private var hideBarWork: DispatchWorkItem?
    @ObservationIgnored private var dictationEscape: HotKey?

    var settings: Settings { .shared }
    var isReading: Bool { phase != .idle }

    @ObservationIgnored let history: History
    /// Greets you on Home. Replaced in sample snapshots.
    @ObservationIgnored var fullUserName = NSFullUserName()
    @ObservationIgnored let telemetry: Telemetry

    init(controller: Controller = Controller(), dictation: Dictation = Dictation(), history: History = .shared,
         telemetry: Telemetry = .shared) {
        self.controller = controller
        self.dictation = dictation
        self.history = history
        self.telemetry = telemetry
        dictation.onStateChange = { [weak self] in self?.syncDictation() }
        dictation.onMessage = { [weak self] in self?.show($0) }
        dictation.onNoTextBox = { [weak self] in self?.showLeftover($0) }
        dictation.onSavedNoTextBox = { [weak self] item in
            // A secret's card names it; the value only goes to the clipboard.
            self?.showLeftover(item.secret ? item.name : item.value, copying: item.value, secret: item.secret)
        }
        dictation.onSavedPasted = { [weak self] item in
            history.addDictation("Pasted \(item.name)")
            if !item.secret { self?.lastDictation = item.value }
            telemetry.pastedSaved(secret: item.secret)
        }
        dictation.onTyped = { [weak self, weak dictation] text in
            self?.lastDictation = text
            history.addDictation(text)
            telemetry.dictated(words: text.split(whereSeparator: \.isWhitespace).count,
                               handsFree: dictation?.lastWasHandsFree ?? false,
                               engine: dictation?.lastEngine ?? "apple")
        }
        controller.onReadFinished = { text, words, seconds in
            history.addRead(text, words: words, seconds: seconds)
            telemetry.readFinished(words: words, seconds: seconds)
        }
        controller.onReadStarted = { target, wait in
            if case .window = target { telemetry.readStarted(source: .window, wait: wait) }
            else { telemetry.readStarted(source: .region, wait: wait) }
        }
        controller.onReadFailed = { telemetry.readFailed($0) }
        controller.onStateChange = { [weak self] in self?.sync() }
        controller.onMessage = { [weak self] in self?.show($0) }
        controller.onNeedsPermission = { [weak self] in
            self?.refreshPermission()
            self?.openWelcome()
        }
        controller.excludedWindows = { [weak self] in
            guard let self else { return [] }
            return [self.bar, self.dictationBar].filter(\.isVisible).map { CGWindowID($0.windowNumber) }
        }
        download.onFinish = { [weak self] ok in
            self?.kokoroInstalled = KokoroSpeaker.isInstalled
            if ok, let first = KokoroSpeaker.voiceNames().first, Settings.shared.voiceID.flatMap(KokoroSpeaker.voiceName) == nil {
                Settings.shared.voiceID = KokoroSpeaker.id(for: first)
            }
        }
    }

    // MARK: Actions

    func readWindow() { controller.readWindow() }
    func readRegion() { controller.readRegion() }
    func togglePause() { controller.togglePause() }
    func stop() { controller.stop() }
    func skip(by direction: Int) { controller.skip(by: direction) }

    /// Dictation shortcut went down: pause any reading so the mic doesn't hear it, then listen.
    /// In hands-free mode, pressing it again finishes instead. `handsFree` (Start Dictation in
    /// the menu) listens until Done, the shortcut or Esc.
    func startDictation(handsFree: Bool = false) {
        if dictation.handsFree { return finishDictation() }
        guard dictation.phase == .idle else { return }
        refreshPermission()
        guard dictationAllowed else {
            show("Finish allowing dictation first")
            WelcomeWindow.show(at: WelcomeWindow.permissionsStep)
            return
        }
        if controller.phase == .reading { controller.togglePause() }
        let typingHere = (NSApp.keyWindow?.firstResponder as? NSTextView)?.isEditable == true
        let target = Self.dictationTarget(front: NSWorkspace.shared.frontmostApplication,
                                          last: controller.lastApp, typingInYapYap: typingHere)
        dictation.begin(target: target, handsFree: handsFree)
        ScreenContext.terms(in: target) { [weak self] in self?.dictation.setContext($0) }
    }

    /// Where dictated text goes: the app in front. When that's YapYap itself, its own text box
    /// if one has focus (Welcome's "Try it"), otherwise the app you were in before.
    static func dictationTarget(front: NSRunningApplication?, last: NSRunningApplication?, typingInYapYap: Bool,
                                me: pid_t = getpid()) -> NSRunningApplication? {
        guard front?.processIdentifier == me else { return front }
        return typingInYapYap ? front : last
    }

    /// Dictation shortcut came back up: types after a hold, keeps listening after a quick tap.
    func stopDictation() { dictation.release() }

    /// Done (or the shortcut again) in hands-free mode: type what was said.
    func finishDictation() { dictation.end() }

    /// Cancel or Esc: stop listening and type nothing.
    func cancelDictation() { dictation.cancel() }

    /// Menu bar: type the last dictation again where the cursor is now (or copy it if there's
    /// no text box).
    func pasteLastDictation(inserter: TextInserting = Paster()) {
        guard let text = lastDictation else { return }
        let app = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? controller.lastApp : $0 }
        let typed = inserter.insert(text, into: app) { [weak self] in self?.showLeftover(text) }
        if !typed { show("Copied your last dictation. Press ⌘V to paste.") }
    }

    // MARK: Nowhere to type

    /// Dictated with no text box in focus: the capsule stays up showing everything that was said,
    /// with Copy, until it's copied, closed (✕ or Esc) or a new dictation starts.
    private(set) var leftover: String?
    private(set) var leftoverCopied = false
    @ObservationIgnored private var leftoverEscape: HotKey?
    /// What Copy puts on the clipboard: the leftover itself, or a saved secret the card only names.
    @ObservationIgnored private var leftoverValue: String?
    @ObservationIgnored private var leftoverSecret = false

    func showLeftover(_ text: String, copying value: String? = nil, secret: Bool = false) {
        leftover = text
        leftoverValue = value
        leftoverSecret = secret
        leftoverCopied = false
        leftoverEscape = HotKey(keyCode: Keys.escape, modifiers: 0) { [weak self] in self?.dismissLeftover() }
        dictationBar.ignoresMouseEvents = false
        dictationBar.show()
        // The card draws on the next pass; size the panel to it then.
        DispatchQueue.main.async { [weak self] in self?.dictationBar.refit() }
    }

    /// For `--dictate-test`: what the dictation panel is doing.
    var dictationBarState: String {
        "visible=\(dictationBar.isVisible) alpha=\(dictationBar.alphaValue) frame=\(dictationBar.frame) leftover=\(leftover != nil)"
    }

    /// Screenshots only: the card's content without showing the panel.
    func previewLeftover(_ text: String) { leftover = text }
    /// Screenshots only: the capsule about to paste a saved item.
    func previewSaved(_ text: String) {
        dictationPhase = .confirming
        dictationText = text
    }

    func copyLeftover() {
        guard let leftover else { return }
        Paster.copy(leftoverValue ?? leftover, secret: leftoverSecret)
        leftoverCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard self?.leftover == leftover else { return }
            self?.dismissLeftover()
        }
    }

    func dismissLeftover() {
        guard leftover != nil else { return }
        leftover = nil
        leftoverCopied = false
        leftoverEscape = nil
        dictationBar.ignoresMouseEvents = !dictationHandsFree
        if dictation.phase == .idle { dictationBar.fadeOut() }
    }

    func read(_ window: NSWindow) {
        guard let frame = Capture.frame(of: CGWindowID(window.windowNumber)) else { return }
        controller.read(TargetWindow(id: CGWindowID(window.windowNumber), frame: frame))
    }

    func setSpeed(_ speed: Double) {
        guard abs(speed - settings.speed) > 0.001 else { return }
        controller.setSpeed((speed * 4).rounded() / 4)
    }

    func changeSpeed(by delta: Double) {
        controller.changeSpeed(by: delta)
        if !bar.isVisible { Toast.show(String(format: "Speed %g×", settings.speed)) }
    }

    func setVoice(_ id: String) {
        settings.voiceID = id
        controller.restartIfReading()
    }

    func previewVoice() {
        controller.preview("Hi, I'm \(voiceName). I'll read along with you and highlight each word as I go.")
    }

    var voiceName: String {
        if let id = settings.voiceID, let name = KokoroSpeaker.voiceName(from: id), kokoroInstalled {
            return KokoroSpeaker.shortName(for: name)
        }
        return Speaker.voice()?.name ?? "System Voice"
    }

    var currentVoiceID: String? {
        if let id = settings.voiceID, KokoroSpeaker.voiceName(from: id) != nil, kokoroInstalled { return id }
        return Speaker.voice()?.identifier
    }

    /// At launch: start fetching the natural voices in the background, so a new user hears them
    /// on their first read instead of the macOS voice. The first one (Heart) is picked when they arrive.
    func downloadVoicesIfNeeded() {
        guard settings.autoDownloadVoices, !kokoroInstalled, download.state != .downloading else { return }
        download.start()
    }

    func removeKokoro() {
        let alert = NSAlert()
        alert.messageText = "Remove natural voices?"
        alert.informativeText = "This frees about 340 MB. You can download them again at any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if KokoroSpeaker.isSelected { controller.stop() }
        KokoroSpeaker.uninstall()
        settings.autoDownloadVoices = false
        if settings.voiceID.flatMap(KokoroSpeaker.voiceName) != nil { settings.voiceID = nil }
        kokoroInstalled = false
    }

    // MARK: Shortcuts

    @ObservationIgnored private var hotKeys: [HotKey] = []
    @ObservationIgnored private var regionHotKey: HotKey?
    @ObservationIgnored private var dictationHotKey: HotKey?

    /// The fixed shortcuts; Read Region's is chosen in Settings.
    private var fixedBindings: [(combo: KeyCombo, action: () -> Void)] {
        [
            (KeyCombo(keyCode: Keys.r, modifiers: Keys.optCmd, keyName: "R"), { [weak self] in self?.readWindow() }),
            (KeyCombo(keyCode: Keys.p, modifiers: Keys.optCmd, keyName: "P"), { [weak self] in self?.togglePause() }),
            (KeyCombo(keyCode: Keys.equal, modifiers: Keys.optCmd, keyName: "="), { [weak self] in self?.changeSpeed(by: 0.25) }),
            (KeyCombo(keyCode: Keys.minus, modifiers: Keys.optCmd, keyName: "−"), { [weak self] in self?.changeSpeed(by: -0.25) }),
        ]
    }

    func registerHotKeys() {
        hotKeys = fixedBindings.compactMap { b in HotKey(keyCode: b.combo.keyCode, modifiers: b.combo.modifiers, handler: b.action) }
        regionHotKey = makeRegionHotKey(settings.regionShortcut)
        dictationHotKey = makeDictationHotKey(settings.dictationShortcut)
    }

    /// Turned off while recording a new shortcut, so pressing one doesn't trigger it.
    func suspendHotKeys(_ suspended: Bool) {
        if suspended {
            hotKeys = []
            regionHotKey = nil
            dictationHotKey = nil
        } else {
            registerHotKeys()
        }
    }

    /// Returns an error to show, or nil when the new shortcut is active.
    func setRegionShortcut(_ combo: KeyCombo) -> String? {
        if isTaken(combo, except: settings.regionShortcut) {
            return "\(combo.displayKeys.joined()) is already a YapYap shortcut"
        }
        regionHotKey = nil
        guard let hotKey = makeRegionHotKey(combo) else {
            regionHotKey = makeRegionHotKey(settings.regionShortcut)
            return "\(combo.displayKeys.joined()) is taken by another app"
        }
        regionHotKey = hotKey
        settings.regionShortcut = combo
        return nil
    }

    private func makeRegionHotKey(_ combo: KeyCombo) -> HotKey? {
        HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers) { [weak self] in self?.readRegion() }
    }

    func setDictationShortcut(_ combo: KeyCombo) -> String? {
        if isTaken(combo, except: settings.dictationShortcut) {
            return "\(combo.displayKeys.joined()) is already a YapYap shortcut"
        }
        dictationHotKey = nil
        guard let hotKey = makeDictationHotKey(combo) else {
            dictationHotKey = makeDictationHotKey(settings.dictationShortcut)
            return "\(combo.displayKeys.joined()) is taken by another app"
        }
        dictationHotKey = hotKey
        settings.dictationShortcut = combo
        return nil
    }

    private func makeDictationHotKey(_ combo: KeyCombo) -> HotKey? {
        HotKey(keyCode: combo.keyCode, modifiers: combo.modifiers, onRelease: { [weak self] in self?.stopDictation() }) { [weak self] in
            self?.startDictation()
        }
    }

    /// Whether another YapYap shortcut already uses `combo`.
    private func isTaken(_ combo: KeyCombo, except own: KeyCombo) -> Bool {
        let all = fixedBindings.map(\.combo) + [settings.regionShortcut, settings.dictationShortcut]
        return all.contains { $0 != own && $0.keyCode == combo.keyCode && $0.modifiers == combo.modifiers }
    }

    // MARK: Permission and login

    func refreshPermission() {
        hasPermission = Capture.hasPermission
        micAllowed = DictationAccess.microphone
        accessibilityAllowed = DictationAccess.accessibility
        speechAllowed = DictationAccess.speech
        screenRecordingNeedsRestart = Capture.needsRestart
        kokoroInstalled = KokoroSpeaker.isInstalled
    }

    private(set) var launchesAtLogin = SMAppService.mainApp.status == .enabled

    func setShareUsageStats(_ on: Bool) {
        settings.shareUsageStats = on
        telemetry.update()
    }

    func setLaunchesAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show("Couldn't change Open at Login: \(error.localizedDescription)")
        }
        launchesAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: State

    private func sync() {
        phase = controller.phase
        let (current, total) = controller.progress
        progress = total > 1 ? Double(current) / Double(total - 1) : 0
        updateBar()
    }

    private func syncDictation() {
        // Assigning an @Observable property redraws its readers even when the value is the same.
        if dictationPhase != dictation.phase { dictationPhase = dictation.phase }
        if dictationText != dictation.text { dictationText = dictation.text }
        if micLevel != dictation.level { micLevel = dictation.level }
        if dictationHandsFree != dictation.handsFree {
            dictationHandsFree = dictation.handsFree
            // The capsule takes clicks for Done and Cancel only while hands-free.
            dictationBar.ignoresMouseEvents = !dictationHandsFree
        }
        // Esc cancels while hands-free, and while a saved item is about to be pasted.
        let escapes = dictation.handsFree || dictation.phase == .confirming
        if escapes != (dictationEscape != nil) {
            dictationEscape = escapes ? HotKey(keyCode: Keys.escape, modifiers: 0) { [weak self] in self?.cancelDictation() } : nil
        }
        if dictation.phase != .idle, leftover != nil {
            // A new dictation replaces the words waiting to be copied.
            leftover = nil
            leftoverCopied = false
            leftoverEscape = nil
            dictationBar.ignoresMouseEvents = !dictationHandsFree
            dictationBar.show()
            DispatchQueue.main.async { [weak self] in self?.dictationBar.refit() }
        }
        if dictation.phase == .idle {
            if leftover == nil { dictationBar.fadeOut() }
        } else if !dictationBar.isVisible {
            dictationBar.show()
        }
    }

    private func updateBar() {
        if isReading {
            hideBarWork?.cancel()
            bar.show(near: controller.frame)
        } else {
            // A new read stops the old one first; don't flicker the bar in between.
            hideBarWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.isReading else { return }
                self.bar.fadeOut()
            }
            hideBarWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    func show(_ text: String) {
        message = text
        // When nothing of ours is on screen, a toast is the only way to be seen.
        if !bar.isVisible { Toast.show(text, for: 2.5) }
        messageWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.message = nil }
        messageWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// Downloads Kokoro's model and voices with progress, cancel and retry.
@Observable
final class KokoroDownload: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case idle
        case downloading
        case failed(String)
    }

    private(set) var state = State.idle
    /// 0…1 across all files.
    private(set) var fraction = 0.0
    @ObservationIgnored var onFinish: ((Bool) -> Void)?

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var queue: [(file: String, url: URL)] = []
    @ObservationIgnored private var done: Int64 = 0
    @ObservationIgnored private var fileFinished = false

    func start() {
        guard state != .downloading else { return }
        queue = KokoroSpeaker.missingDownloads
        guard !queue.isEmpty else { return finish(ok: true) }
        state = .downloading
        fraction = 0
        done = 0
        try? FileManager.default.createDirectory(at: KokoroSpeaker.folder, withIntermediateDirectories: true)
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        next()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        state = .idle
        fraction = 0
    }

    private func next() {
        guard let item = queue.first else {
            session?.finishTasksAndInvalidate()
            session = nil
            return finish(ok: true)
        }
        fileFinished = false
        session?.downloadTask(with: item.url).resume()
    }

    private func finish(ok: Bool, error: String? = nil) {
        state = ok ? .idle : .failed(error ?? "Download failed")
        onFinish?(ok)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten written: Int64, totalBytesExpectedToWrite _: Int64) {
        fraction = min(Double(done + written) / Double(KokoroSpeaker.downloadSize), 1)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = queue.first, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let dest = KokoroSpeaker.folder.appendingPathComponent(item.file)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.moveItem(at: location, to: dest)) != nil else { return }
        done += downloadTask.countOfBytesReceived
        queue.removeFirst()
        fileFinished = true
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard s === session else { return }
        guard error == nil, fileFinished else {
            session?.invalidateAndCancel()
            session = nil
            let status = (task.response as? HTTPURLResponse)?.statusCode
            return finish(ok: false, error: error?.localizedDescription ?? "Server returned \(status ?? 0)")
        }
        next()
    }
}
