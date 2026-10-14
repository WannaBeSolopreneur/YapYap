# YapYap

Mac app (Dock icon, main window, and menu-bar icon) that reads any window aloud and highlights each word on the original app, and types what you
dictate into any app. All on-device.
Built from `build-plan.html` (Phase 0 + most of Phase 1). Requires macOS 15+ and Xcode 16+ (built with Xcode 27).

## Build & run

    scripts/make-signing-cert.sh    # once: stable signature, so permissions survive rebuilds
    scripts/build-app.sh            # → build/YapYap.app
    scripts/build-app.sh --install  # copy to /Applications and launch
    TELEMETRYDECK_APP_ID=… scripts/build-app.sh  # send anonymous usage stats to your TelemetryDeck app (or put it in scripts/local.env)
    scripts/release.sh 1.0.0 [build]            # → build/YapYap-1.0.0.dmg, signed; add --notarize to send it to Apple

Builds use the hardened runtime (entitlements in `scripts/YapYap.entitlements`). With a "Developer ID Application"
certificate installed they're signed with it automatically; otherwise with the local certificate. Notarizing needs
credentials saved once: `xcrun notarytool store-credentials yapyap-notary --apple-id <id> --team-id <team>`.
    xcodebuild test -scheme YapYap -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
    build/YapYap.app/Contents/MacOS/YapYap --ocr screenshot.png   # print OCR text in reading order
    build/YapYap.app/Contents/MacOS/YapYap --kokoro "Some text." # speak with Kokoro, print word timings
    build/YapYap.app/Contents/MacOS/YapYap --transcribe talk.wav  # stream a file through dictation, print text (macOS 26+)
    build/YapYap.app/Contents/MacOS/YapYap --polish "um, so, uh, hi"  # dictation cleanup: filler filter + Apple Intelligence
    open --stdout /dev/stdout -a /Applications/YapYap.app --args --permissions  # what the installed app is allowed
    build/YapYap.app/Contents/MacOS/YapYap --snapshots shots/     # render every UI surface, light + dark

Use `xcodebuild`, not `swift build`/`swift test`: MLX needs its Metal shaders compiled, and SwiftPM's CLI
refuses KokoroSwift's dynamic-library setup.

On first launch grant **Screen Recording** (System Settings → Privacy & Security), then relaunch.

## Keys

| Key | Action |
|---|---|
| ⌥⌘R | Read the front window |
| ⌥A | Drag a region to read (changeable in Settings) |
| ⌥⌘P | Pause / resume |
| ⌥⌘= / ⌥⌘- | Faster / slower (0.5–2.5×) |
| Esc | Stop (only grabbed while reading) |
| ⌥ + click | Read from that word |
| Hold ⌥S | Dictate: speak, let go, and the text is typed into the front app (changeable in Settings) |

## UI (SwiftUI, Liquid Glass on macOS 26+, materials on 15; look shared with `site/` via `Theme`)

- **Main window** (`AppShell` in `MainWindow`): sidebar with the wordmark; **Home** (`HomePage`: greeting, "Press ⌥A. Listen." and "Hold ⌥S. Talk." panels like the website's
  totals, shortcuts, recent reads and dictations from `History`), **Reading**,
  **Dictation** and **Settings** pages (the forms in `SettingsView.swift`; ⌘, opens Settings), **Help** (Welcome).
- **History** (`History`): recent reads/dictations and totals in `~/Library/Application Support/YapYap/history.json`,
  this Mac only; "Keep history" off keeps totals only.
- **Menu-bar menu** (`StatusMenu`): native menu; reading controls while reading, Read Aloud, Open, Settings, Quit.
- **Reading bar** (`PlayerBar`) and **dictation capsule** (`DictationBar`): while in use.
- **Welcome** (`WelcomeView`, `--welcome` to reopen): demo loop (`Resources/welcome-demo.mp4`, 6 s from the
  site's demo) → three permissions → Try it (read the sample with ⌥A, dictate into the box with ⌥S).

`AppModel` is the observable state every view reads; `Controller` does capture → OCR → speech.

## How it works

`Capture` (SCScreenshotManager, one-shot) → `OCR` (Vision, word boxes) → `Layout` (XY-cut reading order,
paragraphs) → `Doc` (text + word rects + UTF-16 ranges) → `VoiceRouter` → `Speaker` (AVSpeechSynthesizer word callbacks) or `KokoroSpeaker`
(Kokoro-82M via [kokoro-ios](https://github.com/mlalma/kokoro-ios)/MLX, sentence chunks, per-token timestamps) →
`OverlayPanel` (click-through, `sharingType = .none`). Window moves follow the overlay; resize or scroll hides
the highlight, re-captures, and re-finds the current word (`Align`).

## Dictation

`Dictation` (hold-to-talk state machine) → `Transcriber`: `AnalyzerTranscriber` on macOS 26+ (SpeechAnalyzer with
SpeechTranscriber, or DictationTranscriber where that isn't supported; the model is a shared system asset that
macOS downloads once) or `RecognizerTranscriber` on 15 (SFSpeechRecognizer, on-device when available) → `Paster`
(clipboard, synthetic ⌘V, old clipboard restored). `DictationPanel` shows the mic level and live text. Reading
pauses while you dictate so the mic doesn't hear it.

Before typing, `Fillers.strip` removes um/uh/er/hmm, then (macOS 26+, Apple Intelligence on) `Polisher` tidies the
text with the on-device `SystemLanguageModel` (never Private Cloud Compute): filler "like"/"you know", stutters,
self-corrections. The model is prewarmed when the shortcut goes down; `Fillers.isFaithful` rejects any result with
words that weren't said (e.g. an answer to a dictated question), and after a 3 s budget the filtered text is typed.

Permissions, asked on first use: **Microphone** (and **Speech Recognition** on macOS 15), plus **Accessibility**
to send ⌘V. Without Accessibility the text is left on the clipboard. Like Screen Recording, these grants are
tied to the ad-hoc signature and may need re-granting after a rebuild.

## Differences from the plan

- RecognizeDocumentsRequest (26+) not used yet; reading order comes from XY-cut.
- Kokoro model + voices (~340 MB) download on demand from Voice → Download Kokoro Natural Voices into
  `~/Library/Application Support/YapYap/Kokoro/`. English (US/UK) voices only.
- Not yet: Accessibility-text hybrid (phase 3), auto-continue past the screen, notarization/Sparkle (phase 5).

## License

YapYap is free software: you can redistribute it and/or modify it under the terms of the
[GNU Affero General Public License v3.0](LICENSE). Anyone who ships a modified version, including
as a paid app or a service, must publish its full source under the same license.

Copyright © 2026 Asad Moulvi
