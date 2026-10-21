import AppKit
import AVFoundation
import ImageIO
import YapYapCore

// `YapYap --ocr image.png` prints the text in reading order: handy for checking
// OCR and layout against a corpus of screenshots without any permissions.
let args = CommandLine.arguments
if args.count == 3, args[1] == "--ocr" {
    let url = URL(fileURLWithPath: args[2]) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        FileHandle.standardError.write("Can't read \(args[2])\n".data(using: .utf8)!)
        exit(1)
    }
    let started = Date()
    let doc = try OCR.doc(from: image)
    print(doc.text)
    FileHandle.standardError.write(String(format: "\n[%d words, %.0f ms]\n", doc.words.count, Date().timeIntervalSince(started) * 1000).data(using: .utf8)!)
    exit(0)
}

// `YapYap --boxes in.png out.png` draws the word boxes the highlight will use.
if args.count == 4, args[1] == "--boxes" {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
    let doc = try OCR.doc(from: image)
    let size = NSSize(width: image.width, height: image.height)
    let out = NSImage(size: size)
    out.lockFocus()
    NSImage(cgImage: image, size: size).draw(at: .zero, from: .zero, operation: .copy, fraction: 1)
    for (i, w) in doc.words.enumerated() {
        (i % 2 == 0 ? NSColor.systemRed : NSColor.systemBlue).withAlphaComponent(0.3).setFill()
        NSRect(x: w.rect.minX * size.width, y: w.rect.minY * size.height, width: w.rect.width * size.width, height: w.rect.height * size.height).fill(using: .sourceOver)
    }
    out.unlockFocus()
    try NSBitmapImageRep(data: out.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
    exit(0)
}

// `YapYap --kokoro "text"` synthesizes with the chosen Kokoro voice and prints word timings.
if args.count == 3, args[1] == "--kokoro" {
    let doc = Doc(blocks: [[OCRLine(text: args[2], rect: .zero, words: args[2].split(separator: " ").map { OCRWord(text: String($0), rect: .zero) })]])
    let speaker = KokoroSpeaker()
    let started = Date()
    speaker.onWord = { i in print(String(format: "%6.2fs  %@", Date().timeIntervalSince(started), doc.words[i].text)) }
    speaker.onFinish = { exit(0) }
    if Settings.shared.voiceID.flatMap(KokoroSpeaker.voiceName) == nil { Settings.shared.voiceID = KokoroSpeaker.id(for: "af_heart") }
    speaker.speak(doc, from: 0)
    RunLoop.main.run()
}

// `YapYap --polish "text"` runs dictation's cleanup on the text: filler filter, then Apple Intelligence.
if args.count == 3, args[1] == "--polish" {
    let said = args[2]
    let filtered = Fillers.strip(said)
    print("said:     \(said)")
    print("filtered: \(filtered)")
    guard #available(macOS 26, *), AppleIntelligence.isAvailable else {
        print("Apple Intelligence: \(AppleIntelligence.status ?? "unavailable")")
        exit(0)
    }
    let polisher = Polisher()
    let started = Date()
    polisher.prepare()
    // READALONG_TALK=3: wait as if talking for 3 s between pressing the shortcut and letting go.
    Thread.sleep(forTimeInterval: Double(ProcessInfo.processInfo.environment["READALONG_TALK"] ?? "0") ?? 0)
    let released = Date()
    polisher.polish(filtered) { polished in
        let started = released
        let seconds = Date().timeIntervalSince(started)
        if let polished {
            print(String(format: "polished: %@\n[%.2f s, %@]", polished, seconds, Fillers.isFaithful(polished, to: said) ? "faithful" : "REJECTED: would type the filtered text"))
        } else {
            print(String(format: "polished: (none after %.2f s: would type the filtered text)", seconds))
        }
        exit(0)
    }
    RunLoop.main.run()
}

// `YapYap --kokoro-memory "text"` reads with Kokoro, then prints the memory footprint while
// loaded and after the idle unload (shortened to 3 s), to check the model is really released.
if args.count == 3, args[1] == "--kokoro-memory" {
    func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
        return Int(info.phys_footprint) / 1_048_576
    }
    let doc = Doc(blocks: [[OCRLine(text: args[2], rect: .zero, words: args[2].split(separator: " ").map { OCRWord(text: String($0), rect: .zero) })]])
    if Settings.shared.voiceID.flatMap(KokoroSpeaker.voiceName) == nil { Settings.shared.voiceID = KokoroSpeaker.id(for: "af_heart") }
    print("start: \(footprintMB()) MB")
    KokoroSpeaker.idleUnload = 3
    let speaker = KokoroSpeaker()
    let started = Date()
    var first = true
    speaker.onWord = { _ in
        if first { first = false; print(String(format: "first word after %.2f s", Date().timeIntervalSince(started))) }
    }
    speaker.onFinish = {
        print("after reading (model loaded): \(footprintMB()) MB")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            print("after idle unload: \(footprintMB()) MB")
            exit(0)
        }
    }
    speaker.speak(doc, from: 0)
    RunLoop.main.run()
}

// `YapYap --vo segments.json outdir [voice]`: each {"id", "text", "speed"?} → outdir/<id>.wav, and outdir/words.json
// with every word's start time, from the same Kokoro pipeline the app reads with. For the product film.
if args.count >= 4, args[1] == "--vo" {
    struct Segment: Decodable { let id: String; let text: String; let speed: Float? }
    let segments = try JSONDecoder().decode([Segment].self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
    let out = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let voice = args.count > 4 ? args[4] : "af_heart"
    var result: [String: Any] = [:]
    for seg in segments {
        let words = seg.text.split(separator: " ").map { OCRWord(text: String($0), rect: .zero) }
        let doc = Doc(blocks: [[OCRLine(text: seg.text, rect: .zero, words: words)]])
        guard let (samples, starts) = KokoroSpeaker.render(doc, voiceName: voice, speed: seg.speed ?? 1) else {
            FileHandle.standardError.write("Kokoro failed on \(seg.id)\n".data(using: .utf8)!)
            exit(1)
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: out.appendingPathComponent("\(seg.id).wav"), settings: format.settings)
        try file.write(from: buffer)
        result[seg.id] = [
            "dur": Double(samples.count) / 24000,
            "words": starts.map { ["i": $0.index, "w": doc.words[$0.index].text, "t": ($0.start * 1000).rounded() / 1000] },
        ]
        print("\(seg.id): \(String(format: "%.2f", Double(samples.count) / 24000)) s, \(starts.count)/\(doc.words.count) words timed")
    }
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("words.json"))
    exit(0)
}

// `YapYap --transcribe speech.wav` streams the file through dictation as if spoken and prints the text.
// `YapYap --transcribe talk.wav "Name One,Name Two"` also gives those words as screen context.
// `--transcribe-parakeet` does the same with Parakeet (YAPYAP_PARAKEET_MODEL picks which), loading it
// first, and reports YapYap's memory.
if (3...4).contains(args.count), args[1] == "--transcribe" || args[1] == "--transcribe-parakeet" {
    let source = try FileAudioSource(url: URL(fileURLWithPath: args[2]))
    let transcriber: Transcriber
    if args[1] == "--transcribe-parakeet" {
        let loading = Date()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { try await ParakeetEngine.shared.load() } catch {
                FileHandle.standardError.write("Failed to load Parakeet: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
            semaphore.signal()
        }
        semaphore.wait()
        FileHandle.standardError.write(String(format: "[Parakeet %@ loaded in %.1f s, %.0f MB]\n", "\(ParakeetEngine.version)", Date().timeIntervalSince(loading), Diagnostics.memoryMB()).data(using: .utf8)!)
        transcriber = ParakeetTranscriber(source: source)
    } else if #available(macOS 26, *) {
        transcriber = AnalyzerTranscriber(source: source)
    } else {
        FileHandle.standardError.write("--transcribe needs macOS 26\n".data(using: .utf8)!)
        exit(1)
    }
    if args.count == 4 { transcriber.setContext(args[3].split(separator: ",").map(String.init)) }
    let started = Date()
    transcriber.onText = { FileHandle.standardError.write(String(format: "%6.2fs  %@\n", Date().timeIntervalSince(started), $0).data(using: .utf8)!) }
    transcriber.start { error in
        if let error {
            FileHandle.standardError.write("Failed: \((error as? DictationError)?.message ?? "\(error)")\n".data(using: .utf8)!)
            exit(1)
        }
        // Let go once the file has played, like releasing the shortcut.
        let seconds = (try? AVAudioFile(forReading: URL(fileURLWithPath: args[2]))).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 0.3) {
            let released = Date()
            transcriber.finish { text in
                print(text)
                FileHandle.standardError.write(String(format: "[final text %.0f ms after release; YapYap memory now %.0f MB, peak %.0f MB]\n", Date().timeIntervalSince(released) * 1000, Diagnostics.memoryMB(), Diagnostics.peakMemoryMB()).data(using: .utf8)!)
                exit(0)
            }
        }
    }
    RunLoop.main.run()
}

// `YapYap --permissions` prints what's allowed, as this app bundle sees it (launch with `open --stdout`).
if args.count == 2, args[1] == "--permissions" {
    print("screen=\(Capture.hasPermission) needsRestart=\(Capture.needsRestart) mic=\(DictationAccess.microphone) accessibility=\(DictationAccess.accessibility)")
    exit(0)
}

// `YapYap --focus` prints, every second for 10 s, what has keyboard focus as Accessibility reports
// it and whether dictation would paste there (launch with `open --stdout`; click around meanwhile).
if args.count == 2, args[1] == "--focus" {
    for _ in 0..<10 {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("\(app): \(Paster.describeFocus()) → \(Paster.focusIsClearlyNotText() ? "copy instead" : "paste")")
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

// `YapYap --screen-terms` waits 3 s, then prints the names dictation would favour from the
// front window (launch with `open --stdout` and switch to the app to test).
if args.count == 2, args[1] == "--screen-terms" {
    _ = NSApplication.shared
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        let app = NSWorkspace.shared.frontmostApplication
        print("front app: \(app?.localizedName ?? "?"), window: \(app.flatMap { Capture.frontWindow(of: $0.processIdentifier) }.map { "\($0.id)" } ?? "none"), screen access: \(Capture.hasPermission)")
        let started = Date()
        ScreenContext.terms(in: app) { terms in
            print("terms (\(terms.count)) in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(terms.joined(separator: ", "))")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { print("no terms after 5 s"); exit(1) }
    }
    NSApplication.shared.run()
}

// `YapYap --dictate-test speech.wav` runs real hands-free dictation on the file (instead of the
// mic) into whatever app is in front, then reports what the dictation panel did. Launch with
// `open -g --stdout` so the app in front stays in front.
if args.count == 3, args[1] == "--dictate-test" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Demo.dictationAudio = URL(fileURLWithPath: args[2])
    let model = AppModel.shared
    let seconds = (try? AVAudioFile(forReading: URL(fileURLWithPath: args[2]))).map { Double($0.length) / $0.processingFormat.sampleRate } ?? 3
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        print("front: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") — \(Paster.describeFocus()) → \(Paster.focusIsClearlyNotText() ? "card" : "paste")")
        model.startDictation(handsFree: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1.5) {
            print("finishing: \(model.dictationBarState)")
            model.finishDictation()
            for t in [0.5, 1.5, 3.0, 6.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) { print(String(format: "+%.1fs: ", t) + model.dictationBarState) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { print("text: \(model.leftover ?? model.lastDictation ?? "-")"); exit(0) }
        }
    }
    app.run()
}

// `YapYap --keychain-test` saves, reads back and deletes a made-up saved item, away from the real list.
if args.count == 2, args[1] == "--keychain-test" {
    let storage = KeychainStorage(service: "cc.yapyap.app.saved-text.test")
    let items = [SavedItem(name: "Test key", value: "sk_test_\(UUID().uuidString)", secret: true)]
    storage.save(items)
    let first = storage.load() == items
    var changed = items
    changed[0].value = "changed"
    storage.save(changed)
    let second = storage.load() == changed
    storage.delete()
    print("saved and read back: \(first), updated: \(second), deleted: \(storage.load().isEmpty)")
    exit(first && second ? 0 : 1)
}

// `YapYap --saved-match "email address"` lists the saved names (never the values) and what the phrase matches.
if args.count == 3, args[1] == "--saved-match" {
    for item in SavedText.shared.items {
        print("saved: \(String(reflecting: item.name)) value \(item.value.count) characters\(item.secret ? ", secret" : "")")
    }
    print("\(String(reflecting: args[2])) → \(SavedText.shared.match(args[2]).map(\.name) ?? "no match")")
    print("after fillers: \(String(reflecting: Fillers.strip(args[2])))")
    exit(0)
}

// `YapYap --engine-test` shows which speech model dictation would use now and once Parakeet is ready.
if args.count == 2, args[1] == "--engine-test" {
    let started = Date()
    func report(_ when: String) {
        let engine = Dictation.systemTranscriber() is ParakeetTranscriber ? "parakeet" : "apple"
        print(String(format: "%@ (%.1f s): %@", when, Date().timeIntervalSince(started), engine))
    }
    print("setting: \(Settings.shared.dictationEngine.rawValue)")
    MainActor.assumeIsolated {
        ParakeetEngine.prepare()
        report("at launch")
    }
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        MainActor.assumeIsolated {
            if ParakeetEngine.isReady || Date().timeIntervalSince(started) > 120 {
                report("ready")
                exit(0)
            }
        }
    }
    RunLoop.main.run()
}

// `YapYap --demo outdir speech.wav` records the product film's take (see Demo.swift).
if args.count == 4, args[1] == "--demo" {
    MainActor.assumeIsolated { Demo.run(out: URL(fileURLWithPath: args[2]), speech: URL(fileURLWithPath: args[3])) }
}

// `YapYap --snapshots dir --sample` uses made-up history and name instead of yours (for the README).
if args.count >= 3, args[1] == "--snapshots" {
    Snapshots.run(into: URL(fileURLWithPath: args[2]), sample: args.contains("--sample"))
    exit(0)
}

YapYapApp.main()
