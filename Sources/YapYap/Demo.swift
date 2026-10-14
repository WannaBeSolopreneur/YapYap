import AppKit
import AVFoundation
import Carbon
import ScreenCaptureKit
import SwiftUI

/// `YapYap --demo <outdir> <speech.wav>` records the product film's take: a team-chat window
/// with a long message, read with the real Read Region (⌥A, a mouse drag, ⌥⌘= up to 2×), then a
/// reply dictated with the real dictation (⌥S held while `speech.wav` plays into the recognizer
/// instead of the microphone), tidied, pasted and sent. Every step is a real key press or mouse
/// event posted to the system, so the app responds exactly as it does to a person. Writes
/// `take.mov` (screen and app audio) and `events.json` (when each step happened, and where the
/// window was) for the edit.
enum Demo {
    /// While recording, our panels show up in screen captures (normally they're kept out, so
    /// reading never sees its own highlight; the app excludes them by window instead).
    static var capturable = false
    static var sharing: NSWindow.SharingType { capturable ? .readOnly : .none }
    /// Dictation listens to this file instead of the microphone.
    static var dictationAudio: URL?
    /// Called when that file starts playing into the recognizer.
    static var onDictationAudio: (() -> Void)?

    @MainActor static func run(out: URL, speech: URL) {
        capturable = true
        dictationAudio = speech
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.mainMenu = editMenu()
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let take = DemoTake(out: out, speech: speech)
        Task { @MainActor in await take.run() }
        NSApp.run()
    }

    /// ⌘V needs a Paste menu item to land in a text field.
    private static func editMenu() -> NSMenu {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        return main
    }
}

// MARK: The take

@MainActor
private final class DemoTake {
    let out: URL
    let speech: URL
    let chat = ChatState()
    let sheet = SheetState()
    let mail = MailState()
    let recorder = ScreenRecorder()
    var events: [[String: Any]] = []
    var window: NSWindow?
    var chatFrame: NSRect?
    var backdrop: NSWindow?
    var others: [NSWindow] = []
    var windows: [String: NSWindow] = [:]

    init(out: URL, speech: URL) {
        self.out = out
        self.speech = speech
    }

    func run() async {
        let model = AppModel.shared
        let settings = Settings.shared
        let saved = (speed: settings.speed, style: settings.style, ruler: settings.ruler, voice: settings.voiceID)
        settings.speed = 1
        settings.style = .yellow
        settings.ruler = false
        if KokoroSpeaker.isInstalled { settings.voiceID = KokoroSpeaker.id(for: "af_heart") }
        defer {
            settings.speed = saved.speed
            settings.style = saved.style
            settings.ruler = saved.ruler
            settings.voiceID = saved.voice
        }

        guard CGPreflightPostEventAccess(), Capture.hasPermission, model.dictationAllowed else {
            print("needs Accessibility, Screen Recording and dictation permissions")
            exit(1)
        }
        // Takes don't go into the history or the totals.
        model.controller.onReadFinished = nil
        model.dictation.onTyped = nil
        model.registerHotKeys()
        Demo.onDictationAudio = { [weak self] in self?.mark("dictation-audio") }
        Input.clock = { [weak self] in self?.recorder.elapsed ?? 0 }
        showWindows()
        // Load the voice now, so the read starts as soon as the drag ends (heard before recording).
        model.controller.preview("Ready.")
        await pause(4.0)
        model.controller.stop()
        await pause(0.5)
        // He's busy in the spreadsheet.
        let rest = CGPoint(x: 520, y: 330)
        Input.move(to: rest)
        chat.arrived = true

        do {
            try await recorder.start(to: out.appendingPathComponent("take.mov"))
        } catch {
            print("recording failed: \(error)")
            exit(1)
        }
        mark("start")
        // He's opening Marcus's email when Brenda's message pops in.
        await click(mail.frames["row0"], in: windows["Inbox"], glide: 0.45)
        mark("mail-open")
        await pause(0.5)

        // Brenda's message arrives: the chat pops in, in the corner.
        popIn()
        mark("message")
        await pause(3.0)

        // ⌥A, then drag over the message.
        guard let body = chat.bodyFrame else { return fail("message not laid out") }
        let from = screenPoint(in: CGPoint(x: body.minX - 10, y: body.minY - 8))
        let to = screenPoint(in: CGPoint(x: body.maxX + 14, y: body.maxY + 8))
        await Input.glide(from: rest, to: from, seconds: 0.75)
        Input.press(kVK_ANSI_A, flags: .maskAlternate)
        mark("read-key")
        await pause(0.45)
        Input.mouse(.leftMouseDown, at: from)
        mark("drag")
        await Input.glide(from: from, to: to, seconds: 0.9, dragging: true)
        await pause(0.08)
        Input.mouse(.leftMouseUp, at: to)
        mark("drag-end")
        await Input.glide(from: to, to: screenPoint(in: CGPoint(x: body.maxX + 60, y: body.maxY + 60)), seconds: 0.4)

        // Reading. A couple of seconds in, ⌥⌘= four times: 1× → 2×.
        guard await wait(timeout: 20, { model.phase == .reading }) else { return fail("reading never started") }
        mark("reading")
        // Back to the spreadsheet while she's read: the missing West / September number.
        await pause(0.4)
        await fillCell(row: 4, column: 3, typing: "171880")
        mark("sheet-1")
        await pause(0.5)
        for _ in 0..<4 {
            Input.press(kVK_ANSI_Equal, flags: [.maskAlternate, .maskCommand])
            mark("faster")
            await pause(0.12)
        }
        // Still working at 2×: the note, then the reply to Marcus.
        await pause(0.7)
        await fillCell(row: 9, column: 1, typing: "West Sept added")
        mark("sheet-2")
        await pause(0.3)
        await click(mail.frames["reply"], in: windows["Inbox"], glide: 0.45)
        mark("mail-reply")
        await pause(0.25)
        await click(mail.frames["field"], in: windows["Inbox"], glide: 0.2, times: 1)
        await type("West Sept is in and the totals match now. Sheet attached.", fast: true)
        await pause(0.25)
        await click(mail.frames["send"], in: windows["Inbox"], glide: 0.35)
        mark("mail-sent")
        guard await wait(timeout: 40, { model.phase == .idle }) else { return fail("reading never ended") }
        mark("read-end")
        await pause(0.6)

        // Click into the reply box, hold ⌥S while he talks, let go.
        guard let field = chat.fieldFrame else { return fail("composer not laid out") }
        let box = screenPoint(in: CGPoint(x: field.minX + 160, y: field.midY))
        await Input.glide(from: Input.location, to: box, seconds: 0.55)
        Input.mouse(.leftMouseDown, at: box)
        await pause(0.06)
        Input.mouse(.leftMouseUp, at: box)
        mark("click-reply")
        await pause(0.7)
        Input.key(kVK_ANSI_S, down: true, flags: .maskAlternate)
        mark("dictate-key")
        guard await wait(timeout: 20, { self.marked("dictation-audio") }) else { return fail("dictation never listened") }
        await pause(audioSeconds(speech) + 0.5)
        Input.key(kVK_ANSI_S, down: false, flags: .maskAlternate)
        mark("dictate-release")
        guard await wait(timeout: 15, { !self.chat.draft.isEmpty && model.dictationPhase == .idle }) else {
            return fail("nothing was pasted")
        }
        mark("pasted")
        await pause(1.3)

        // Send.
        Input.press(kVK_Return, flags: [])
        mark("send")
        await pause(3.6)

        await recorder.stop()
        save()
        print("done: \(chat.sent ?? "(not sent)")")
        exit(0)
    }

    // MARK: Windows

    func showWindows() {
        let screen = NSScreen.main!
        let area = screen.visibleFrame

        let backdrop = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.level = .floating
        backdrop.contentView = NSHostingView(rootView: Backdrop())
        backdrop.collectionBehavior = [.canJoinAllSpaces, .stationary]
        backdrop.orderFrontRegardless()
        self.backdrop = backdrop

        // Other work, open behind: a spreadsheet, an inbox, a draft agenda (made up, like the chat).
        for (view, frame, title) in [
            (AnyView(DocApp()), CGRect(x: 950, y: 52, width: 900, height: 560), "Offsite agenda"),
            (AnyView(SheetApp().environment(sheet)), CGRect(x: 130, y: 52, width: 1000, height: 408), "Q3 Forecast"),
            (AnyView(MailApp().environment(mail)), CGRect(x: 150, y: 470, width: 880, height: 530), "Inbox"),
        ] {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = title
            w.isReleasedWhenClosed = false
            w.level = .floating
            // Fixed size: SwiftUI must not grow the window past where it's placed.
            let host = NSHostingView(rootView: view)
            host.sizingOptions = []
            w.contentView = host
            w.setFrame(appKitFrame(frame), display: true)
            w.orderFrontRegardless()
            // Placed again once on screen: the system may have moved it while ordering it in.
            w.setFrame(appKitFrame(frame), display: true)
            others.append(w)
            windows[title] = w
        }

        // The chat, in the bottom-right corner; it pops in when Brenda's message arrives.
        let size = NSSize(width: 870, height: 620)
        let origin = NSPoint(x: area.maxX - size.width - 60, y: area.minY + 82)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.contentView = NSHostingView(rootView: ChatView().environment(chat))
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        window.alphaValue = 0
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        chatFrame = window.frame
    }

    /// Springs the chat window in from its corner.
    func popIn() {
        guard let window, let final = chatFrame else { return }
        let start = NSRect(x: final.maxX - final.width * 0.9, y: final.minY, width: final.width * 0.9, height: final.height * 0.9)
        window.setFrame(start, display: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.25, 0.4, 1)
            window.animator().setFrame(final, display: true)
            window.animator().alphaValue = 1
        }
    }

    /// Global CoreGraphics (top-left) → AppKit (bottom-left) frame.
    func appKitFrame(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: Screen.primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A point in the chat window's content (top-left origin) → global CoreGraphics coordinates.
    func screenPoint(in p: CGPoint) -> CGPoint {
        guard let window else { return p }
        return screenPoint(in: p, of: window)
    }

    /// SwiftUI's global frames start at the top of the window, title bar included.
    func screenPoint(in p: CGPoint, of window: NSWindow) -> CGPoint {
        CGPoint(x: window.frame.minX + p.x, y: Screen.primaryHeight - window.frame.maxY + p.y)
    }

    /// Clicks a spreadsheet cell, types into it like a person, presses Return.
    func fillCell(row: Int, column: Int, typing text: String) async {
        // Double-click to edit, like a spreadsheet: the second click lands in the field and focuses it.
        await click(sheet.frames[SheetState.key(row, column)], in: windows["Q3 Forecast"], glide: 0.5, times: 2)
        await pause(0.1)
        await type(text)
        await pause(0.2)
        Input.press(kVK_Return, flags: [])
    }

    /// Glides to the middle of `frame` (in the window's content) and clicks. The first click on a
    /// window in the background only brings it forward, so then it clicks again, like a person.
    func click(_ frame: CGRect?, in window: NSWindow?, glide: Double, times: Int? = nil, _ name: String = #function) async {
        guard let frame, let window else { return print("nothing to click: \(name) \(frame == nil ? "no frame" : "no window")") }
        let target = screenPoint(in: CGPoint(x: frame.midX, y: frame.midY), of: window)
        await Input.glide(from: Input.location, to: target, seconds: glide)
        for _ in 0..<(times ?? (window.isKeyWindow ? 1 : 2)) {
            Input.mouse(.leftMouseDown, at: target)
            await pause(0.05)
            Input.mouse(.leftMouseUp, at: target)
            await pause(0.22)
        }
    }

    func type(_ text: String, fast: Bool = false) async {
        for ch in text {
            guard let (code, shift) = Input.keyCode(for: ch) else { continue }
            Input.press(code, flags: shift ? .maskShift : [])
            await pause(ch == " " ? (fast ? 0.09 : 0.12) : (fast ? 0.058 : 0.085))
        }
    }

    // MARK: Timing

    func mark(_ name: String) {
        events.append(["name": name, "t": recorder.elapsed])
    }

    func marked(_ name: String) -> Bool {
        events.contains { $0["name"] as? String == name }
    }

    func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func wait(timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            await pause(0.02)
        }
        return false
    }

    func audioSeconds(_ url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func fail(_ why: String) {
        print("take failed: \(why)")
        Task {
            await recorder.stop()
            save()
            exit(1)
        }
    }

    func save() {
        let f = window?.frame ?? .zero
        let screen = NSScreen.main!
        let info: [String: Any] = [
            "events": events,
            // Global CoreGraphics points.
            "window": [f.minX, Screen.primaryHeight - f.maxY, f.width, f.height],
            "screen": [screen.frame.width, screen.frame.height],
            "visible": [screen.visibleFrame.minX, Screen.primaryHeight - screen.visibleFrame.maxY,
                        screen.visibleFrame.width, screen.visibleFrame.height],
            "scale": screen.backingScaleFactor,
            "message": chat.bodyFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
            "composer": chat.fieldFrame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? [],
            "pasted": chat.sent ?? chat.draft,
            "others": windows.mapValues { w in [w.frame.minX, Screen.primaryHeight - w.frame.maxY, w.frame.width, w.frame.height] },
            "note": sheet.rows[9][1],
            "trail": Input.trail,
            "mailSent": mail.sent,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: out.appendingPathComponent("events.json"))
        }
    }
}

private enum Screen {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
}

// MARK: Input, posted like a person's

@MainActor
private enum Input {
    static let source = CGEventSource(stateID: .hidSystemState)
    private(set) static var location = CGPoint.zero
    /// Every pointer move, click and key press: [t, x, y, kind], for the edit's camera.
    static var trail: [[Any]] = []
    static var clock: () -> Double = { 0 }

    private static func log(_ kind: String) {
        trail.append([(clock() * 1000).rounded() / 1000, location.x, location.y, kind])
    }

    static func key(_ code: Int, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        if down { log("key") }
    }

    /// The US-layout key for a character, and whether it needs Shift.
    static func keyCode(for ch: Character) -> (Int, Bool)? {
        let letters: [Character: Int] = ["a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
            "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S,
            "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6,
            "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9, " ": kVK_Space, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period]
        if let code = letters[ch] { return (code, false) }
        if ch.isUppercase, let code = letters[Character(ch.lowercased())] { return (code, true) }
        return nil
    }

    static func press(_ code: Int, flags: CGEventFlags) {
        key(code, down: true, flags: flags)
        key(code, down: false, flags: flags)
    }

    static func mouse(_ type: CGEventType, at p: CGPoint) {
        location = p
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        log(type == .leftMouseDown ? "down" : type == .leftMouseUp ? "up" : type == .leftMouseDragged ? "drag" : "move")
    }

    static func move(to p: CGPoint) {
        mouse(.mouseMoved, at: p)
    }

    /// Moves the pointer along an eased path, like a hand.
    static func glide(from a: CGPoint, to b: CGPoint, seconds: Double, dragging: Bool = false) async {
        let steps = max(2, Int(seconds * 120))
        for i in 1...steps {
            let x = Double(i) / Double(steps)
            let e = x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
            let p = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            mouse(dragging ? .leftMouseDragged : .mouseMoved, at: p)
            try? await Task.sleep(for: .seconds(seconds / Double(steps)))
        }
    }
}

// MARK: Recording

/// Records the main display, with the app's own audio, to a movie file.
private final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var finished: CheckedContinuation<Void, Never>?
    private var started: Date?

    /// Seconds since the recording started.
    var elapsed: Double { started.map { Date().timeIntervalSince($0) } ?? 0 }

    func start(to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw DictationError.unavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = false
        config.sampleRate = 48000
        config.channelCount = 2
        config.queueDepth = 8

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        let queue = DispatchQueue(label: "demo.capture")
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .hevc
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        // Wait for the file to really start, so event times line up with the movie.
        for _ in 0..<300 where started == nil { try? await Task.sleep(for: .milliseconds(10)) }
        if started == nil { started = Date() }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            Task {
                try? await stream.stopCapture()
                // Don't hang if the delegate never reports.
                try? await Task.sleep(for: .seconds(5))
                self.finish()
            }
        }
    }

    private func finish() {
        let c = finished
        finished = nil
        c?.resume()
    }

    func recordingOutputDidStartRecording(_ output: SCRecordingOutput) {
        if started == nil { started = Date() }
    }

    func recordingOutputDidFinishRecording(_ output: SCRecordingOutput) {
        DispatchQueue.main.async { self.finish() }
    }

    func recordingOutput(_ output: SCRecordingOutput, didFailWithError error: Error) {
        print("recording error: \(error)")
        DispatchQueue.main.async { self.finish() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {}
}

// MARK: The chat app (a made-up workspace, people and messages)

@Observable
private final class ChatState {
    var arrived = false
    var draft = ""
    var sent: String?
    /// In the window's content, top-left origin.
    var bodyFrame: CGRect?
    var fieldFrame: CGRect?
}

private enum Palette {
    static let sidebar = Color(red: 0.13, green: 0.16, blue: 0.20)
    static let sidebarText = Color.white.opacity(0.68)
    static let selected = Color(red: 0.23, green: 0.42, blue: 0.85)
    static let badge = Color(red: 0.89, green: 0.27, blue: 0.27)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let muted = Color(red: 0.45, green: 0.46, blue: 0.5)
    static let brenda = Color(red: 0.85, green: 0.45, blue: 0.3)
    static let sam = Color(red: 0.3, green: 0.55, blue: 0.75)
}

private struct ChatView: View {
    @Environment(ChatState.self) private var chat

    var body: some View {
        HStack(spacing: 0) {
            ChatSidebar()
                .frame(width: 200)
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        DayDivider(title: "Yesterday")
                        MessageRow(name: "Brenda Kowalski", initials: "BK", color: Palette.brenda, time: "4:58 PM",
                                   text: "Did you get a chance to look at the offsite deck?")
                        MessageRow(name: nil, initials: "", color: .clear, time: "5:31 PM", text: "Bumping this 🙂")
                        DayDivider(title: "Today")
                        if chat.arrived {
                            MessageRow(name: "Brenda Kowalski", initials: "BK", color: Palette.brenda, time: "9:41 AM",
                                       text: Self.long, reportsFrame: true)
                        }
                        if let sent = chat.sent {
                            MessageRow(name: "Sam Reyes", initials: "SR", color: Palette.sam, time: "9:43 AM", text: sent)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                Composer()
            }
            .background(Color.white)
        }
        .foregroundStyle(Palette.ink)
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(initials: "BK", color: Palette.brenda, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("Brenda Kowalski").font(.system(size: 15, weight: .bold))
                Text("Operations · 9:42 AM local time").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Image(systemName: "phone").foregroundStyle(Palette.muted)
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 20)
        .frame(height: 64)
        .padding(.top, 6)
    }

    static let long = "Hi! Quick one before next week's offsite. Could you pull together the Q3 numbers and double check the venue booking? Also, leadership wants a five minute roadmap update, so if you could present that too, that would be amazing. Let me know by end of day! Thanks so much!!"
}

private struct ChatSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Fernway").font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 8)
            .padding(.top, 48)
            .padding(.bottom, 14)

            row("bubble.left.and.bubble.right", "Threads", badge: nil)
            row("at", "Mentions", badge: 6)
            section("Channels")
            row("number", "general", badge: 12, bold: true)
            row("number", "marketing", badge: 4, bold: true)
            row("number", "offsite-planning", badge: 7, bold: true)
            row("number", "random", badge: nil)
            section("Direct messages")
            person("Brenda Kowalski", Palette.brenda, selected: true)
            person("Marcus Lee", .purple, badge: 2)
            person("Priya Shah", .teal, badge: 1)
            person("Tom Becker", .green)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.sidebar)
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.5))
            .padding(.horizontal, 8)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    private func row(_ symbol: String, _ title: String, badge: Int?, bold: Bool = false) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 16)
            Text(title).font(.system(size: 13, weight: bold ? .semibold : .regular))
            Spacer()
            if let badge { Badge(count: badge) }
        }
        .foregroundStyle(bold ? .white : Palette.sidebarText)
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func person(_ name: String, _ color: Color, selected: Bool = false, badge: Int? = nil) -> some View {
        HStack(spacing: 9) {
            Avatar(initials: String(name.split(separator: " ").compactMap(\.first)), color: color, size: 18)
            Text(name).font(.system(size: 13, weight: badge != nil || selected ? .semibold : .regular))
            Spacer()
            if let badge { Badge(count: badge) }
        }
        .foregroundStyle(selected || badge != nil ? .white : Palette.sidebarText)
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(selected ? Palette.selected : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct Badge: View {
    let count: Int
    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(Palette.badge, in: Capsule())
    }
}

private struct Avatar: View {
    let initials: String
    let color: Color
    let size: CGFloat
    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

private struct DayDivider: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, 10)
                .frame(height: 22)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.1)))
            Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct MessageRow: View {
    @Environment(ChatState.self) private var chat
    let name: String?
    let initials: String
    let color: Color
    let time: String
    let text: String
    var reportsFrame = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if name != nil {
                Avatar(initials: initials, color: color, size: 36)
            } else {
                Color.clear.frame(width: 36, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let name {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(name).font(.system(size: 15, weight: .bold))
                        Text(time).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                }
                Text(text)
                    .font(.system(size: 17))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        if reportsFrame { chat.bodyFrame = frame }
                    }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, name == nil ? 2 : 7)
    }
}

private struct Composer: View {
    @Environment(ChatState.self) private var chat
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = chat
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message Brenda Kowalski", text: $chat.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .lineLimit(1...4)
                .focused($focused)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { chat.fieldFrame = $0 }
                .onKeyPress(.return) {
                    send()
                    return .handled
                }
            HStack(spacing: 14) {
                Image(systemName: "plus.circle")
                Image(systemName: "textformat")
                Image(systemName: "face.smiling")
                Image(systemName: "at")
                Spacer()
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(chat.draft.isEmpty ? Palette.muted.opacity(0.5) : Palette.selected)
            }
            .font(.system(size: 14))
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? Color.black.opacity(0.35) : Color.black.opacity(0.15)))
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .padding(.top, 4)
    }

    private func send() {
        let text = chat.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.spring(duration: 0.4, bounce: 0.2)) {
            chat.sent = text
            chat.draft = ""
        }
    }
}

/// A calm desktop behind the take, instead of whatever is on the real one.
private struct Backdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.80, green: 0.86, blue: 0.95), Color(red: 0.95, green: 0.90, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: Other work on the desktop (made up: no real apps, people or numbers)

/// What's in the spreadsheet, and which cell is being typed into.
@Observable
private final class SheetState {
    static func key(_ row: Int, _ column: Int) -> String { "\(row),\(column)" }

    var rows: [[String]] = [
        ["Region", "July", "August", "September", "Q3 total", "vs plan"],
        ["North", "182,400", "176,950", "191,300", "550,650", "+4.2%"],
        ["South", "143,210", "151,880", "139,040", "434,130", "−1.8%"],
        ["East", "201,775", "198,300", "214,960", "615,035", "+6.9%"],
        ["West", "167,090", "159,420", "?", "#REF!", ""],
        ["Online", "96,500", "104,230", "118,700", "319,430", "+11.3%"],
        ["Partners", "58,300", "61,050", "57,980", "177,330", "−0.4%"],
        ["Total", "849,275", "851,830", "", "", ""],
        ["", "", "", "", "", ""],
        ["Notes", "West Sept missing, ask Marcus", "", "", "", ""],
    ]
    var editing: String?
    var draft = ""
    /// Cells that just changed, briefly lit.
    var flashing: Set<String> = []
    /// Each cell's frame in the window's content, top-left origin.
    var frames: [String: CGRect] = [:]

    func commit() {
        guard let editing else { return }
        let parts = editing.split(separator: ",").compactMap { Int($0) }
        let (row, column) = (parts[0], parts[1])
        var value = draft
        if let n = Int(draft) {
            value = n.formatted(.number.grouping(.automatic))
            // The row and the column add up again.
            if row == 4 && column == 3 {
                rows[4][4] = (167_090 + 159_420 + n).formatted()
                rows[4][5] = "+2.1%"
                rows[7][3] = (191_300 + 139_040 + 214_960 + n + 118_700 + 57_980).formatted()
                rows[7][4] = (550_650 + 434_130 + 615_035 + 167_090 + 159_420 + n + 319_430 + 177_330).formatted()
            }
        }
        rows[row][column] = value
        var changed: Set<String> = [editing]
        if row == 4 && column == 3 { changed.formUnion(["4,4", "4,5", "7,3", "7,4"]) }
        self.editing = nil
        draft = ""
        flashing = changed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.6)) { self.flashing.subtract(changed) }
        }
    }
}

/// A spreadsheet of Q3 numbers, mid-edit. Click a cell to type into it.
private struct SheetApp: View {
    @Environment(SheetState.self) private var sheet
    @FocusState private var focused: String?
    private static let columns = ["", "A", "B", "C", "D", "E", "F"]

    var body: some View {
        @Bindable var sheet = sheet
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("fx").italic().foregroundStyle(.secondary)
                Text(sheet.editing == nil ? "=SUM(B5:D5)" : sheet.draft).font(.system(size: 13, design: .monospaced))
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color(white: 0.97))
            Divider()
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Self.columns, id: \.self) { c in
                        Text(c).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: c.isEmpty ? 36 : 148, height: 24).background(Color(white: 0.94))
                            .border(Color.black.opacity(0.08), width: 0.5)
                    }
                }
                ForEach(Array(sheet.rows.enumerated()), id: \.offset) { i, row in
                    GridRow {
                        Text("\(i + 1)").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 36, height: 30).background(Color(white: 0.94))
                            .border(Color.black.opacity(0.08), width: 0.5)
                        ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
                            self.cell(i, j, cell)
                        }
                    }
                }
            }
            Spacer()
        }
        .background(Color.white)
        .foregroundStyle(Palette.ink)
    }

    @ViewBuilder
    private func cell(_ i: Int, _ j: Int, _ value: String) -> some View {
        @Bindable var sheet = sheet
        let key = SheetState.key(i, j)
        let editing = sheet.editing == key
        let missing = value == "?"
        Group {
            if editing {
                TextField("", text: $sheet.draft)
                    .textFieldStyle(.plain)
                    .focused($focused, equals: key)
                    .onSubmit { sheet.commit() }
                    .onAppear { focused = key }
            } else {
                Text(value)
                    .foregroundStyle(value == "#REF!" ? Color.red : value.hasPrefix("−") ? Color(red: 0.75, green: 0.2, blue: 0.2) : .primary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 13, weight: i == 0 || i == 7 ? .semibold : .regular))
        .frame(width: 136, height: 30, alignment: j == 0 || editing || i == 9 ? .leading : .trailing)
        .padding(.horizontal, 6)
        .background(sheet.flashing.contains(key) ? Color.green.opacity(0.28)
                    : missing ? Color.yellow.opacity(0.35) : i == 0 ? Color(red: 0.9, green: 0.95, blue: 0.9) : .white)
        .overlay(Rectangle().strokeBorder(editing ? Color.green : Color.black.opacity(0.08), lineWidth: editing ? 2 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            sheet.editing = key
            sheet.draft = ""
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { sheet.frames[key] = $0 }
    }
}

@Observable
private final class MailState {
    var open = false
    var replying = false
    var draft = ""
    var sent = false
    /// Clickable things, in the window's content, top-left origin.
    var frames: [String: CGRect] = [:]
}

/// An inbox that's getting away from him. Marcus's email can be opened, replied to and sent.
private struct MailApp: View {
    @Environment(MailState.self) private var mail
    @FocusState private var typing: Bool

    private static let list: [(from: String, subject: String, preview: String, time: String)] = [
        ("Marcus Lee", "Re: Q3 numbers", "Can you send me the latest before the 2pm? I still…", "9:38 AM"),
        ("IT Security", "Action required: training due Friday", "You have 3 incomplete modules…", "9:30 AM"),
        ("Expenses", "Your expense report is overdue", "Report #4471 is waiting for receipts…", "9:12 AM"),
        ("Priya Shah", "Offsite catering (3 attachments)", "Here are the three options…", "8:57 AM"),
        ("Calendar", "Invitation: Sync about the sync", "Thu 10:00–10:30 AM · Tom Becker", "8:40 AM"),
        ("Brenda Kowalski", "Fwd: Fwd: venue contract", "They need a signed copy by Monday…", "Yesterday"),
    ]

    var body: some View {
        @Bindable var mail = mail
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Inbox", systemImage: "tray").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                Label("Flagged", systemImage: "flag").font(.system(size: 13)).padding(.horizontal, 8).frame(height: 26)
                Label("Sent", systemImage: "paperplane").font(.system(size: 13)).padding(.horizontal, 8).frame(height: 26)
                Label("Drafts (4)", systemImage: "doc").font(.system(size: 13)).padding(.horizontal, 8).frame(height: 26)
                Spacer()
            }
            .padding(10)
            .frame(width: 130)
            .background(Color(white: 0.95))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Inbox").font(.system(size: 17, weight: .bold))
                    Text("\(mail.open ? 46 : 47) unread").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 40)
                Divider()
                ForEach(Array(Self.list.enumerated()), id: \.offset) { i, m in
                    let unread = !(i == 0 && mail.open) && i != 5
                    HStack(alignment: .top, spacing: 8) {
                        Group {
                            if i == 0 && mail.sent {
                                Image(systemName: "arrowshape.turn.up.left.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                            } else {
                                Circle().fill(unread ? Color.blue : .clear).frame(width: 8, height: 8)
                            }
                        }
                        .frame(width: 10).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.from).font(.system(size: 13, weight: unread ? .bold : .regular))
                                Spacer()
                                Text(m.time).font(.system(size: 11)).foregroundStyle(i == 0 && mail.open ? .white.opacity(0.8) : .secondary)
                            }
                            Text(m.subject).font(.system(size: 13, weight: unread ? .semibold : .regular)).lineLimit(1)
                            Text(m.preview).font(.system(size: 12)).lineLimit(1)
                                .foregroundStyle(i == 0 && mail.open ? .white.opacity(0.8) : .secondary)
                        }
                    }
                    .foregroundStyle(i == 0 && mail.open ? .white : Palette.ink)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(i == 0 && mail.open ? Color.accentColor : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { if i == 0 { mail.open = true } }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { if i == 0 { mail.frames["row0"] = $0 } }
                    Divider().padding(.leading, 28)
                }
                Spacer()
            }
            .frame(width: 300)
            Divider()
            reading
                .frame(width: 420)
                .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color.white)
        .foregroundStyle(Palette.ink)
    }

    @ViewBuilder
    private var reading: some View {
        @Bindable var mail = mail
        if !mail.open {
            Text("No Message Selected").font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Re: Q3 numbers").font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button { mail.replying = true } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left").font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mail.frames["reply"] = $0 }
                }
                Text("Marcus Lee · 9:38 AM").font(.system(size: 12)).foregroundStyle(.secondary)
                Divider()
                Text("Hey, can you send me the latest before the 2pm? I still don't have West for September, and finance is asking why the total doesn't match the deck.")
                    .font(.system(size: 14)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if mail.replying {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To: Marcus Lee").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("", text: $mail.draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .lineLimit(3...5)
                            .frame(minHeight: 54, alignment: .topLeading)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mail.frames["field"] = $0 }
                            .focused($typing)
                            .onAppear { typing = true }
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.spring(duration: 0.35)) {
                                    mail.sent = true
                                    mail.replying = false
                                }
                            } label: {
                                Label("Send", systemImage: "paperplane.fill").font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mail.frames["send"] = $0 }
                        }
                    }
                    .padding(12)
                    .background(Color(white: 0.97), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.5)))
                    .transition(.opacity)
                }
                if mail.sent {
                    Label("Reply sent", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                    Text(mail.draft).font(.system(size: 13)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(18)
        }
    }
}

/// A draft agenda with too many comments.
private struct DocApp: View {
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Offsite agenda — DRAFT v7").font(.system(size: 24, weight: .bold, design: .serif))
                Text("Day 1").font(.system(size: 15, weight: .semibold))
                Text("9:00  Welcome and coffee\n9:30  Year in review (Brenda)\n10:30  Q3 numbers (TBD)\n11:30  Team exercise: \"Blue sky, no limits\"\n12:30  Lunch (catering not confirmed)")
                    .font(.system(size: 14, design: .serif)).lineSpacing(5)
                Text("Day 2").font(.system(size: 15, weight: .semibold))
                Text("9:00  Roadmap update (who??)\n10:00  Breakouts\n11:00  Wrap-up and survey")
                    .font(.system(size: 14, design: .serif)).lineSpacing(5)
                Spacer()
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                comment("Brenda", "can we add a roadmap section?")
                comment("Tom", "is lunch included?")
                comment("Priya", "venue says 40 max, we are 46")
                comment("Brenda", "bumping this 🙂")
                Spacer()
            }
            .padding(14)
            .frame(width: 210)
            .background(Color(white: 0.97))
        }
        .background(Color.white)
        .foregroundStyle(Palette.ink)
    }

    private func comment(_ who: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(who).font(.system(size: 12, weight: .bold))
            Text(text).font(.system(size: 12))
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1, green: 0.96, blue: 0.8), in: RoundedRectangle(cornerRadius: 6))
    }
}
