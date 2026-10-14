import AppKit
import YapYapCore

/// Glue: capture → OCR → speech, with spoken word → highlight on the overlay.
final class Controller {
    enum Target {
        case window(CGWindowID)
        case region
    }

    enum Phase {
        case idle
        /// Capturing, recognizing text or waiting for the voice to start.
        case preparing
        case reading
        case paused
    }

    /// Called on any phase or progress change.
    var onStateChange: (() -> Void)?
    /// Something the user should know ("No text found"). Shown in the UI or as a toast.
    var onMessage: ((String) -> Void)?
    /// Asked when Screen Recording isn't granted yet.
    var onNeedsPermission: (() -> Void)?
    /// The first word of a read was spoken, `wait` seconds after the read was asked for.
    var onReadStarted: ((_ target: Target, _ wait: TimeInterval) -> Void)?
    /// A read couldn't start, as a fixed code: noWindow, captureFailed or noText.
    var onReadFailed: ((_ reason: String) -> Void)?
    /// A read ended: its text, how many words were spoken and for how long.
    var onReadFinished: ((_ text: String, _ words: Int, _ seconds: Double) -> Void)?
    /// Our own floating windows, kept out of region captures.
    var excludedWindows: () -> [CGWindowID] = { [] }
    var lastApp: NSRunningApplication?

    private(set) var phase = Phase.idle
    /// Global, top-left-origin frame of what is being read.
    private(set) var frame: CGRect = .zero

    private let speaker: SpeechEngine
    private let selector = RegionSelector()

    /// The text being spoken. Stays fixed for a session so word indices remain valid.
    private var speech: Doc?
    /// Where words are on screen right now. Replaced after scroll/resize re-capture.
    private var layout: Doc?
    /// layout index = speech index + shift.
    private var shift = 0
    private var current = 0
    /// Furthest word spoken and time spent speaking this read, for the totals.
    private var furthest = -1
    private var listened = 0.0
    private var outOfSync = false
    /// When the current read was asked for, until its first word is spoken.
    private var requested: Date?

    private var target: Target?
    private var overlay: OverlayPanel?
    private var timer: Timer?
    private var ticks = 0
    private var scrollMonitor: Any?
    private var resyncWork: DispatchWorkItem?
    private var escape: HotKey?
    /// Bumped on every start/stop so late OCR results from an old session are dropped.
    private var session = 0

    var isReading: Bool { phase != .idle }
    var isPaused: Bool { phase == .paused }
    /// (current word, total words) of what is being read.
    var progress: (current: Int, total: Int) { (current, speech?.words.count ?? 0) }

    init(speaker: SpeechEngine = VoiceRouter()) {
        self.speaker = speaker
        speaker.onWord = { [weak self] i in self?.spoke(i) }
        speaker.onFinish = { [weak self] in self?.stop() }
    }

    // MARK: Commands

    func readWindow() {
        guard ensurePermission() else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.processIdentifier == getpid() ? lastApp : front
        guard let app, let window = Capture.frontWindow(of: app.processIdentifier) else {
            return fail("No window to read", reason: "noWindow")
        }
        read(window)
    }

    /// Reads a specific window, e.g. our own Welcome window for the test read.
    func read(_ window: TargetWindow) {
        guard ensurePermission() else { return }
        stop()
        // Load the voice while the window is captured and its text recognized.
        speaker.prepare()
        setPhase(.preparing)
        requested = Date()
        Capture.image(of: window.id) { [weak self] image in
            guard let image else { self?.stop(); self?.fail("Couldn't capture that window", reason: "captureFailed"); return }
            self?.start(image: image, target: .window(window.id), frame: window.frame)
        }
    }

    func readRegion() {
        guard ensurePermission() else { return }
        stop()
        // Load the voice while the region is being chosen.
        speaker.prepare()
        selector.begin { [weak self] rect in
            guard let rect else { return }
            // Let the window server remove the dimming panels before capturing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self?.setPhase(.preparing)
                self?.requested = Date()
                Capture.image(of: rect, excluding: self?.excludedWindows() ?? []) { image in
                    guard let image else { self?.stop(); self?.fail("Couldn't capture that region", reason: "captureFailed"); return }
                    self?.start(image: image, target: .region, frame: rect)
                }
            }
        }
    }

    func togglePause() {
        guard isReading else { return }
        speaker.togglePause()
        setPhase(speaker.isPaused ? .paused : .reading)
    }

    /// Previous (-1) or next (+1) sentence, like a music player's skip buttons.
    func skip(by direction: Int) {
        guard let speech, phase == .reading || phase == .paused else { return }
        let target = direction < 0 ? speech.previousSentence(from: current) : speech.nextSentence(from: current)
        guard let target else { return }
        current = target
        if speaker.isPaused { speaker.togglePause() }
        speaker.speak(speech, from: target)
        setPhase(.reading)
        updateHighlight()
    }

    /// Speaks a sample with the current voice, without capturing or highlighting anything.
    func preview(_ text: String) {
        stop()
        let words = text.split(separator: " ").map { OCRWord(text: String($0), rect: .zero) }
        speaker.speak(Doc(blocks: [[OCRLine(text: text, rect: .zero, words: words)]]), from: 0)
    }

    func stop() {
        if let speech, furthest >= 0 { onReadFinished?(speech.text, furthest + 1, listened) }
        furthest = -1
        listened = 0
        requested = nil
        session += 1
        speaker.stop()
        overlay?.orderOut(nil)
        overlay = nil
        timer?.invalidate()
        timer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        resyncWork?.cancel()
        escape = nil
        speech = nil
        layout = nil
        target = nil
        current = 0
        setPhase(.idle)
    }

    func changeSpeed(by delta: Double) {
        setSpeed(Settings.shared.speed + delta)
    }

    func setSpeed(_ speed: Double) {
        Settings.shared.speed = speed
        restartIfReading()
    }

    func restartIfReading() {
        guard let speech, phase == .reading else { return }
        speaker.speak(speech, from: current)
    }

    func refreshHighlight() {
        overlay?.highlight.needsDisplay = true
    }

    // MARK: Session

    private func start(image: CGImage, target: Target, frame: CGRect) {
        let asked = requested
        stop()
        setPhase(.preparing)
        let id = session
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let doc = try? OCR.doc(from: image)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == id else { return }
                guard let doc, !doc.words.isEmpty else { self.stop(); self.fail("No text found", reason: "noText"); return }
                self.requested = asked
                self.begin(doc, target: target, frame: frame)
            }
        }
    }

    func begin(_ doc: Doc, target: Target, frame: CGRect) {
        speech = doc
        layout = doc
        shift = 0
        outOfSync = false
        self.target = target
        self.frame = frame

        let overlay = OverlayPanel(frame: frame)
        overlay.highlight.onClick = { [weak self] p in self?.jump(to: p) }
        overlay.orderFrontRegardless()
        self.overlay = overlay

        escape = HotKey(keyCode: Keys.escape, modifiers: 0) { [weak self] in self?.stop() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in self?.scrolled() }

        current = 0
        setPhase(.preparing)
        speaker.speak(doc, from: 0)
    }

    private func spoke(_ i: Int) {
        guard speech != nil else { return }
        current = i
        furthest = max(furthest, i)
        if phase == .preparing { phase = .reading }
        if let asked = requested, let target {
            requested = nil
            onReadStarted?(target, Date().timeIntervalSince(asked))
        }
        updateHighlight()
        onStateChange?()
    }

    private func setPhase(_ p: Phase) {
        phase = p
        onStateChange?()
    }

    private func notify(_ message: String) {
        onMessage?(message)
    }

    private func fail(_ message: String, reason: String) {
        onReadFailed?(reason)
        notify(message)
    }

    private func updateHighlight() {
        guard let overlay, let speech, let layout, !outOfSync else { overlay?.highlight.clear(); return }
        func matches(_ s: Int) -> Bool {
            let j = current + s
            return layout.words.indices.contains(j) && Align.norm(layout.words[j].text) == Align.norm(speech.words[current].text)
        }
        // OCR of a re-capture differs slightly, so re-anchor locally before giving up.
        if !matches(shift), let s = Align.shift(from: speech, at: current, to: layout), matches(s) {
            shift = s
        }
        guard matches(shift) else { overlay.highlight.clear(); return }
        let word = layout.words[current + shift]
        overlay.highlight.word = word.rect
        overlay.highlight.line = layout.lineRects[word.line]
    }

    /// ⌥-click a word: read from there, using what is on screen now.
    private func jump(to point: CGPoint) {
        guard let layout, let j = layout.wordIndex(at: point) else { return }
        speech = layout
        shift = 0
        outOfSync = false
        current = j
        if speaker.isPaused { speaker.togglePause() }
        speaker.speak(layout, from: j)
        setPhase(.reading)
        updateHighlight()
    }

    // MARK: Following the page

    private func tick() {
        guard let overlay else { return }
        if phase == .reading { listened += 0.1 }
        // Holding ⌥ makes the overlay clickable for click-to-jump; otherwise clicks pass through.
        let wantsClicks = NSEvent.modifierFlags.contains(.option) && !NSEvent.modifierFlags.contains(.command)
        if overlay.ignoresMouseEvents == wantsClicks { overlay.ignoresMouseEvents = !wantsClicks }

        ticks += 1
        guard ticks % 3 == 0, case let .window(id) = target else { return }
        guard let now = Capture.frame(of: id) else { return stop() }
        guard now != frame else { return }
        let resized = abs(now.width - frame.width) > 1 || abs(now.height - frame.height) > 1
        frame = now
        overlay.place(now)
        if resized {
            // Text reflows on resize; hide rather than draw in the wrong place.
            outOfSync = true
            updateHighlight()
            scheduleResync()
        }
    }

    private func scrolled() {
        guard let overlay, overlay.frame.contains(NSEvent.mouseLocation) else { return }
        outOfSync = true
        updateHighlight()
        scheduleResync()
    }

    private func scheduleResync() {
        resyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.resync() }
        resyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func resync() {
        guard let target, let overlay else { return }
        let id = session
        switch target {
        case let .window(window): Capture.image(of: window) { [weak self] in self?.resynced($0, session: id) }
        case .region:
            let excluded = [CGWindowID(overlay.windowNumber)] + excludedWindows()
            Capture.image(of: frame, excluding: excluded) { [weak self] in self?.resynced($0, session: id) }
        }
    }

    private func resynced(_ image: CGImage?, session id: Int) {
        guard let image, session == id else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let doc = try? OCR.doc(from: image)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == id, let doc, let speech = self.speech else { return }
                self.layout = doc
                if let s = Align.shift(from: speech, at: self.current, to: doc) {
                    self.shift = s
                    self.outOfSync = false
                } else {
                    // Spoken text scrolled out of view; ⌥-click to continue from what's visible.
                    self.outOfSync = true
                }
                self.updateHighlight()
            }
        }
    }

    // MARK: Permission

    private func ensurePermission() -> Bool {
        if Capture.hasPermission { return true }
        onNeedsPermission?()
        return false
    }
}

enum Permission {
    static func request() {
        Capture.requestPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
