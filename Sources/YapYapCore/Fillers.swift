import Foundation

/// Cleaning up dictated text without a language model, and checking a model's cleanup.
public enum Fillers {
    /// Sounds that are never real words in dictation. "Like", "you know" and "so" are left
    /// alone: they're often meant, and only a language model can tell.
    private static let sounds = try! NSRegularExpression(
        pattern: #"(,?)\s*(?<![\w'-])(?i:u+m+|u+h+m*|e+r+m*|a+h+|h+m+|m{2,})(?![\w'-])((?:\s*(?:,|…|\.{2,}))*)"#)
    /// Words that join a phrase, so commas next to them only framed the filler:
    /// "is, uh, Thursday", "Wednesday, uh, at 3".
    private static let joining: Set<String> = ["is", "are", "was", "were", "be", "the", "a", "an", "to", "of", "at", "on",
                                               "in", "for", "with", "and", "or", "but", "my", "your", "our", "their",
                                               "will", "would", "can", "could", "should", "i", "we", "it", "that"]

    /// "Um, so the plan is, uh, Thursday." → "So the plan is Thursday."
    public static func strip(_ text: String) -> String {
        let ns = NSMutableString(string: text)
        for match in sounds.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let before = match.range(at: 1).length > 0
            let after = match.range(at: 2).length > 0
            var keepComma = false
            if before && after {
                // Either side continuing the phrase means the commas only framed the filler.
                let isWord: (Character) -> Bool = { $0.isLetter || $0 == "'" }
                let previous = ns.substring(to: match.range.location).split(whereSeparator: { !isWord($0) }).last.map { $0.lowercased() } ?? ""
                let next = ns.substring(from: match.range.upperBound).split(whereSeparator: { !isWord($0) }).first.map { $0.lowercased() } ?? ""
                keepComma = !joining.contains(previous) && !joining.contains(next)
            } else if before {
                // "I think, umm we": keep the pause. "numbers, uh.": the sentence end follows.
                let rest = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespaces)
                keepComma = !(rest.isEmpty || ".!?".contains(rest.first!))
            }
            ns.replaceCharacters(in: match.range, with: keepComma ? ", " : " ")
        }
        var s = ns as String
        let fixes: [(String, String)] = [
            (#"\s+([,.!?;:])"#, "$1"),          // "plan ," → "plan,"
            (#",(\s*,)+"#, ","),                // ", ," → ","
            (#",\s*([.!?])"#, "$1"),            // "plan, ." → "plan."
            (#"([.!?])\s*,"#, "$1"),            // ". ," → "."
            (#"^\s*[,.;:]+\s*"#, ""),           // leading ", "
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in fixes {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizingSentences(s)
    }

    /// Capitalizes the first letter of the text and of each sentence, where removing a
    /// filler left a lowercase word in front ("um, so" → "So").
    private static func capitalizingSentences(_ s: String) -> String {
        var out = ""
        var capitalizeNext = true
        for ch in s {
            if capitalizeNext, ch.isLetter {
                out += ch.uppercased()
                capitalizeNext = false
            } else {
                out.append(ch)
                if ".!?".contains(ch) { capitalizeNext = true } else if !ch.isWhitespace { capitalizeNext = false }
            }
        }
        return out
    }

    /// Whether `cleaned` is a plausible cleanup of `original`: not empty, not much longer,
    /// and made almost only of words that were said. Cleanup deletes and repunctuates; a model
    /// that answered a dictated question or rewrote it fails this.
    public static func isFaithful(_ cleaned: String, to original: String) -> Bool {
        let spoken = words(original)
        let said = Set(spoken)
        let kept = words(cleaned)
        guard !kept.isEmpty, !said.isEmpty, kept.count <= spoken.count + 2 else { return false }
        let new = kept.filter { !said.contains($0) }.count
        return Double(new) <= max(1, Double(kept.count) * 0.1)
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }
}
