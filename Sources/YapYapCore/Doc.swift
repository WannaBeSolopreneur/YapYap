import CoreGraphics
import Foundation

/// A recognized line of text. Rects are normalized to the captured image with a
/// bottom-left origin (Vision's convention), so they map straight onto an overlay
/// view that covers the same frame.
public struct OCRLine {
    public var text: String
    public var rect: CGRect
    public var words: [OCRWord]

    public init(text: String, rect: CGRect, words: [OCRWord]) {
        self.text = text
        self.rect = rect
        self.words = words
    }
}

public struct OCRWord {
    public var text: String
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public struct Word {
    public let text: String
    public let rect: CGRect
    public let line: Int
    /// UTF-16 range inside `Doc.text`, the unit AVSpeechSynthesizer reports.
    public let range: NSRange
}

/// The reading model: one speakable string plus every word's screen position, in reading order.
public struct Doc {
    public let text: String
    public let words: [Word]
    public let lineRects: [CGRect]

    /// `blocks` are paragraphs in reading order; lines within a block are joined with
    /// spaces so speech flows, blocks with newlines so the voice pauses between them.
    public init(blocks: [[OCRLine]]) {
        var text = ""
        var length = 0
        var words: [Word] = []
        var lineRects: [CGRect] = []

        func append(_ s: String) {
            text += s
            length += s.utf16.count
        }

        for (bi, block) in blocks.enumerated() {
            if bi > 0 { append("\n") }
            for (li, line) in block.enumerated() {
                if li > 0 { append(" ") }
                let lineIndex = lineRects.count
                lineRects.append(line.rect)
                for (wi, w) in line.words.enumerated() {
                    if wi > 0 { append(" ") }
                    let range = NSRange(location: length, length: w.text.utf16.count)
                    append(w.text)
                    words.append(Word(text: w.text, rect: w.rect, line: lineIndex, range: range))
                }
            }
        }
        self.text = text
        self.words = words
        self.lineRects = lineRects
    }

    /// The word being spoken at a UTF-16 offset into `text`.
    public func wordIndex(atUTF16 location: Int) -> Int? {
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if words[mid].range.location <= location { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// The word under a normalized point, or the nearest word on the line under it.
    public func wordIndex(at point: CGPoint) -> Int? {
        if let hit = words.firstIndex(where: { $0.rect.insetBy(dx: -0.002, dy: -0.002).contains(point) }) {
            return hit
        }
        let onLine = words.indices.filter {
            let r = lineRects[words[$0].line]
            return point.y >= r.minY && point.y <= r.maxY
        }
        return onLine.min { abs(words[$0].rect.midX - point.x) < abs(words[$1].rect.midX - point.x) }
    }
}

extension Doc {
    /// Splits the text from `wordIndex` on into pieces short enough for a neural voice
    /// (Kokoro caps at 510 phonemes), breaking after sentences and at paragraph ends.
    /// The first piece is kept short so speech starts quickly.
    public func chunks(from wordIndex: Int, first: Int = 120, target: Int = 280, limit: Int = 400) -> [NSRange] {
        guard words.indices.contains(wordIndex) else { return [] }
        let ns = text as NSString
        var result: [NSRange] = []
        var start = wordIndex
        for i in wordIndex..<words.count {
            let begin = words[start].range.location
            let end = NSMaxRange(words[i].range)
            let length = end - begin
            let isLast = i == words.count - 1
            let paragraphEnds = !isLast && ns.substring(with: NSRange(location: end, length: words[i + 1].range.location - end)).contains("\n")
            let sentenceEnds = words[i].text.last.map { ".!?:;".contains($0) } ?? false
            let goal = result.isEmpty ? first : target
            let nextTooLong = !isLast && NSMaxRange(words[i + 1].range) - begin > limit
            if isLast || paragraphEnds || (sentenceEnds && length >= goal) || nextTooLong {
                result.append(NSRange(location: begin, length: length))
                start = i + 1
            }
        }
        return result
    }
}

extension Doc {
    /// True when a sentence ends after word `i`: closing punctuation or the end of a paragraph.
    func endsSentence(_ i: Int) -> Bool {
        guard i < words.count - 1 else { return true }
        let trimmed = words[i].text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'”’)]"))
        if let last = trimmed.last, ".!?…".contains(last) { return true }
        let end = NSMaxRange(words[i].range)
        let gap = NSRange(location: end, length: words[i + 1].range.location - end)
        return (text as NSString).substring(with: gap).contains("\n")
    }

    public func sentenceStart(containing i: Int) -> Int {
        var s = min(max(i, 0), words.count - 1)
        while s > 0, !endsSentence(s - 1) { s -= 1 }
        return s
    }

    public func nextSentence(from i: Int) -> Int? {
        var j = max(i, 0)
        while j < words.count - 1, !endsSentence(j) { j += 1 }
        return j + 1 < words.count ? j + 1 : nil
    }

    /// Like a music player's back button: restarts the sentence, or goes to the previous
    /// one when already within its first two words.
    public func previousSentence(from i: Int) -> Int {
        let start = sentenceStart(containing: i)
        return i - start <= 1 && start > 0 ? sentenceStart(containing: start - 1) : start
    }
}

extension Doc {
    /// The text to hand to a voice. With `skippingLinks`, web and email addresses are blanked
    /// out with spaces of the same length, so the voice stays silent there while every UTF-16
    /// offset (and so every word index the voice reports) stays the same.
    public func speechText(skippingLinks: Bool) -> String {
        guard skippingLinks, let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return text
        }
        let spoken = NSMutableString(string: text)
        for match in detector.matches(in: text, range: NSRange(location: 0, length: spoken.length)) {
            spoken.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        return spoken as String
    }
}

/// Text as handed to a neural voice, with a way back to the original's UTF-16 offsets.
public struct SpeechText {
    public let text: String
    /// `map[i]` is the original offset of UTF-16 unit `i` in `text`, plus one entry for the end.
    let map: [Int]

    /// Squeezes runs of spaces (left by skipped links) to one: Kokoro turns a long blank run
    /// into a stray sound.
    public static func collapsingSpaces(_ original: String) -> SpeechText {
        var units: [UInt16] = []
        var map: [Int] = []
        var previousWasSpace = false
        for (i, u) in original.utf16.enumerated() {
            let isSpace = u == 0x20
            if isSpace && previousWasSpace { continue }
            units.append(u)
            map.append(i)
            previousWasSpace = isSpace
        }
        map.append(original.utf16.count)
        return SpeechText(text: String(utf16CodeUnits: units, count: units.count), map: map)
    }

    public func original(_ offset: Int) -> Int {
        map[min(max(offset, 0), map.count - 1)]
    }
}
