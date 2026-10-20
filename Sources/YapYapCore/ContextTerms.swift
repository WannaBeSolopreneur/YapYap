import Foundation
import NaturalLanguage

/// Words on screen worth teaching the speech recognizer before someone dictates, so names come out
/// spelled right: people, places and organisations (Apple's on-device name tagger), plus words
/// capitalised in the middle of a sentence, which catches products and nicknames it misses
/// ("Fernway", "TelemetryDeck"). Most frequent first.
public enum ContextTerms {
    public static func from(_ text: String, limit: Int = 100) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        func add(_ raw: Substring) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines))
            guard (2...40).contains(word.count), word.rangeOfCharacter(from: .letters) != nil else { return }
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }

        let names: Set<NLTag> = [.personalName, .placeName, .organizationName]
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
            if let tag, names.contains(tag) { add(text[range]) }
            return true
        }

        let sentences = NLTokenizer(unit: .sentence)
        sentences.string = text
        let words = NLTokenizer(unit: .word)
        sentences.enumerateTokens(in: text.startIndex..<text.endIndex) { sentence, _ in
            words.string = String(text[sentence])
            var first = true
            words.enumerateTokens(in: words.string!.startIndex..<words.string!.endIndex) { range, _ in
                let word = words.string![range]
                defer { first = false }
                if !first, let initial = word.first, initial.isUppercase, word != "I" { add(word) }
                return true
            }
            return true
        }

        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return Array(order.sorted { (counts[$0]!, rank[$1]!) > (counts[$1]!, rank[$0]!) }.prefix(limit))
    }
}
