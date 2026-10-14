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
if args.count == 3, args[1] == "--transcribe" {
    guard #available(macOS 26, *) else {
        FileHandle.standardError.write("--transcribe needs macOS 26\n".data(using: .utf8)!)
        exit(1)
    }
    let source = try FileAudioSource(url: URL(fileURLWithPath: args[2]))
    let transcriber = AnalyzerTranscriber(source: source)
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
                FileHandle.standardError.write(String(format: "[final text %.0f ms after release]\n", Date().timeIntervalSince(released) * 1000).data(using: .utf8)!)
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
