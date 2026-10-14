import Foundation

/// What dictation has heard so far: finalized pieces, plus a live draft that may still change.
public struct Transcript: Equatable {
    public private(set) var final = ""
    public private(set) var draft = ""

    public init() {}

    /// A final piece is kept and clears the draft; a draft replaces the previous draft.
    public mutating func receive(_ text: String, isFinal: Bool) {
        if isFinal {
            final = Self.join(final, text)
            draft = ""
        } else {
            draft = text
        }
    }

    /// Everything heard, trimmed, ready to type.
    public var text: String {
        Self.join(final, draft).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Joins two pieces with one space unless either already has whitespace at the seam.
    static func join(_ a: String, _ b: String) -> String {
        guard let last = a.last, let first = b.first else { return a + b }
        if last.isWhitespace || first.isWhitespace { return a + b }
        return a + " " + b
    }
}
