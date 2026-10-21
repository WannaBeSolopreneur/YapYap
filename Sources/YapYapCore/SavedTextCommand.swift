import Foundation

/// Spots a whole dictation that asks for a saved snippet: "email address", "paste my home address",
/// "type the eleven labs API key". Only the whole dictation counts, so a sentence that mentions
/// an email address is typed as usual.
public enum SavedTextCommand {
    /// The index of the name asked for in `said`, or nil. Saying a name in full always works;
    /// a shortened one ("paste my ElevenLabs" for "ElevenLabs key") needs a word like paste or
    /// type in front, so a lone "home" is still just typed.
    public static func match(_ said: String, names: [String]) -> Int? {
        guard !names.isEmpty else { return nil }
        var words = tokens(said)
        var asked = false
        while let first = words.first, leading.contains(first) {
            if verbs.contains(first) { asked = true }
            words.removeFirst()
        }
        while let last = words.last, trailing.contains(last) { words.removeLast() }
        guard !words.isEmpty, words.count <= 8 else { return nil }

        let full = words.joined()
        let short = words.filter { !generic.contains($0) }.joined()
        // Saying "API key" or "address" counts like asking: it's clearly about a saved thing.
        if short != full { asked = true }

        var best: (index: Int, score: Double)?
        for (index, name) in names.enumerated() {
            let nameWords = tokens(name)
            let nameFull = nameWords.joined()
            let nameShort = nameWords.filter { !generic.contains($0) }.joined()
            guard !nameFull.isEmpty else { continue }
            var score = similarity(full, nameFull)
            if asked, !short.isEmpty, !nameShort.isEmpty { score = max(score, similarity(short, nameShort)) }
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        guard let best else { return nil }
        // Exact, or a near miss like "elevenlab" in a name long enough to tell apart.
        if best.score == 1 { return best.index }
        let length = tokens(names[best.index]).joined().count
        return best.score >= 0.85 && length >= 6 ? best.index : nil
    }

    /// Lower-case words, with numbers spelled out ("11 Labs" and "ElevenLabs" read the same once joined).
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map(spellNumbers)
    }

    private static func spellNumbers(_ word: String) -> String {
        guard word.contains(where: \.isNumber) else { return word }
        var out = "", digits = ""
        func flush() {
            guard !digits.isEmpty else { return }
            if let n = Int(digits), let spelled = speller.string(from: NSNumber(value: n)) {
                out += spelled.components(separatedBy: CharacterSet.letters.inverted).joined()
            } else {
                out += digits
            }
            digits = ""
        }
        for c in word {
            if c.isNumber { digits.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return out
    }

    private static let speller: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    /// 1 for the same text, falling with the share of letters that differ.
    static func similarity(_ a: String, _ b: String) -> Double {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return a == b ? 1 : 0 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = row[j]
                row[j] = current
            }
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }

    private static let verbs: Set<String> = ["paste", "type", "insert", "enter", "put", "add", "fill", "use", "drop", "write", "give"]
    private static let leading: Set<String> = verbs.union(["in", "my", "the", "me", "a", "an", "our", "your", "it", "with", "out", "up"])
    private static let trailing: Set<String> = ["please", "here", "in", "now", "thanks", "thank", "you"]
    /// Words that say what kind of thing it is, which people often leave out or add.
    private static let generic: Set<String> = ["api", "key", "keys", "token", "secret", "password", "address", "number", "details", "info"]
}
